#!/usr/bin/env bash
# ValidateService (scenario 37) — /ready (DB ping) must answer 200 AND report the version we just
# deployed; otherwise the deployment fails here, the instance stays out of the target group and
# CodeDeploy rolls back (auto_rollback_configuration).
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/student-app}"
URL="${READY_URL:-http://127.0.0.1/ready}" # compose publishes 80 -> 8080
ATTEMPTS="${ATTEMPTS:-30}"

image="$(tr -d '[:space:]' < "$APP_DIR/release/IMAGE_URI")"
ref="${image%@*}"         # repo:tag@sha256:... -> repo:tag (digest-pinned revisions are fine)
expected="${ref##*:}"     # APP_VERSION baked into the image = git short SHA

for ((i = 1; i <= ATTEMPTS; i++)); do
    if body="$(curl -fsS -m 5 "$URL" 2>/dev/null)"; then
        version="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' <<<"$body")"
        if [[ "$version" == "$expected" ]]; then
            echo "ready: $body"
            exit 0
        fi
        echo "attempt $i: ready but version '$version' != '$expected'"
    else
        echo "attempt $i: $URL not ready yet"
    fi
    sleep 5
done

echo "validation failed after $ATTEMPTS attempts" >&2
docker compose -f "$APP_DIR/docker-compose.prod.yml" logs --tail 50 app >&2 || true
exit 1
