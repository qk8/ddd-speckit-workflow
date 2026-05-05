#!/usr/bin/env bash
# Sets task status in tasks.md.
#
# Usage:
#   bash scripts/set-task-status.sh <tasks_file> <new_status> [task_id] [message]
#     Per-task mode: only changes the specified task's status.
#   bash scripts/set-task-status.sh <tasks_file> <new_status> --cascade <task_id> [message]
#     Cascade mode: also marks all tasks depending on <task_id> as ABANDONED.
#   bash scripts/set-task-status.sh <tasks_file> <new_status> [message]
#     Legacy mode: changes ALL IN_PROGRESS tasks (backward compatible).
#
# Used by: ddd-workflow.yml (on_restart, on_abandon, on_revise)

set -euo pipefail

TASKS_FILE="${1:?Usage: bash scripts/set-task-status.sh <tasks_file> <new_status> [options...]}"; shift
NEW_STATUS="${1:?Usage: bash scripts/set-task-status.sh <tasks_file> <new_status> [options...]}"; shift

# Parse optional args: --cascade, task_id, message
CASCADE=false
TASK_ID=""
MESSAGE=""

# Collect remaining args
REMAINING=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cascade)
      CASCADE=true
      ;;
    *)
      REMAINING+=("$1")
      ;;
  esac
  shift
done

# Remaining args: [task_id] [message]
if [ ${#REMAINING[@]} -ge 1 ]; then
  TASK_ID="${REMAINING[0]}"
fi
if [ ${#REMAINING[@]} -ge 2 ]; then
  MESSAGE="${REMAINING[1]}"
fi

# Use temp file for cross-platform compatibility (GNU sed vs BSD sed).
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
_ESCAPED_STATUS=$(printf '%s\n' "$NEW_STATUS" | sed 's/[&/\]/\\&/g')

if [ -n "$TASK_ID" ]; then
  # Per-task mode: only change the specified task
  # TASK_ID comes as "TASK-N" format (e.g., "TASK-3")
  awk -v task="## $TASK_ID" -v status="Status: $_ESCAPED_STATUS" '
    {
      if (in_task && $0 ~ /^Status: IN_PROGRESS$/) { print status; next }
    }
    {
      if ($0 == task) { in_task=1 } else { in_task=0 }
      print
    }
  ' "$TASKS_FILE" > "$TMPFILE"

  if [ "$CASCADE" = true ]; then
    # Find tasks that depend on TASK_ID and mark them ABANDONED too
    DEPENDENTS=$(awk -v dep="TASK-$TASK_ID" '
      /^## TASK-/ { gsub(/^## /, ""); tid = $0; in_task=0 }
      /^Status: (TODO|IN_PROGRESS)$/ { status_line=NR }
      /^Depends on:/ && index($0, dep) { print tid }
    ' "$TASKS_FILE")

    for dep_task in $DEPENDENTS; do
      awk -v task="## $dep_task" -v status="Status: ABANDONED" '
        {
          if (in_task && $0 ~ /^Status: (TODO|IN_PROGRESS)$/) { print status; next }
        }
        {
          if ($0 == task) { in_task=1 } else { in_task=0 }
          print
        }
      ' "$TASKS_FILE" > "$TMPFILE"
      mv "$TMPFILE" "$TASKS_FILE"
      echo "Cascaded ABANDONED to $dep_task (depends on $TASK_ID)"
    done
  fi
else
  # Legacy mode: change ALL IN_PROGRESS tasks
  sed "s/^Status: IN_PROGRESS$/Status: $_ESCAPED_STATUS/" "$TASKS_FILE" > "$TMPFILE"
fi

mv "$TMPFILE" "$TASKS_FILE"

if [ -n "$MESSAGE" ]; then
  echo "$MESSAGE"
fi
