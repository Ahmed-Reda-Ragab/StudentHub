#!/usr/bin/env bash
# with-probe.sh -- <command...> — run a deployment while probe.sh measures availability.
#
#   deploy/scripts/with-probe.sh -- deploy/ec2/lb/bin/bluegreen.sh student-app:v2
#   PROBE_URL=http://localhost/login MAX_FAILURES=0 deploy/scripts/with-probe.sh -- ./bin/canary.sh img
#   EXPECT_EXIT=2 deploy/scripts/with-probe.sh -- ./bin/canary.sh img      # expect an aborted canary
#
# Env: PROBE_URL (default http://localhost/ready), PROBE_INTERVAL (0.05), MAX_FAILURES (0), EXPECT_EXIT (0)
# Exit: non-zero if the command's exit code != EXPECT_EXIT or the probe saw > MAX_FAILURES failures.
set -uo pipefail

[[ "${1:-}" == "--" ]] && shift
(( $# > 0 )) || { echo "usage: with-probe.sh -- <command...>" >&2; exit 64; }

HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE_URL="${PROBE_URL:-http://localhost/ready}"
PROBE_INTERVAL="${PROBE_INTERVAL:-0.05}"
EXPECT_EXIT="${EXPECT_EXIT:-0}"
export MAX_FAILURES="${MAX_FAILURES:-0}"

stop_file="$(mktemp -u)"
STOP_FILE="$stop_file" bash "$HERE/probe.sh" "$PROBE_URL" 0 "$PROBE_INTERVAL" &
probe_pid=$!
sleep 1

echo "▶ $* (probing $PROBE_URL)"
"$@"
cmd_exit=$?

sleep 2
touch "$stop_file"
wait "$probe_pid"
probe_exit=$?
rm -f "$stop_file"

status=0
if (( cmd_exit != EXPECT_EXIT )); then
    echo "✘ command exited $cmd_exit (expected $EXPECT_EXIT)" >&2
    status=1
fi
if (( probe_exit != 0 )); then
    echo "✘ availability check failed (MAX_FAILURES=$MAX_FAILURES)" >&2
    status=1
fi
(( status == 0 )) && echo "✔ command exit=$cmd_exit as expected, availability within budget"
exit "$status"
