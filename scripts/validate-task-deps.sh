#!/usr/bin/env bash
# Validates that a task's dependencies are still satisfied.
# Called during crash recovery to ensure IN_PROGRESS tasks can proceed.
#
# Usage: validate-task-deps.sh <tasks_file> <task_id>
# Outputs: DEPS_OK=true|false, BROKEN_DEPS=<comma-separated list>

set -euo pipefail

TASKS_FILE="${1:?Usage: validate-task-deps.sh <tasks_file> <task_id>}"
TASK_ID="${2:?}"

if [ ! -f "$TASKS_FILE" ]; then
  echo "DEPS_OK=false"
  echo "BROKEN_DEPS=missing_tasks_file"
  exit 1
fi

# Find the Depends-on line for this task
# Use two-pass approach: first find the task block, then look for Depends on:
DEPS_LINE=$(awk -v tid="## $TASK_ID" '
  $0 == tid { in_task=1; next }
  in_task && /^Status:/ { next }
  in_task && /^Depends on:/ { print; exit }
  in_task && /^## / { exit }
  /^## / { in_task=0 }
' "$TASKS_FILE")
DEPS=$(echo "$DEPS_LINE" | sed 's/^Depends on: //')

if [ "$DEPS" = "none" ] || [ -z "$DEPS" ]; then
  echo "DEPS_OK=true"
  echo "BROKEN_DEPS="
  exit 0
fi

BROKEN=""
IFS=',' read -ra dep_list <<< "$DEPS"
for dep in "${dep_list[@]}"; do
  dep=$(echo "$dep" | xargs)
  # Check if this dependency task exists and is DONE
  DEP_STATUS=$(awk -v dep="## TASK-$dep" '
    $0 == dep { found=1; next }
    found && /^Status: / { gsub(/^Status: /, ""); print; exit }
    found && /^## / { exit }
  ' "$TASKS_FILE")

  if [ "$DEP_STATUS" != "DONE" ]; then
    if [ -n "$BROKEN" ]; then
      BROKEN="$BROKEN,$dep"
    else
      BROKEN="$dep"
    fi
  fi
done

if [ -n "$BROKEN" ]; then
  echo "DEPS_OK=false"
  echo "BROKEN_DEPS=$BROKEN"
  echo "WARNING: Task $TASK_ID depends on $BROKEN which is not DONE." >&2
  exit 1
else
  echo "DEPS_OK=true"
  echo "BROKEN_DEPS="
fi
