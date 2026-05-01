#!/usr/bin/env bash
# Usage: count-stagnation.sh <feature_dir>
# Increments stagnation counter, returns total and whether to force abort
FEATURE_DIR="${1:?}"
STATE_FILE="$FEATURE_DIR/.stagnation_total"
COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
NEW_COUNT=$((COUNT + 1))
echo "$NEW_COUNT" > "$STATE_FILE"
if [ "$NEW_COUNT" -ge 3 ]; then
  echo "FORCE_ABORT=true"
else
  echo "FORCE_ABORT=false"
fi
echo "TOTAL=$NEW_COUNT"
