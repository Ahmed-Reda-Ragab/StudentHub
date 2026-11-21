#!/usr/bin/env bash
# ApplicationStop (scenario 37) — executed from the PREVIOUS revision, before the new files land.
#
# With traffic control the instance is already deregistered (BlockTraffic). By default the old
# container keeps running: ApplicationStart recreates it within seconds, and if this deployment
# fails before ApplicationStart, CodeDeploy's rollback finds a working release still in place.
# STOP_APP_ON_APPLICATION_STOP=true stops it gracefully instead (SIGQUIT, 30 s grace).
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/student-app}"
STOP_APP_ON_APPLICATION_STOP="${STOP_APP_ON_APPLICATION_STOP:-false}"

if [[ ! -f "$APP_DIR/CURRENT_RELEASE" ]]; then
    echo "first deployment on this instance: nothing to stop"
    exit 0
fi
echo "current release: $(cat "$APP_DIR/CURRENT_RELEASE")"

if [[ "$STOP_APP_ON_APPLICATION_STOP" == "true" && -f "$APP_DIR/docker-compose.prod.yml" ]]; then
    APP_ENV_FILE="$APP_DIR/app.env" MYSQL_ENV_FILE="$APP_DIR/mysql.env" \
        docker compose -f "$APP_DIR/docker-compose.prod.yml" stop app
    echo "app container stopped"
else
    echo "keeping the current container until ApplicationStart replaces it"
fi
