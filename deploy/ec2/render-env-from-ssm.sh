#!/usr/bin/env bash
# render-env-from-ssm.sh — write /opt/student-app/{app,mysql}.env from SSM Parameter Store.
#
# Convention (docs/devops/CONVENTIONS.md):
#   /student-app/<env>/app/<ENV_KEY>     → app.env      e.g. /student-app/lab/app/APP_KEY (SecureString)
#   /student-app/<env>/mysql/<ENV_KEY>   → mysql.env    e.g. /student-app/lab/mysql/MYSQL_ROOT_PASSWORD
#
# Needs an instance profile allowing ssm:GetParametersByPath (+ kms:Decrypt for SecureString).
#   ./render-env-from-ssm.sh            # env=lab, dir=/opt/student-app
#   ENV_NAME=staging APP_DIR=/srv/app ./render-env-from-ssm.sh
set -euo pipefail

ENV_NAME="${ENV_NAME:-lab}"
APP_DIR="${APP_DIR:-/opt/student-app}"
PREFIX="/student-app/${ENV_NAME}"

if [[ -z "${AWS_REGION:-}" ]]; then
    token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
    AWS_REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/region)
fi
export AWS_REGION

render() { # section target-file
    local section="$1" target="$2" tmp
    tmp="$(mktemp)"
    aws ssm get-parameters-by-path --path "$PREFIX/$section/" --recursive --with-decryption \
        --query 'Parameters[*].[Name,Value]' --output text \
        | while IFS=$'\t' read -r name value; do
            printf '%s=%s\n' "${name##*/}" "$value"
          done > "$tmp"
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "no parameters under $PREFIX/$section/ — $target left untouched" >&2
        return 0
    fi
    install -m 600 "$tmp" "$target"
    rm -f "$tmp"
    echo "wrote $target ($(wc -l < "$target") keys from $PREFIX/$section/)"
}

mkdir -p "$APP_DIR"
render app "$APP_DIR/app.env"
render mysql "$APP_DIR/mysql.env"
