#!/usr/bin/env bash
# canary.sh <image> — progressive delivery on one host (scenario 24).
#
# The new image starts on the idle color, then receives STEPS percent of traffic
# (weighted nginx upstream). After each step the canary's own /metrics are compared
# before/after: if its 5xx ratio on real pages exceeds MAX_ERROR_RATE, traffic goes
# back to the stable color and the script exits 2 (automatic abort).
#
#   STEPS="10 25 50 100" STEP_SECONDS=60 MAX_ERROR_RATE=0.01 ./bin/canary.sh <image>
#   SLOT_ENV="SRE_FAULT_ERROR_RATE=0.5" ./bin/canary.sh <image>     # bad-release drill
#
# Real canaries get real user traffic. In the lab, generate it in another terminal:
#   ../../scripts/probe.sh http://localhost/login 0 0.05
# shellcheck source-path=SCRIPTDIR source=lib.sh
# shellcheck disable=SC2034  # state vars (ACTIVE, MODE, *_IMAGE) are read by lib.sh/save_state
source "$(dirname "$0")/lib.sh"

IMAGE="${1:?usage: canary.sh <image>}"
STEPS="${STEPS:-10 25 50 100}"
STEP_SECONDS="${STEP_SECONDS:-30}"
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.01}"
MIN_REQUESTS="${MIN_REQUESTS:-10}"

load_state
ensure_single_live
STABLE="$ACTIVE"
CANARY="$(other "$STABLE")"
log "stable=$STABLE ($(image_of "$STABLE"))  canary=$CANARY <- $IMAGE"

abort() {
    warn "ABORT: $1"
    render_single "$STABLE"
    reload_proxy
    ACTIVE="$STABLE"; MODE="single"; BROKEN="$CANARY"; save_state
    stop_slot "$CANARY" || true
    warn "canary aborted - 100% of traffic back on $STABLE ($(image_of "$STABLE"))"
    exit 2
}

set_image "$CANARY" "$IMAGE"
MODE="canary"
save_state
# A release that fails its pre-traffic checks (migrate / ready / smoke) is an aborted
# canary too: it never received user traffic. Same exit code (2) as a failed analysis.
start_slot "$CANARY" || abort "canary failed its pre-traffic checks (migrate / ready / smoke)"

for pct in $STEPS; do
    if (( pct >= 100 )); then break; fi
    log "step: $pct% -> $CANARY"
    render_weighted "$STABLE" "$CANARY" "$pct"
    reload_proxy

    read -r e0 t0 <<<"$(slot_counters "$CANARY")"
    sleep "$STEP_SECONDS"
    read -r e1 t1 <<<"$(slot_counters "$CANARY")"

    errors=$(( e1 - e0 )); total=$(( t1 - t0 ))
    if (( total < MIN_REQUESTS )); then
        warn "only $total canary requests in ${STEP_SECONDS}s (< MIN_REQUESTS=$MIN_REQUESTS) - not enough data, holding this step"
        sleep "$STEP_SECONDS"
        read -r e1 t1 <<<"$(slot_counters "$CANARY")"
        errors=$(( e1 - e0 )); total=$(( t1 - t0 ))
        (( total >= MIN_REQUESTS )) || abort "no traffic reached the canary - cannot judge it"
    fi

    rate=$(awk -v e="$errors" -v t="$total" 'BEGIN { printf "%.4f", e / t }')
    log "canary analysis: $errors errors / $total requests = $rate (max $MAX_ERROR_RATE)"
    if awk -v r="$rate" -v m="$MAX_ERROR_RATE" 'BEGIN { exit !(r > m) }'; then
        abort "error rate $rate > $MAX_ERROR_RATE at $pct%"
    fi
    ok "step $pct% healthy"
done

log "promoting $CANARY to 100%"
render_single "$CANARY"
reload_proxy
ACTIVE="$CANARY"; MODE="single"; save_state
ok "canary promoted: live=$CANARY ($IMAGE); $STABLE still running for rollback"
