#!/usr/bin/env bash
# ab-test.sh <image> [percent] | ab-test.sh stop — A/B testing (scenario 26).
#
# Unlike a canary (random requests, judged by error rate), A/B routes USERS:
#   - header  X-Variant: green|blue  → forced variant (QA / internal testers)
#   - cookie  ab_variant=green|blue  → sticky: a user stays in the same variant
#   - otherwise split_clients hashes the client → <percent>% get the new version
# shellcheck source-path=SCRIPTDIR source=lib.sh
# shellcheck disable=SC2034  # state vars (ACTIVE, MODE, *_IMAGE) are read by lib.sh/save_state
source "$(dirname "$0")/lib.sh"

load_state
STABLE="$ACTIVE"
VARIANT="$(other "$STABLE")"

if [[ "${1:-}" == "stop" ]]; then
    render_single "$STABLE"
    reload_proxy
    MODE="single"; save_state
    ok "A/B test stopped — 100% on $STABLE"
    exit 0
fi

IMAGE="${1:?usage: ab-test.sh <image> [percent] | stop}"
PERCENT="${2:-20}"
ensure_single_live

set_image "$VARIANT" "$IMAGE"
MODE="ab"; save_state
start_slot "$VARIANT" || { MODE="single"; save_state; die "variant failed its checks - traffic unchanged on $STABLE"; }

render_single "$STABLE"   # upstreams (app_*_only are always defined)
cat > "$NGINX_STATE/maps.conf" <<EOF
# A/B routing — generated $(date -Iseconds)
split_clients "\${remote_addr}\${http_user_agent}" \$ab_split {
    ${PERCENT}%   app_${VARIANT}_only;
    *             app_${STABLE}_only;
}
map \$cookie_ab_variant \$ab_cookie {
    ${VARIANT}    app_${VARIANT}_only;
    ${STABLE}     app_${STABLE}_only;
    default       "";
}
map \$http_x_variant \$ab_forced {
    ${VARIANT}    app_${VARIANT}_only;
    ${STABLE}     app_${STABLE}_only;
    default       \$ab_cookie;
}
map \$ab_forced \$ab_upstream {
    ""            \$ab_split;
    default       \$ab_forced;
}
map \$ab_upstream \$ab_variant_name {
    app_${VARIANT}_only  ${VARIANT};
    default              ${STABLE};
}
EOF
cat > "$NGINX_STATE/routing.conf" <<'EOF'
location / {
    proxy_pass http://$ab_upstream;
    add_header X-Variant $ab_variant_name always;
    add_header Set-Cookie "ab_variant=$ab_variant_name; Path=/; Max-Age=86400; SameSite=Lax" always;
}
EOF
reload_proxy
ok "A/B live: ${PERCENT}% of users → $VARIANT ($IMAGE), rest → $STABLE. Force with: curl -H 'X-Variant: $VARIANT' ..."
