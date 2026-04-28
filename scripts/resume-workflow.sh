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

echo "Workflow was paused. Resuming by marking current task as TODO (was IN_PROGRESS)..."

# Reset the task that was being worked on
TASK=$(grep "Status: IN_PROGRESS" "$FEATURE_DIR/tasks.md" -B5 | grep "## TASK" | tail -1 | sed 's/## TASK-\[\([0-9]*\)\].*/\1/')
if [ -n "$TASK" ]; then
  sed -i "s/Status: IN_PROGRESS/Status: TODO/" "$FEATURE_DIR/tasks.md"
  echo "Reset TASK-$TASK to TODO. Run /speckit.implement to continue."
else
  echo "No IN_PROGRESS task found. Workflow may already be at a checkpoint."
fi

# Clean up state file
rm -f "$STATE_FILE"
