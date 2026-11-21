#!/usr/bin/env bash
# shadow.sh <image> | shadow.sh stop — traffic mirroring / dark launch (scenario 26).
#
# Users are always served by the live color. nginx `mirror` sends a copy of every
# request to the new version and DISCARDS its response — you compare its metrics,
# logs and latency under real traffic with zero user impact.
#
# DANGER: mirrored writes (POST/PUT/DELETE) would hit the shared database twice,
# so only GET/HEAD are mirrored. Real systems mirror into an isolated environment.
# shellcheck source-path=SCRIPTDIR source=lib.sh
# shellcheck disable=SC2034  # state vars (ACTIVE, MODE, *_IMAGE) are read by lib.sh/save_state
source "$(dirname "$0")/lib.sh"

load_state
LIVE="$ACTIVE"
SHADOW="$(other "$LIVE")"

if [[ "${1:-}" == "stop" ]]; then
    render_single "$LIVE"
    reload_proxy
    MODE="single"; save_state
    ok "shadow traffic stopped"
    exit 0
fi

IMAGE="${1:?usage: shadow.sh <image> | stop}"
ensure_single_live
set_image "$SHADOW" "$IMAGE"
MODE="shadow"; save_state
start_slot "$SHADOW" || { MODE="single"; save_state; die "shadow release failed its checks - traffic unchanged on $LIVE"; }

render_single "$LIVE"
cat > "$NGINX_STATE/routing.conf" <<EOF
location / {
    mirror /__shadow;
    mirror_request_body off;
    proxy_pass http://app_main;
}
location = /__shadow {
    internal;
    if (\$request_method !~ ^(GET|HEAD)\$) {
        return 204;
    }
    proxy_set_header X-Shadow-Request "1";
    proxy_connect_timeout 1s;
    proxy_read_timeout 3s;
    proxy_pass http://app_${SHADOW}_only\$request_uri;
}
EOF
reload_proxy
ok "shadowing GET traffic to $SHADOW ($IMAGE). Compare: curl -s 127.0.0.1:$(slot_port "$SHADOW")/metrics vs 127.0.0.1:$(slot_port "$LIVE")/metrics"
