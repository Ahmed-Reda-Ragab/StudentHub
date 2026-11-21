#!/usr/bin/env bash
# status.sh — what is running, which color is live, how nginx routes traffic.
# shellcheck source-path=SCRIPTDIR source=lib.sh
# shellcheck disable=SC2034  # state vars (ACTIVE, MODE, *_IMAGE) are read by lib.sh/save_state
source "$(dirname "$0")/lib.sh"

load_state
echo "── state ($STATE_FILE)"
cat "$STATE_FILE"
echo
echo "── containers"
compose ps
echo
echo "── nginx upstreams"
sed -n '/upstream app_main/,/}/p' "$NGINX_STATE/upstreams.conf"
[[ -s "$NGINX_STATE/maps.conf" ]] && { echo "── nginx maps (A/B)"; cat "$NGINX_STATE/maps.conf"; }
echo
echo "── slots"
for color in blue green; do
    printf '  %-6s ' "$color"
    curl -s -m 2 "http://127.0.0.1:$(slot_port "$color")/ready" || printf 'down'
    echo
done
echo "── through the proxy"
via_proxy /ready || echo "proxy not answering"
echo
