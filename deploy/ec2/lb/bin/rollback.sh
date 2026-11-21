#!/usr/bin/env bash
# rollback.sh — undo the last change, whatever the strategy was.
#
#   MODE=single  (after blue/green or a promoted canary) → switch to the other color
#                 (instant while it is still running; otherwise it is started first)
#   MODE=canary|ab|shadow (an experiment is in progress or was interrupted)
#                → 100% back to the live color ($ACTIVE); the experiment slot keeps running
#   MODE=rolling (both slots run the new image) → roll both slots back to PREVIOUS_IMAGE
#
# Migrations are never rolled back — they must be backward compatible (scenario 95).
# shellcheck source-path=SCRIPTDIR source=lib.sh
# shellcheck disable=SC2034  # state vars (ACTIVE, MODE, *_IMAGE) are read by lib.sh/save_state
source "$(dirname "$0")/lib.sh"

load_state

case "$MODE" in
    canary|ab|shadow)
        is_ready "$ACTIVE" || die "live color $ACTIVE is not ready — inspect with bin/status.sh"
        render_single "$ACTIVE"
        reload_proxy
        MODE="single"; save_state
        ok "experiment cancelled: 100% on $ACTIVE ($(image_of "$ACTIVE")); app_$(other "$ACTIVE") left running for investigation"
        ;;
    rolling)
        [[ -n "$PREVIOUS_IMAGE" ]] || die "no PREVIOUS_IMAGE recorded — run bin/rolling.sh <old-image> manually"
        warn "pool mode: rolling both slots back to $PREVIOUS_IMAGE"
        SKIP_MIGRATE=true exec bash "$(dirname "$0")/rolling.sh" "$PREVIOUS_IMAGE"
        ;;
    *)
        CURRENT="$ACTIVE"
        PREVIOUS="$(other "$CURRENT")"
        [[ -n "$(image_of "$PREVIOUS")" ]] || die "no previous release recorded for $PREVIOUS"
        # After a FAILED deploy traffic never left $CURRENT — the other slot holds the broken release.
        [[ "$BROKEN" != "$PREVIOUS" ]] || die "app_$PREVIOUS holds the release that just failed its checks ($(image_of "$PREVIOUS")) — nothing to roll back to; $CURRENT is still live"

        if ! slot_running "$PREVIOUS"; then
            warn "app_$PREVIOUS is stopped — starting it (rollback is no longer instant)"
            SKIP_MIGRATE=true start_slot "$PREVIOUS" || die "previous release failed to start — traffic unchanged on $CURRENT"
        fi
        wait_ready "$PREVIOUS" || die "app_$PREVIOUS is not ready — traffic unchanged on $CURRENT"
        smoke "$PREVIOUS" || die "app_$PREVIOUS failed its smoke test — traffic unchanged on $CURRENT"

        render_single "$PREVIOUS"
        reload_proxy
        ACTIVE="$PREVIOUS"; MODE="single"; save_state
        ok "rolled back: live=$PREVIOUS ($(image_of "$PREVIOUS")); $CURRENT left running for investigation"
        ;;
esac
warn "migrations are NOT rolled back — that is why they must be backward compatible (expand/contract, scenario 95)"
