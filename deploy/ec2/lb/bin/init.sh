#!/usr/bin/env bash
# init.sh <image> — first start of the zero-downtime stack: mysql + app_blue + proxy (blue active).
#   ./bin/init.sh 123456789012.dkr.ecr.us-east-1.amazonaws.com/student-app:3f2c1ab
# shellcheck source-path=SCRIPTDIR source=lib.sh
# shellcheck disable=SC2034  # state vars (ACTIVE, MODE, *_IMAGE) are read by lib.sh/save_state
source "$(dirname "$0")/lib.sh"

IMAGE="${1:?usage: init.sh <image>}"

BLUE_IMAGE="$IMAGE"
GREEN_IMAGE="$IMAGE"
ACTIVE="blue"
MODE="single"
save_state
render_single blue

if [[ "$USE_LOCAL_MYSQL" == "true" ]]; then
    log "starting mysql"
    compose up -d --wait mysql
fi

start_slot blue || die "first release failed its checks (see logs above)"
reload_proxy
via_proxy /ready >/dev/null && ok "stack is up: http://<host>:$LB_HTTP_PORT  (active=blue, image=$IMAGE)"
