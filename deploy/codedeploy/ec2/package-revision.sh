#!/usr/bin/env bash
# package-revision.sh — assemble the scenario-37 CodeDeploy revision (no source code, just the
# image reference + deploy scripts) into a directory ready for `aws deploy push`.
#
#   dir=$(deploy/codedeploy/ec2/package-revision.sh <account>.dkr.ecr.us-east-1.amazonaws.com/student-app:3f2c1ab)
#   aws deploy push --application-name student-app-lab-ec2 \
#       --s3-location "s3://<bucket>/codedeploy/student-app-3f2c1ab.zip" --source "$dir"
#
# Options: --env <name> (default lab), --local-mysql (single host with the mysql container),
#          --out <dir> (default: a new temp dir).
set -euo pipefail

ENV_NAME="lab"
USE_LOCAL_MYSQL="false"
OUT=""
IMAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_NAME="$2"; shift 2 ;;
        --local-mysql) USE_LOCAL_MYSQL="true"; shift ;;
        --out) OUT="$2"; shift 2 ;;
        -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
        -*) echo "unknown option $1" >&2; exit 64 ;;
        *) IMAGE="$1"; shift ;;
    esac
done

if [[ -z "$IMAGE" || "$IMAGE" != *:* || "$IMAGE" == *:latest ]]; then
    echo "usage: $0 <image-uri with an immutable tag> [--env lab] [--local-mysql] [--out dir]" >&2
    exit 64
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT/hooks" "$OUT/scripts"

cp "$HERE/appspec.yml" "$OUT/"
cp "$HERE"/hooks/*.sh "$OUT/hooks/"
cp "$ROOT/deploy/ec2/deploy-pull-image.sh" "$ROOT/deploy/ec2/render-env-from-ssm.sh" "$OUT/scripts/"
cp "$ROOT/docker-compose.prod.yml" "$OUT/"
printf '%s\n' "$IMAGE" > "$OUT/IMAGE_URI"
printf 'USE_LOCAL_MYSQL=%s\nENV_NAME=%s\n' "$USE_LOCAL_MYSQL" "$ENV_NAME" > "$OUT/deploy.env"
# The agent executes hooks directly: the zip must carry the executable bit.
chmod 0755 "$OUT"/hooks/*.sh "$OUT"/scripts/*.sh

echo "$OUT"
