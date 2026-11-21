#!/usr/bin/env bash
# AfterInstall (scenario 37) — validate the bundle and put the compose file where
# deploy/ec2/deploy-pull-image.sh expects it.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/student-app}"
RELEASE="$APP_DIR/release"

image="$(tr -d '[:space:]' < "$RELEASE/IMAGE_URI")"
if [[ -z "$image" || "$image" != *:* || "$image" == *:latest ]]; then
    echo "IMAGE_URI must be an immutable tag (git short SHA), got '$image'" >&2
    exit 1
fi

chmod 0755 "$RELEASE"/scripts/*.sh "$RELEASE"/hooks/*.sh
install -m 0644 "$RELEASE/docker-compose.prod.yml" "$APP_DIR/docker-compose.prod.yml"
echo "release staged: $image"
