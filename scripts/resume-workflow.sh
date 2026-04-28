#!/usr/bin/env bash
# Resume a paused workflow by resetting task state
set -euo pipefail

FEATURE_DIR=$(bash scripts/find-first-feature.sh)

if [ -z "$FEATURE_DIR" ] || [ ! -d "$FEATURE_DIR" ]; then
  echo "No feature directory found. Nothing to resume."
  exit 0
fi

STATE_FILE="$FEATURE_DIR/workflow_state.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "No paused workflow found. Nothing to resume."
  exit 0
fi

echo "Workflow was paused. Resuming..."

# Parse workflow_state.json to find the paused step
PAUSED_STEP=$(grep '"step"' "$STATE_FILE" | sed 's/.*"step": *"\([^"]*\)".*/\1/')
PAUSED_AT=$(grep '"paused_at"' "$STATE_FILE" | sed 's/.*"paused_at": *"\([^"]*\)".*/\1/')
if [ -n "${PAUSED_STEP:-}" ]; then
  echo "  Paused at step: $PAUSED_STEP"
  echo "  Paused at: $PAUSED_AT"
  echo "  Resume instructions:"
  case "$PAUSED_STEP" in
    review-implement)
      echo "    1. Check for partial files from interrupted implementation"
      echo "    2. Run: /speckit.implement to continue from the current task"
      ;;
    *)
      echo "    1. Review the state of tasks.md"
      echo "    2. Run /speckit.implement to proceed"
      ;;
  esac
fi

# Reset only the first IN_PROGRESS task found
TMPFILE=$(mktemp)
TASK=$(grep "Status: IN_PROGRESS" "$FEATURE_DIR/tasks.md" -B5 | grep "^## TASK" | tail -1 | sed 's/## TASK-\[\([0-9]*\)\].*/\1/')
if [ -n "$TASK" ]; then
  awk -v found_task="$TASK" '
    $0 ~ /^## TASK-/ { task = ""; sub("## TASK-", ""); sub(/\].*/, ""); task = $0 }
    task == found_task && $0 ~ /^Status: IN_PROGRESS$/ { print "Status: TODO"; task = ""; next }
    { print }
  ' "$FEATURE_DIR/tasks.md" > "$TMPFILE"
  mv "$TMPFILE" "$FEATURE_DIR/tasks.md"
  echo "Reset TASK-$TASK to TODO. Run /speckit.implement to continue."
else
  echo "No IN_PROGRESS task found. Workflow may already be at a checkpoint."
  cat "$FEATURE_DIR/tasks.md" > "$TMPFILE"
  mv "$TMPFILE" "$FEATURE_DIR/tasks.md"
fi

# Clean up state file
rm -f "$STATE_FILE"
