#!/usr/bin/env bash
# ApplicationStart (scenario 37) — reuse the scenario 32/33 deploy script: ECR login, render app.env
# from SSM, pull, `php artisan migrate --force` (one-off), recreate the container, record the release.
#
# Migrations run on every instance, but with CodeDeployDefault.OneAtATime only the first one has
# work to do; the others find nothing pending. Use AllAtOnce only with idempotent, lock-safe migrations.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/student-app}"
RELEASE="$APP_DIR/release"

# deploy.env is written by package-revision.sh: USE_LOCAL_MYSQL, ENV_NAME.
if [[ -f "$RELEASE/deploy.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$RELEASE/deploy.env"
    set +a
fi
export APP_DIR
export USE_LOCAL_MYSQL="${USE_LOCAL_MYSQL:-false}" # stack 40 uses RDS
export ENV_NAME="${ENV_NAME:-lab}"

# docker compose loads every service's env_file, even for `up app`: with RDS there are no
# /student-app/<env>/mysql/* parameters, so make sure an (empty) mysql.env exists.
[[ -f "$APP_DIR/mysql.env" ]] || install -m 0600 /dev/null "$APP_DIR/mysql.env"

image="$(tr -d '[:space:]' < "$RELEASE/IMAGE_URI")"
echo "deploying $image (env=$ENV_NAME, local mysql=$USE_LOCAL_MYSQL)"
"$RELEASE/scripts/deploy-pull-image.sh" "$image"
