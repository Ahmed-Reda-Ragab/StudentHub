#!/usr/bin/env bash
# run-migrations.sh — run `php artisan migrate --force` ONCE per release as a one-off ECS task
# (CONVENTIONS §2: never on every replica at boot) and fail when the container exits non-zero.
# Scenarios 53-55, 58. Used by .github/workflows/deploy-ecs.yml and deploy/codebuild/buildspec-deploy-ecs.yml.
#
#   deploy/ecs/run-migrations.sh --cluster student-app-lab --service student-app-lab-app \
#       [--task-definition <arn|family:revision>] [--network-configuration '<json>'] \
#       [--capacity-provider FARGATE] [--timeout 900]
#
# Env fallbacks: ECS_CLUSTER, ECS_SERVICE, TASK_DEFINITION, NETWORK_CONFIGURATION, CAPACITY_PROVIDER.
#   no --task-definition        -> the service's current revision (re-run migrations of the live release)
#   no --network-configuration  -> the service's own subnets / security groups / public-IP setting
set -euo pipefail

CLUSTER="${ECS_CLUSTER:-}"
SERVICE="${ECS_SERVICE:-}"
TASK_DEFINITION="${TASK_DEFINITION:-}"
NETWORK_CONFIGURATION="${NETWORK_CONFIGURATION:-}"
# On-demand on purpose: a Spot reclaim must never kill a migration halfway through.
CAPACITY_PROVIDER="${CAPACITY_PROVIDER:-FARGATE}"
CONTAINER_NAME="${CONTAINER_NAME:-app}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
POLL_SECONDS=10
COMMAND_JSON='["php","artisan","migrate","--force"]'

usage() { sed -n '2,13p' "$0"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --service) SERVICE="$2"; shift 2 ;;
        --task-definition) TASK_DEFINITION="$2"; shift 2 ;;
        --network-configuration) NETWORK_CONFIGURATION="$2"; shift 2 ;;
        --capacity-provider) CAPACITY_PROVIDER="$2"; shift 2 ;;
        --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

for bin in aws jq; do
    command -v "$bin" >/dev/null || { echo "$bin is required" >&2; exit 69; }
done
: "${CLUSTER:?--cluster (or ECS_CLUSTER) is required}"

# ---------------------------------------------------------------- resolve defaults from the service
if [[ -z "$TASK_DEFINITION" || -z "$NETWORK_CONFIGURATION" ]]; then
    : "${SERVICE:?--service (or ECS_SERVICE) is required to derive the task definition / network configuration}"
    svc="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --output json)"
    # CODE_DEPLOY services keep both settings on the PRIMARY task set, not on the service.
    primary='((.taskSets // []) | map(select(.status == "PRIMARY")) | .[0])'
    if [[ -z "$TASK_DEFINITION" ]]; then
        TASK_DEFINITION="$(jq -r ".services[0] | ($primary.taskDefinition // .taskDefinition)" <<<"$svc")"
    fi
    if [[ -z "$NETWORK_CONFIGURATION" ]]; then
        NETWORK_CONFIGURATION="$(jq -c ".services[0] | (.networkConfiguration // $primary.networkConfiguration)" <<<"$svc")"
    fi
fi
if [[ -z "$TASK_DEFINITION" || "$TASK_DEFINITION" == "null" ]]; then
    echo "could not resolve a task definition (service $SERVICE in $CLUSTER not found?)" >&2
    exit 66
fi
if [[ -z "$NETWORK_CONFIGURATION" || "$NETWORK_CONFIGURATION" == "null" ]]; then
    echo "could not resolve the network configuration; pass --network-configuration" >&2
    exit 66
fi

# ---------------------------------------------------------------- start the one-off task
overrides="$(jq -cn --arg name "$CONTAINER_NAME" --argjson cmd "$COMMAND_JSON" \
    '{containerOverrides: [{name: $name, command: $cmd}]}')"

echo "▶ migrations with ${TASK_DEFINITION##*/} on $CLUSTER ($CAPACITY_PROVIDER)"
run="$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --task-definition "$TASK_DEFINITION" \
    --capacity-provider-strategy "capacityProvider=$CAPACITY_PROVIDER,weight=1" \
    --network-configuration "$NETWORK_CONFIGURATION" \
    --overrides "$overrides" \
    --started-by "migrations" \
    --enable-ecs-managed-tags \
    --propagate-tags TASK_DEFINITION \
    --output json)"

if [[ "$(jq '.failures | length' <<<"$run")" -gt 0 ]]; then
    echo "run-task failed:" >&2
    jq '.failures' <<<"$run" >&2
    exit 1
fi
task_arn="$(jq -r '.tasks[0].taskArn' <<<"$run")"
task_id="${task_arn##*/}"
echo "  task $task_id"

# ---------------------------------------------------------------- wait (own loop: the CLI waiter gives up after 10 min)
deadline=$((SECONDS + TIMEOUT_SECONDS))
status=""
while ((SECONDS < deadline)); do
    status="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
        --query 'tasks[0].lastStatus' --output text)"
    [[ "$status" == "STOPPED" ]] && break
    sleep "$POLL_SECONDS"
done
if [[ "$status" != "STOPPED" ]]; then
    echo "✖ migration task $task_id still $status after ${TIMEOUT_SECONDS}s (left running on purpose — a killed migration is worse)" >&2
    exit 1
fi

desc="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" --output json)"
exit_code="$(jq -r --arg name "$CONTAINER_NAME" \
    '.tasks[0].containers[] | select(.name == $name) | (.exitCode // "none")' <<<"$desc")"
stopped_reason="$(jq -r '.tasks[0].stoppedReason // ""' <<<"$desc")"

# ---------------------------------------------------------------- show the migration output (best effort)
logcfg="$(aws ecs describe-task-definition --task-definition "$TASK_DEFINITION" \
    --query "taskDefinition.containerDefinitions[?name=='$CONTAINER_NAME'] | [0].logConfiguration.options" \
    --output json 2>/dev/null || echo null)"
log_group="$(jq -r '.["awslogs-group"] // empty' <<<"$logcfg" 2>/dev/null || true)"
log_prefix="$(jq -r '.["awslogs-stream-prefix"] // empty' <<<"$logcfg" 2>/dev/null || true)"
if [[ -n "$log_group" && -n "$log_prefix" ]]; then
    stream="$log_prefix/$CONTAINER_NAME/$task_id"
    echo "── $log_group  $stream"
    aws logs get-log-events --log-group-name "$log_group" --log-stream-name "$stream" \
        --start-from-head --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' | tail -n 50 || true
    echo "──"
fi

if [[ "$exit_code" != "0" ]]; then
    echo "✖ migrations failed: exit code $exit_code; $stopped_reason" >&2
    exit 1
fi
echo "✔ migrations done ($task_id)"
