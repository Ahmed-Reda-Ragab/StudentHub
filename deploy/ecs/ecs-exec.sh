#!/usr/bin/env bash
# ecs-exec.sh — shell (or one command) inside a running app task via ECS Exec, no SSH (scenario 52).
#
#   deploy/ecs/ecs-exec.sh                                  # /bin/sh in the first RUNNING task
#   deploy/ecs/ecs-exec.sh -- php artisan about             # one command
#   deploy/ecs/ecs-exec.sh --task 0123abcd -- php artisan migrate:status
#   deploy/ecs/ecs-exec.sh --cluster student-app-lab --service student-app-lab-app
#
# Needs AWS CLI v2 + session-manager-plugin locally and enable_execute_command = true on the service.
# Env fallbacks: ECS_CLUSTER, ECS_SERVICE, CONTAINER_NAME.
set -euo pipefail

CLUSTER="${ECS_CLUSTER:-student-app-lab}"
SERVICE="${ECS_SERVICE:-student-app-lab-app}"
CONTAINER="${CONTAINER_NAME:-app}"
TASK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --service) SERVICE="$2"; shift 2 ;;
        --task) TASK="$2"; shift 2 ;;
        --container) CONTAINER="$2"; shift 2 ;;
        --) shift; break ;;
        -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1 (put the command after --)" >&2; exit 64 ;;
    esac
done
COMMAND="${*:-/bin/sh}"

command -v session-manager-plugin >/dev/null ||
    { echo "install the Session Manager plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2; exit 69; }

if [[ -z "$TASK" ]]; then
    TASK="$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING \
        --query 'taskArns[0]' --output text)"
    if [[ -z "$TASK" || "$TASK" == "None" ]]; then
        echo "no RUNNING task in $CLUSTER/$SERVICE" >&2
        exit 66
    fi
fi

# Exec is decided when a task STARTS: tasks launched before enable_execute_command need a redeploy.
read -r exec_enabled agent_status < <(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" \
    --query "tasks[0].[enableExecuteCommand, containers[?name=='$CONTAINER'] | [0].managedAgents[?name=='ExecuteCommandAgent'] | [0].lastStatus]" \
    --output text)
if [[ "$exec_enabled" != "True" ]]; then
    echo "ECS Exec is off for ${TASK##*/}. Start new tasks: aws ecs update-service --cluster $CLUSTER --service $SERVICE --force-new-deployment" >&2
    exit 1
fi
if [[ "$agent_status" != "RUNNING" ]]; then
    echo "warning: ExecuteCommandAgent is '$agent_status' (task still starting, or the task role lacks ssmmessages:*)" >&2
fi

echo "▶ ${TASK##*/} [$CONTAINER] \$ $COMMAND"
exec aws ecs execute-command --cluster "$CLUSTER" --task "$TASK" --container "$CONTAINER" \
    --interactive --command "$COMMAND"
