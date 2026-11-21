#!/usr/bin/env bash
# bluegreen.sh <image> — Blue/Green on one host (scenario 23).
#
#  1. deploy the new image to the IDLE color (pull → migrate → start → ready → smoke)
#  2. switch 100% of traffic in one graceful nginx reload
#  3. keep the old color running → ./bin/rollback.sh is instant
#
#   KEEP_OLD=false ./bin/bluegreen.sh <image>   # stop the old color after DRAIN_SECONDS
# shellcheck source-path=SCRIPTDIR source=lib.sh
# shellcheck disable=SC2034  # state vars (ACTIVE, MODE, *_IMAGE) are read by lib.sh/save_state
source "$(dirname "$0")/lib.sh"

IMAGE="${1:?usage: bluegreen.sh <image>}"
KEEP_OLD="${KEEP_OLD:-true}"
DRAIN_SECONDS="${DRAIN_SECONDS:-10}"

load_state
ensure_single_live
LIVE="$ACTIVE"
IDLE="$(other "$LIVE")"
log "live=$LIVE ($(image_of "$LIVE"))  →  deploying $IMAGE to idle=$IDLE"

set_image "$IDLE" "$IMAGE"
save_state

start_slot "$IDLE" || die "new release failed its pre-traffic checks - traffic is still 100% on $LIVE ($(image_of "$LIVE"))"

log "switching traffic $LIVE → $IDLE"
render_single "$IDLE"
reload_proxy

served_by="$(via_proxy /ready | grep -o '"color":"[^"]*"' | cut -d'"' -f4)"
[[ "$served_by" == "$IDLE" ]] || die "proxy still answers from '$served_by' — check state/nginx/upstreams.conf"

ACTIVE="$IDLE"
MODE="single"
save_state
ok "now live: $IDLE ($IMAGE)"

if [[ "$KEEP_OLD" == "true" ]]; then
    ok "$LIVE kept running for instant rollback:  ./bin/rollback.sh"
else
    log "draining $LIVE for ${DRAIN_SECONDS}s before stopping it"
    sleep "$DRAIN_SECONDS"
    stop_slot "$LIVE"
fi
