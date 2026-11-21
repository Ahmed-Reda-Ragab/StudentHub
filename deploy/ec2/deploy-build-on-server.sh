#!/usr/bin/env bash
# deploy-build-on-server.sh [git-ref] — scenario 20 / 31: build the image ON the EC2 host.
#
#   ssh ec2-user@<host> 'cd /opt/student-app/src && ./deploy/ec2/deploy-build-on-server.sh master'
#
# Strategy = Recreate: the old container is stopped and the new one started → a few
# seconds of downtime (measure it with deploy/scripts/probe.sh from your laptop).
# Downsides you should be able to explain in an interview: the server needs build tools,
# CPU/RAM spikes on the box serving users, builds are not reproducible across servers,
# and the image is never scanned before it runs.
set -euo pipefail

REF="${1:-master}"
APP_DIR="${APP_DIR:-/opt/student-app}"
SRC_DIR="${SRC_DIR:-$APP_DIR/src}"
USE_LOCAL_MYSQL="${USE_LOCAL_MYSQL:-true}"

cd "$SRC_DIR"
git fetch --prune origin
git checkout -q "$REF"
git merge -q --ff-only "origin/$REF" 2>/dev/null || true
SHA="$(git rev-parse --short HEAD)"

export APP_VERSION="$SHA"
export APP_IMAGE="student-app:$SHA"
export APP_ENV_FILE="$APP_DIR/app.env"
export MYSQL_ENV_FILE="$APP_DIR/mysql.env"
compose() { docker compose -f "$SRC_DIR/docker-compose.prod.yml" "$@"; }

echo "▶ building $APP_IMAGE on $(hostname)"
compose build app

if [[ "$USE_LOCAL_MYSQL" == "true" ]]; then
    compose up -d --wait mysql
fi

echo "▶ migrations (one-off container, new image)"
compose run --rm --no-deps app php artisan migrate --force

echo "▶ recreate app (downtime window starts)"
compose up -d --no-deps --wait app
echo "▶ live: $(curl -fsS -m 5 http://127.0.0.1/ready)"

[[ -f "$APP_DIR/CURRENT_RELEASE" ]] && cp "$APP_DIR/CURRENT_RELEASE" "$APP_DIR/PREVIOUS_RELEASE"
echo "$APP_IMAGE" > "$APP_DIR/CURRENT_RELEASE"
docker image prune -f --filter "until=168h" >/dev/null
echo "✔ deployed $SHA"
