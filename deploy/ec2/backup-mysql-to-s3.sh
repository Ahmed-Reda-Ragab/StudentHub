#!/usr/bin/env bash
# backup-mysql-to-s3.sh — scenario 27: logical backup of the MySQL *container* to S3.
#
#   BACKUP_BUCKET=student-app-lab-backups-123456789012 ./backup-mysql-to-s3.sh
#   ./backup-mysql-to-s3.sh restore s3://bucket/mysql/student_app-2026-11-21T0300.sql.gz
#
# Scheduled by the Ansible role `mysql_backup` (systemd timer). Lifecycle rules on the
# bucket expire old dumps. RDS (scenario 41+) replaces this with automated backups + PITR.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/student-app}"
COMPOSE_FILE="${COMPOSE_FILE:-$APP_DIR/docker-compose.prod.yml}"
BUCKET="${BACKUP_BUCKET:?set BACKUP_BUCKET}"
DB="${DB_NAME:-student_app}"
export APP_ENV_FILE="$APP_DIR/app.env" MYSQL_ENV_FILE="$APP_DIR/mysql.env"
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

if [[ "${1:-}" == "restore" ]]; then
    SRC="${2:?usage: restore s3://bucket/key.sql.gz}"
    echo "⚠ restoring $SRC into $DB (overwrites data)"
    aws s3 cp "$SRC" - | gunzip | compose exec -T mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" $DB"
    echo "✔ restore complete — verify with: curl -s http://127.0.0.1/ready"
    exit 0
fi

KEY="mysql/${DB}-$(date -u +%Y-%m-%dT%H%M).sql.gz"
start=$(date +%s)
# Stream to a .partial key first: if mysqldump dies half-way (pipefail), the truncated object
# must never look like the newest good backup. Only a complete dump is moved to its final key.
if compose exec -T mysql sh -c "mysqldump --single-transaction --quick --routines --triggers -uroot -p\"\$MYSQL_ROOT_PASSWORD\" $DB" \
    | gzip -9 \
    | aws s3 cp - "s3://$BUCKET/$KEY.partial" --sse AES256; then
    aws s3 mv "s3://$BUCKET/$KEY.partial" "s3://$BUCKET/$KEY" --sse AES256 >/dev/null
    echo "✔ s3://$BUCKET/$KEY ($(( $(date +%s) - start ))s)"
else
    aws s3 rm "s3://$BUCKET/$KEY.partial" >/dev/null 2>&1 || true
    echo "✘ backup FAILED — nothing published under s3://$BUCKET/$KEY" >&2
    exit 1
fi
