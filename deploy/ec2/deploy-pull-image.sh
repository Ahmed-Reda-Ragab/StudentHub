#!/usr/bin/env bash
# deploy-pull-image.sh <image-uri> — scenario 32 / 33: run an image that CI already built,
# tested and scanned (build once, deploy many). Called by SSM Run Command or Ansible.
#
#   ./deploy-pull-image.sh 123456789012.dkr.ecr.us-east-1.amazonaws.com/student-app:3f2c1ab
#   ./deploy-pull-image.sh rollback          # redeploy PREVIOUS_RELEASE
#
# Expects /opt/student-app/docker-compose.prod.yml (copied by Ansible / the workflow).
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/student-app}"
USE_LOCAL_MYSQL="${USE_LOCAL_MYSQL:-true}"
RENDER_ENV="${RENDER_ENV:-true}"
HERE="$(cd "$(dirname "$0")" && pwd)"

IMAGE="${1:?usage: deploy-pull-image.sh <image-uri>|rollback}"
if [[ "$IMAGE" == "rollback" ]]; then
    IMAGE="$(cat "$APP_DIR/PREVIOUS_RELEASE")"
    echo "↩ rolling back to $IMAGE"
fi

REGISTRY="${IMAGE%%/*}"
if [[ "$REGISTRY" == *.dkr.ecr.*.amazonaws.com ]]; then
    REGION="$(cut -d. -f4 <<<"$REGISTRY")"
    aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
fi

if [[ "$RENDER_ENV" == "true" ]]; then
    APP_DIR="$APP_DIR" "$HERE/render-env-from-ssm.sh"
fi

export APP_IMAGE="$IMAGE"
export APP_ENV_FILE="$APP_DIR/app.env"
export MYSQL_ENV_FILE="$APP_DIR/mysql.env"
compose() { docker compose -f "$APP_DIR/docker-compose.prod.yml" "$@"; }

echo "▶ pulling $IMAGE"
compose pull app

if [[ "$USE_LOCAL_MYSQL" == "true" ]]; then
    compose up -d --wait mysql
fi

echo "▶ migrations"
compose run --rm --no-deps app php artisan migrate --force

echo "▶ recreate app"
compose up -d --no-deps --wait app
echo "▶ live: $(curl -fsS -m 5 http://127.0.0.1/ready)"

if [[ -f "$APP_DIR/CURRENT_RELEASE" && "$(cat "$APP_DIR/CURRENT_RELEASE")" != "$IMAGE" ]]; then
    cp "$APP_DIR/CURRENT_RELEASE" "$APP_DIR/PREVIOUS_RELEASE"
fi
echo "$IMAGE" > "$APP_DIR/CURRENT_RELEASE"
docker image prune -af --filter "until=168h" >/dev/null
echo "✔ deployed $IMAGE"
