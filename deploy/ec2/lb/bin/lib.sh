#!/usr/bin/env bash
# Shared helpers for the single-host zero-downtime scripts. Sourced, not executed.
#
# Environment (all optional):
#   APP_ENV_FILE     app env file           (default /opt/student-app/app.env)
#   MYSQL_ENV_FILE   mysql container env    (default /opt/student-app/mysql.env)
#   USE_LOCAL_MYSQL  true|false             (default true; false when DB_HOST is RDS)
#   LB_HTTP_PORT     proxy port             (default 80)
#   READY_TIMEOUT    seconds to wait for a slot to become ready (default 120)
#   SKIP_PULL        true to use a local image without `docker compose pull`
#   SKIP_MIGRATE     true to skip `php artisan migrate --force`
#   SLOT_ENV         extra env for the NEW slot only, e.g. "SRE_FAULT_ERROR_RATE=0.5" (bad-release drills)
set -euo pipefail

LB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$LB_DIR/state"
NGINX_STATE="$STATE_DIR/nginx"
STATE_FILE="$STATE_DIR/release.env"

export APP_ENV_FILE="${APP_ENV_FILE:-/opt/student-app/app.env}"
export MYSQL_ENV_FILE="${MYSQL_ENV_FILE:-/opt/student-app/mysql.env}"
export LB_HTTP_PORT="${LB_HTTP_PORT:-80}"
USE_LOCAL_MYSQL="${USE_LOCAL_MYSQL:-true}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"

BLUE_IMAGE=""
GREEN_IMAGE=""
ACTIVE="blue"
MODE="single"          # single | canary | ab | shadow | rolling
PREVIOUS_IMAGE=""      # what rolling.sh replaced (rollback target in pool mode)
BROKEN=""              # color whose last start_slot failed — rollback.sh never switches to it

log()  { printf '\033[1;34m[%s] %s\033[0m\n' "$(date +%T)" "$*"; }
ok()   { printf '\033[1;32m[%s] ✔ %s\033[0m\n' "$(date +%T)" "$*"; }
warn() { printf '\033[1;33m[%s] ! %s\033[0m\n' "$(date +%T)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ✘ %s\033[0m\n' "$(date +%T)" "$*" >&2; exit 1; }

compose() {
    docker compose -f "$LB_DIR/docker-compose.yml" --env-file "$STATE_FILE" "$@"
}

load_state() {
    [[ -f "$STATE_FILE" ]] || die "No state yet — run bin/init.sh <image> first."
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

save_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
BLUE_IMAGE=$BLUE_IMAGE
GREEN_IMAGE=$GREEN_IMAGE
ACTIVE=$ACTIVE
MODE=$MODE
PREVIOUS_IMAGE=$PREVIOUS_IMAGE
BROKEN=$BROKEN
EOF
}

other() { [[ "$1" == "blue" ]] && echo green || echo blue; }

slot_port() { [[ "$1" == "blue" ]] && echo 8081 || echo 8082; }

set_image() { # color image
    if [[ "$1" == "blue" ]]; then BLUE_IMAGE="$2"; else GREEN_IMAGE="$2"; fi
}

image_of() { [[ "$1" == "blue" ]] && echo "$BLUE_IMAGE" || echo "$GREEN_IMAGE"; }

# Per-slot env overrides (state/<color>.env). Reset on every deploy unless SLOT_ENV is given.
write_slot_env() { # color
    mkdir -p "$STATE_DIR"
    : > "$STATE_DIR/$1.env"
    if [[ -n "${SLOT_ENV:-}" ]]; then
        tr ' ' '\n' <<<"$SLOT_ENV" > "$STATE_DIR/$1.env"
        warn "slot $1 gets extra env: $SLOT_ENV"
    fi
}

slot_running() { # color
    [[ -n "$(compose ps -q --status running "app_$1" 2>/dev/null)" ]]
}

# The helpers below RETURN non-zero instead of exiting, so each strategy decides what a
# failed slot means: blue/green keeps traffic where it is, canary aborts (exit 2),
# rolling puts the healthy peer back in charge. Callers: `start_slot x || <handle>`.
# (Inside `||` bash disables `set -e`, hence the explicit `|| return 1` everywhere.)

is_ready() { # color — single quick check, no waiting
    curl -fsS -m 2 "http://127.0.0.1:$(slot_port "$1")/ready" >/dev/null 2>&1
}

wait_ready() { # color
    local color="$1" port body deadline
    port="$(slot_port "$color")"
    deadline=$(( $(date +%s) + READY_TIMEOUT ))
    log "waiting for app_$color to be ready on 127.0.0.1:$port/ready ..."
    until body=$(curl -fsS -m 2 "http://127.0.0.1:$port/ready" 2>/dev/null); do
        if (( $(date +%s) >= deadline )); then
            compose logs --tail=50 "app_$color" >&2 || true
            warn "app_$color not ready after ${READY_TIMEOUT}s"
            return 1
        fi
        sleep 2
    done
    ok "app_$color ready: $body"
}

smoke() { # color — the release must serve real pages before it gets traffic
    local port path; port="$(slot_port "$1")"
    for path in /up /ready /login; do
        if ! curl -fsS -o /dev/null -m 5 "http://127.0.0.1:$port$path"; then
            warn "smoke test failed: app_$1 $path"
            return 1
        fi
    done
    ok "smoke tests passed on app_$1 (/up /ready /login)"
}

migrate() { # color — run once per release with the NEW image, before it receives traffic
    if [[ "${SKIP_MIGRATE:-false}" == "true" ]]; then warn "SKIP_MIGRATE=true"; return 0; fi
    log "running migrations with app_$1 image ($(image_of "$1"))"
    compose run --rm --no-deps "app_$1" php artisan migrate --force
}

start_slot() { # color — pull, migrate, (re)create, wait, smoke. Returns 1 on any failure.
    local color="$1"
    if _start_slot "$color"; then
        [[ "$BROKEN" == "$color" ]] && { BROKEN=""; save_state; }
        return 0
    fi
    BROKEN="$color"   # remembered so bin/rollback.sh never sends traffic to a failed release
    save_state
    return 1
}

_start_slot() {
    local color="$1"
    if [[ "${SKIP_PULL:-false}" != "true" ]]; then
        compose pull "app_$color" || warn "pull failed — using the local image"
    fi
    write_slot_env "$color" || return 1
    migrate "$color" || { warn "migrations failed with $(image_of "$color")"; return 1; }
    log "starting app_$color with $(image_of "$color")"
    # --no-deps: never touch mysql/proxy while deploying a slot (--force-recreate would restart them too)
    compose up -d --no-deps --force-recreate "app_$color" || return 1
    wait_ready "$color" || return 1
    smoke "$color" || return 1
}

stop_slot() { # color
    log "stopping app_$1 (graceful: SIGQUIT, up to 30s for in-flight requests)"
    compose stop "app_$1"
}

# ---------------------------------------------------------------- nginx rendering
write_upstreams() { # main-servers-block
    mkdir -p "$NGINX_STATE"
    cat > "$NGINX_STATE/upstreams.conf" <<EOF
# generated by deploy/ec2/lb/bin — $(date -Iseconds)
upstream app_main {
    zone app_main 64k;
$1
    keepalive 16;
}
upstream app_blue_only {
    zone app_blue_only 64k;
    server app_blue:8080 resolve;
}
upstream app_green_only {
    zone app_green_only 64k;
    server app_green:8080 resolve;
}
EOF
}

write_routing_default() {
    : > "$NGINX_STATE/maps.conf"
    cat > "$NGINX_STATE/routing.conf" <<'EOF'
location / {
    proxy_pass http://app_main;
}
EOF
}

render_single() { # color
    write_upstreams "    server app_$1:8080 resolve;"
    write_routing_default
}

render_weighted() { # stable canary canary-percent
    local stable="$1" canary="$2" pct="$3"
    if (( pct >= 100 )); then render_single "$canary"; return; fi
    write_upstreams "    server app_$stable:8080 resolve weight=$(( 100 - pct ));
    server app_$canary:8080 resolve weight=$pct;"
    write_routing_default
}

render_pool() { # space-separated "color:state" list, state = up|down
    local lines="" item color state
    for item in $1; do
        color="${item%%:*}"; state="${item##*:}"
        if [[ "$state" == "down" ]]; then
            lines+="    server app_$color:8080 resolve down;"$'\n'
        else
            lines+="    server app_$color:8080 resolve;"$'\n'
        fi
    done
    write_upstreams "${lines%$'\n'}"
    write_routing_default
}

reload_proxy() {
    if [[ -z "$(compose ps -q --status running proxy 2>/dev/null)" ]]; then
        log "starting proxy"
        compose up -d --no-deps proxy
        sleep 1
    fi
    compose exec -T proxy nginx -t -q || die "nginx config test failed — traffic NOT switched"
    compose exec -T proxy nginx -s reload
    sleep 1
    ok "proxy reloaded (graceful)"
}

# After a rolling update both slots are in the pool. Before the idle slot is recreated
# (blue/green, canary, A/B, shadow), route 100% to the live color again.
ensure_single_live() {
    if [[ "$MODE" != "single" ]]; then
        is_ready "$ACTIVE" || die "mode=$MODE but live color $ACTIVE is not ready — inspect with bin/status.sh before deploying"
        log "mode=$MODE → routing 100% to live color $ACTIVE before touching the idle slot"
        render_single "$ACTIVE"
        reload_proxy
        MODE="single"
        save_state
    fi
}

via_proxy() { # path
    curl -fsS -m 3 "http://127.0.0.1:$LB_HTTP_PORT$1"
}

# ---------------------------------------------------------------- metrics gate
# Prints "<5xx> <total>" for app requests served by a slot (scraped straight from its /metrics).
# sre-lab endpoints and the health checks are excluded: we judge the release on real pages.
slot_counters() { # color
    local port token auth=()
    port="$(slot_port "$1")"
    # /metrics may be protected by METRICS_TOKEN (bearer) — read it from the app env file.
    token="${METRICS_TOKEN:-$(grep -E '^METRICS_TOKEN=' "$APP_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')}"
    [[ -n "$token" ]] && auth=(-H "Authorization: Bearer $token")
    curl -fsS -m 3 "${auth[@]}" "http://127.0.0.1:$port/metrics" 2>/dev/null \
        | awk '
            /^student_app_http_requests_total\{/ {
                if ($0 ~ /route="(sre-lab\.|health\.ready|up)/) next
                total += $NF
                if ($0 ~ /status="5[0-9][0-9]"/) errors += $NF
            }
            END { printf "%d %d\n", errors, total }'
}
