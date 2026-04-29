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

# Reset ALL IN_PROGRESS tasks to TODO (multiple = workflow corruption)
TMPFILE=$(mktemp)
# Find all IN_PROGRESS tasks and reset them
IN_PROGRESS_TASKS=$(grep -B1 "^Status: IN_PROGRESS$" "$FEATURE_DIR/tasks.md" 2>/dev/null | grep "^## TASK" | sed 's/^## //' || true)

if [ -n "$IN_PROGRESS_TASKS" ]; then
  # Build awk script to reset all IN_PROGRESS tasks
  awk '
    /^Status: IN_PROGRESS$/ { print "Status: TODO"; next }
    { print }
  ' "$FEATURE_DIR/tasks.md" > "$TMPFILE"
  mv "$TMPFILE" "$FEATURE_DIR/tasks.md"

  if echo "$IN_PROGRESS_TASKS" | grep -q ','; then
    echo "Reset ALL IN_PROGRESS tasks to TODO (multiple detected):"
    echo "$IN_PROGRESS_TASKS" | tr ',' '\n' | while read -r task; do
      echo "  - $task"
    done
  else
    echo "Reset TASK-$IN_PROGRESS_TASKS to TODO. Run /speckit.implement to continue."
  fi
else
  echo "No IN_PROGRESS task found. Workflow may already be at a checkpoint."
  rm -f "$TMPFILE"
fi

# Clean up state file
rm -f "$STATE_FILE"
