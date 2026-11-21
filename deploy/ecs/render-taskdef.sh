#!/usr/bin/env bash
# render-taskdef.sh — print a task definition that `aws ecs register-task-definition` accepts
# (scenarios 53-55, 58). One renderer for GitHub Actions, CodeBuild and humans.
#
#   live  copy the NEWEST ACTIVE revision of a family and swap only the image of container "app".
#         Terraform keeps owning env / secrets / roles / sizing; CI only owns the image.
#         SRE_FAULT_* env vars are DROPPED from the copy (a drill's bad release must never leak
#         into the next deploy); re-add them per deploy with deploy-ecs.yml `extra_env`.
#         KEEP_FAULT_ENV=true keeps them.
#           deploy/ecs/render-taskdef.sh live student-app-lab-app <image-uri>
#           deploy/ecs/render-taskdef.sh live student-app-lab-app '<IMAGE1_NAME>'   # CodeDeployToECS template
#
#   repo  fill the placeholders of a template committed in the repo (task definition as code).
#           AWS_ACCOUNT_ID=123456789012 AWS_REGION=us-east-1 ENV_NAME=lab IMAGE_URI=<uri> \
#             deploy/ecs/render-taskdef.sh repo deploy/ecs/task-definition.json
#         Placeholders: ${AWS_ACCOUNT_ID} ${AWS_REGION} ${ENV_NAME} [${IMAGE_URI}]
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-app}"

usage() {
    sed -n '2,14p' "$0" >&2
    exit 64
}

command -v jq >/dev/null || { echo "jq is required" >&2; exit 69; }

mode="${1:-}"
[[ $# -ge 2 ]] || usage
shift

# Fields describe-task-definition returns but register-task-definition rejects.
READ_ONLY_FIELDS='del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)'

case "$mode" in
    live)
        family="$1"
        image="${2:-}"
        command -v aws >/dev/null || { echo "aws CLI is required" >&2; exit 69; }
        aws ecs describe-task-definition --task-definition "$family" --query taskDefinition --output json |
            jq --arg name "$CONTAINER_NAME" --arg image "$image" --arg keep "${KEEP_FAULT_ENV:-false}" "
                $READ_ONLY_FIELDS
                | if ([.containerDefinitions[].name] | index(\$name)) == null
                  then error(\"container \(\$name) not found in task definition\") else . end
                | if \$keep == \"true\" then .
                  else .containerDefinitions |= map(if .name == \$name
                       then .environment = ((.environment // []) | map(select(.name | startswith(\"SRE_FAULT_\") | not)))
                       else . end) end
                | if \$image == \"\" then .
                  else .containerDefinitions |= map(if .name == \$name then .image = \$image else . end) end"
        ;;
    repo)
        template="$1"
        : "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID is required}" "${AWS_REGION:?AWS_REGION is required}"
        ENV_NAME="${ENV_NAME:-lab}"
        rendered="$(sed \
            -e "s|\${AWS_ACCOUNT_ID}|${AWS_ACCOUNT_ID}|g" \
            -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
            -e "s|\${ENV_NAME}|${ENV_NAME}|g" \
            "$template")"
        if [[ -n "${IMAGE_URI:-}" ]]; then
            rendered="${rendered//\$\{IMAGE_URI\}/$IMAGE_URI}"
        fi
        # Fail loudly instead of registering a definition with a literal "${...}" in it.
        # (${IMAGE_URI} may stay: the GitHub render action sets the image afterwards.)
        # shellcheck disable=SC2016 # literal "${" on purpose
        if grep -v 'IMAGE_URI' <<<"$rendered" | grep -q '\${'; then
            echo "unrendered placeholder left in $template" >&2
            exit 65
        fi
        jq . <<<"$rendered"
        ;;
    *)
        usage
        ;;
esac
