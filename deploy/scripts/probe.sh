#!/usr/bin/env bash
# probe.sh — measure downtime during a deployment.
#
# Sends one request every INTERVAL seconds, counts failures (non 2xx/3xx or no answer)
# and records which release answered (reads "version"/"color" from /ready JSON).
#
#   ./probe.sh http://<host>/ready 120 0.2           # 120 s, 5 req/s, then print a summary
#   STOP_FILE=/tmp/stop ./probe.sh http://localhost/ready 0 &   # run until the file exists (CI)
#   MAX_FAILURES=0 ./probe.sh ...                     # exit 1 if any request failed
#
# Env: TIMEOUT (curl seconds, default 2), OUT (write summary to this file), STOP_FILE, MAX_FAILURES
set -uo pipefail

URL="${1:-http://localhost/ready}"
DURATION="${2:-60}"          # 0 = until STOP_FILE appears or SIGTERM/SIGINT
INTERVAL="${3:-0.2}"
TIMEOUT="${TIMEOUT:-2}"
STOP_FILE="${STOP_FILE:-}"

total=0
failed=0
first_fail=""
last_fail=""
declare -A seen=()
stop=0
trap 'stop=1' TERM INT

started=$(date +%s)
deadline=$(( started + DURATION ))

while (( stop == 0 )); do
    [[ -n "$STOP_FILE" && -f "$STOP_FILE" ]] && break
    (( DURATION > 0 && $(date +%s) >= deadline )) && break

    response=$(curl -s -m "$TIMEOUT" -w $'\n%{http_code}' "$URL" 2>/dev/null)
    code="${response##*$'\n'}"
    body="${response%$'\n'*}"
    total=$(( total + 1 ))

    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        version=$(grep -o '"version":"[^"]*"' <<<"$body" | head -1 | cut -d'"' -f4)
        color=$(grep -o '"color":"[^"]*"' <<<"$body" | head -1 | cut -d'"' -f4)
        key="${version:-n/a}${color:+ ($color)}"
        seen["$key"]=$(( ${seen["$key"]:-0} + 1 ))
    else
        failed=$(( failed + 1 ))
        now=$(date +%T)
        [[ -z "$first_fail" ]] && first_fail="$now"
        last_fail="$now"
        echo "[probe] $now FAIL http=${code:-000}" >&2
    fi

    sleep "$INTERVAL"
done

elapsed=$(( $(date +%s) - started ))
{
    echo "================ probe summary ================"
    echo "url            : $URL"
    echo "duration       : ${elapsed}s"
    echo "requests       : $total"
    echo "failed         : $failed"
    if (( total > 0 )); then
        awk -v t="$total" -v f="$failed" 'BEGIN { printf "availability   : %.3f%%\n", (t - f) * 100 / t }'
    fi
    [[ -n "$first_fail" ]] && echo "failure window : $first_fail → $last_fail"
    echo "answered by    :"
    for key in "${!seen[@]}"; do
        printf "  %-32s %s\n" "$key" "${seen[$key]}"
    done
    echo "==============================================="
} | tee ${OUT:+"$OUT"}

if [[ -n "${MAX_FAILURES:-}" ]] && (( failed > MAX_FAILURES )); then
    echo "[probe] $failed failed requests > MAX_FAILURES=$MAX_FAILURES" >&2
    exit 1
fi
