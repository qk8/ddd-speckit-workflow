#!/usr/bin/env bash
# Detects implementation stagnation: no tasks completed for N consecutive iterations.
# Usage: check-stagnation.sh <feature_dir> <current_done> <total_tasks>
# Outputs: STAGNANT=true|false, CONSECUTIVE_NO_PROGRESS=N
set -euo pipefail

FEATURE_DIR="${1:?Usage: check-stagnation.sh <feature_dir> <current_done> <total_tasks>}"
CURRENT_DONE="${2:?}"
TOTAL_TASKS="${3:?}"

STATE_FILE="$FEATURE_DIR/.stagnation_state"
CONSEC_FILE="$STATE_FILE.consec"
mkdir -p "$FEATURE_DIR"

PREV_DONE=$(cat "$STATE_FILE" 2>/dev/null || echo "-1")
CONSECUTIVE=$(cat "$CONSEC_FILE" 2>/dev/null || echo 0)

if [ "$CURRENT_DONE" -gt "$PREV_DONE" ]; then
  echo "STAGNANT=false"
  echo "$CURRENT_DONE" > "$STATE_FILE"
  echo "0" > "$CONSEC_FILE"
elif [ "$TOTAL_TASKS" -eq 0 ] || [ "$PREV_DONE" -eq -1 ]; then
  echo "STAGNANT=false"
  echo "$CURRENT_DONE" > "$STATE_FILE"
  echo "0" > "$CONSEC_FILE"
else
  NEW_CONSEC=$((CONSECUTIVE + 1))
  echo "$NEW_CONSEC" > "$CONSEC_FILE"
  echo "$CURRENT_DONE" > "$STATE_FILE"
  if [ "$NEW_CONSEC" -ge 3 ]; then
    echo "STAGNANT=true"
    echo "CONSECUTIVE_NO_PROGRESS=$NEW_CONSEC"
  else
    echo "STAGNANT=false"
    echo "CONSECUTIVE_NO_PROGRESS=$NEW_CONSEC"
  fi
fi
