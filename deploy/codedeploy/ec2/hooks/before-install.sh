#!/usr/bin/env bash
# BeforeInstall (scenario 37) — make sure the host can run the release, start from a clean bundle dir.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/student-app}"

# Prerequisites installed by deploy/ec2/user-data.sh (or the golden AMI).
systemctl is-active --quiet docker || systemctl start docker
docker compose version >/dev/null
command -v aws >/dev/null || { echo "AWS CLI missing on the instance" >&2; exit 1; }

mkdir -p "$APP_DIR"

# ASG instances boot the app with a plain `docker run --name student-app -p 80:8080`
# (infra/terraform/modules/asg-app user data). From the first CodeDeploy revision on,
# compose owns the app — remove the boot container so port 80 is free. Traffic is
# already blocked for this instance at this point (BlockTraffic runs before BeforeInstall).
if docker ps -a --format '{{.Names}}' | grep -qx student-app; then
    echo "removing the user-data container 'student-app' (compose takes over)"
    docker rm -f student-app >/dev/null
fi

# Old hooks/scripts must not survive into the new release.
rm -rf "$APP_DIR/release"
echo "ready for the new revision in $APP_DIR/release"
