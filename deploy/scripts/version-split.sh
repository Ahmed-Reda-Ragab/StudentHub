#!/usr/bin/env bash
# version-split.sh — send N requests and show which release answered (blue/green, canary, A/B).
#
#   ./version-split.sh http://<host>/ready 200
#   ./version-split.sh http://<host>/sre-lab/version 100 "X-Lab-Token: $SRE_LAB_TOKEN"
set -uo pipefail

URL="${1:-http://localhost/ready}"
COUNT="${2:-100}"
HEADER="${3:-}"

declare -A seen=()
failed=0

for _ in $(seq 1 "$COUNT"); do
    body=$(curl -s -m 3 ${HEADER:+-H "$HEADER"} -c /dev/null "$URL") || { failed=$(( failed + 1 )); continue; }
    version=$(grep -o '"version":"[^"]*"' <<<"$body" | head -1 | cut -d'"' -f4)
    color=$(grep -o '"color":"[^"]*"' <<<"$body" | head -1 | cut -d'"' -f4)
    key="${version:-n/a}${color:+ ($color)}"
    seen["$key"]=$(( ${seen["$key"]:-0} + 1 ))
done

echo "requests: $COUNT  failed: $failed"
for key in "${!seen[@]}"; do
    awk -v k="$key" -v n="${seen[$key]}" -v t="$COUNT" 'BEGIN { printf "  %-32s %5d  (%.1f%%)\n", k, n, n * 100 / t }'
done
