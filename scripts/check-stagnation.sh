#!/usr/bin/env bash
# Detects implementation stagnation: no tasks completed for N consecutive iterations.
# Usage: check-stagnation.sh <feature_dir> <current_done> <total_tasks>
#        check-stagnation.sh --reset <feature_dir>
# Outputs: STAGNANT=true|false, CONSECUTIVE_NO_PROGRESS=N
set -euo pipefail

RESET_MODE=false
if [ "${1:-}" = "--reset" ]; then
  RESET_MODE=true
  FEATURE_DIR="${2:?Usage: check-stagnation.sh --reset <feature_dir>}"
else
  FEATURE_DIR="${1:?Usage: check-stagnation.sh <feature_dir> <current_done> <total_tasks>}"
  CURRENT_DONE="${2:?}"
  TOTAL_TASKS="${3:?}"
fi

STATE_FILE="$FEATURE_DIR/.stagnation_state"
CONSEC_FILE="$STATE_FILE.consec"
mkdir -p "$FEATURE_DIR"

if [ "$RESET_MODE" = true ]; then
  # Atomic reset: write both values to temp file, then mv
  TMPFILE=$(mktemp)
  echo "0" > "$TMPFILE"
  echo "0" >> "$TMPFILE"
  mv "$TMPFILE" "$STATE_FILE"
  echo "0" > "$CONSEC_FILE"
  echo "STAGNANT=false"
  echo "CONSECUTIVE_NO_PROGRESS=0"
  exit 0
fi

PREV_DONE=$(cat "$STATE_FILE" 2>/dev/null || echo "-1")
# Validate PREV_DONE is numeric; default to -1 if not
case "$PREV_DONE" in
  ''|*[!0-9-]*) PREV_DONE=-1 ;;
esac
CONSECUTIVE=$(cat "$CONSEC_FILE" 2>/dev/null || echo 0)
# Validate CONSECUTIVE is numeric; default to 0 if not
case "$CONSECUTIVE" in
  ''|*[!0-9]*) CONSECUTIVE=0 ;;
esac

if [ "$CURRENT_DONE" -gt "$PREV_DONE" ]; then
  echo "STAGNANT=false"
  TMPFILE=$(mktemp)
  echo "$CURRENT_DONE" > "$TMPFILE"
  mv "$TMPFILE" "$STATE_FILE"
  echo "0" > "$CONSEC_FILE"
elif [ "$TOTAL_TASKS" -eq 0 ] || [ "$PREV_DONE" -eq -1 ]; then
  echo "STAGNANT=false"
  TMPFILE=$(mktemp)
  echo "$CURRENT_DONE" > "$TMPFILE"
  mv "$TMPFILE" "$STATE_FILE"
  echo "0" > "$CONSEC_FILE"
else
  NEW_CONSEC=$((CONSECUTIVE + 1))
  echo "$NEW_CONSEC" > "$CONSEC_FILE"
  TMPFILE=$(mktemp)
  echo "$CURRENT_DONE" > "$TMPFILE"
  mv "$TMPFILE" "$STATE_FILE"
  if [ "$NEW_CONSEC" -ge 3 ]; then
    echo "STAGNANT=true"
    echo "CONSECUTIVE_NO_PROGRESS=$NEW_CONSEC"
  else
    echo "STAGNANT=false"
    echo "CONSECUTIVE_NO_PROGRESS=$NEW_CONSEC"
  fi
fi
