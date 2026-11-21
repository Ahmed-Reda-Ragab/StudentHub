#!/usr/bin/env bash
# rolling.sh <image> — rolling update across the slots of one host (scenario 25).
#
# Both slots serve traffic (pool mode). One slot at a time is marked `down` in nginx,
# drained, recreated with the new image, health-checked and put back — capacity never
# drops to zero. With N slots it is the same loop; ASG instance refresh (scenario 44),
# ECS (53) and Kubernetes (66) do exactly this at bigger scale.
#
# If a new slot fails its checks, the healthy peer (still on the old image) takes 100%
# of traffic and the script stops — never leaving a broken slot in the pool.
# `bin/rollback.sh` afterwards rolls both slots back to PREVIOUS_IMAGE.
# shellcheck source-path=SCRIPTDIR source=lib.sh
# shellcheck disable=SC2034  # state vars (ACTIVE, MODE, *_IMAGE) are read by lib.sh/save_state
source "$(dirname "$0")/lib.sh"

IMAGE="${1:?usage: rolling.sh <image>}"
DRAIN_SECONDS="${DRAIN_SECONDS:-3}"
SLOTS=(blue green)

load_state
ensure_single_live
LIVE_IMAGE="$(image_of "$ACTIVE")"

# Pool mode needs every slot up with the CURRENT live release first (an idle slot may
# still run an older image from a previous blue/green — it must not join the pool).
for color in "${SLOTS[@]}"; do
    if ! slot_running "$color" || [[ "$(image_of "$color")" != "$LIVE_IMAGE" ]]; then
        log "pool mode: (re)starting app_$color with the live image $LIVE_IMAGE"
        set_image "$color" "$LIVE_IMAGE"
        save_state
        SKIP_MIGRATE=true start_slot "$color" || die "could not prepare app_$color with the live image — traffic untouched on $ACTIVE"
    fi
done

PREVIOUS_IMAGE="$LIVE_IMAGE"
render_pool "blue:up green:up"
reload_proxy
MODE="rolling"; save_state

first=true
for color in "${SLOTS[@]}"; do
    peer="$(other "$color")"
    log "── rolling app_$color ──"
    render_pool "$color:down $peer:up"
    reload_proxy
    log "draining app_$color for ${DRAIN_SECONDS}s"
    sleep "$DRAIN_SECONDS"

    set_image "$color" "$IMAGE"
    save_state
    # migrations run once, with the first new slot
    skip_migrate=$([[ "$first" == "true" ]] && echo "${SKIP_MIGRATE:-false}" || echo true)
    first=false
    if ! SKIP_MIGRATE="$skip_migrate" start_slot "$color"; then
        warn "app_$color failed with $IMAGE — $peer takes 100% of traffic"
        render_single "$peer"
        reload_proxy
        ACTIVE="$peer"; MODE="single"; save_state
        die "rolling update stopped; live=$peer ($(image_of "$peer")). Investigate app_$color, fix, then run bin/rolling.sh again"
    fi

    render_pool "blue:up green:up"
    reload_proxy
    ok "app_$color updated and back in the pool"
done

ACTIVE="blue"; save_state
ok "rolling update complete: all slots run $IMAGE (previous: $PREVIOUS_IMAGE)"
