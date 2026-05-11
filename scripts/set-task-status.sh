#!/usr/bin/env bash
# Sets task status. Delegates to state-engine.sh if state.json exists,
# otherwise falls back to tasks.md manipulation (backward compatible).
#
# Usage:
#   bash scripts/set-task-status.sh <tasks_file> <new_status> [task_id] [message]
#   bash scripts/set-task-status.sh <tasks_file> <new_status> --cascade <task_id> [message]

set -euo pipefail

TASKS_FILE="${1:?Usage: bash scripts/set-task-status.sh <tasks_file> <new_status> [options...]}"; shift
NEW_STATUS="${1:?Usage: bash scripts/set-task-status.sh <tasks_file> <new_status> [options...]}"; shift

# Parse optional args: --cascade, task_id, message
CASCADE=false
TASK_ID=""
MESSAGE=""

REMAINING=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cascade) CASCADE=true ;;
    *) REMAINING+=("$1") ;;
  esac
  shift
done

if [ ${#REMAINING[@]} -ge 1 ]; then TASK_ID="${REMAINING[0]}"; fi
if [ ${#REMAINING[@]} -ge 2 ]; then MESSAGE="${REMAINING[1]}"; fi

FEATURE_DIR="$(cd "$(dirname "$TASKS_FILE")" && pwd)"

# ── Fast path: if state.json exists, delegate to state-engine.sh ──
if [ -f "$FEATURE_DIR/state.json" ]; then
  if [ -n "$TASK_ID" ]; then
    bash scripts/state-engine.sh write "$FEATURE_DIR" "tasks.$TASK_ID.status" "$NEW_STATUS"
  else
    # Legacy mode: set all tasks (set each task found in state.json)
    local_tids=$(bash scripts/state-engine.sh read "$FEATURE_DIR" tasks 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    for tid in $local_tids; do
      local_cur=$(bash scripts/state-engine.sh read "$FEATURE_DIR" "tasks.$tid.status" 2>/dev/null || true)
      if [ "$local_cur" = "IN_PROGRESS" ]; then
        bash scripts/state-engine.sh write "$FEATURE_DIR" "tasks.$tid.status" "$NEW_STATUS"
      fi
    done
  fi
  [ -n "$MESSAGE" ] && echo "$MESSAGE"
  # Also update tasks.md for human readability (regenerate from state.json)
  if [ -f "$FEATURE_DIR/tasks.md" ] && [ -f "$FEATURE_DIR/MIGRATION_DONE" ]; then
    bash scripts/state-engine.sh generate-tasks-md "$FEATURE_DIR" > "${TASKS_FILE}.tmp" 2>/dev/null && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
  fi
  exit 0
fi

# ── Legacy path: tasks.md manipulation (backward compatible) ──
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
_ESCAPED_STATUS=$(printf '%s\n' "$NEW_STATUS" | sed 's/[&/\]/\\&/g')

if [ -n "$TASK_ID" ]; then
  awk -v task="## $TASK_ID" -v status="Status: $_ESCAPED_STATUS" '
    { if (in_task && $0 ~ /^Status: IN_PROGRESS$/) { print status; next } }
    { if ($0 == task) { in_task=1 } else { in_task=0 } print }
  ' "$TASKS_FILE" > "$TMPFILE"

  if [ "$CASCADE" = true ]; then
    DEPENDENTS=$(awk -v dep="TASK-$TASK_ID" '
      /^## TASK-/ { gsub(/^## /, ""); tid = $0; in_task=0 }
      /^Status: (TODO|IN_PROGRESS)$/ { status_line=NR }
      /^Depends on:/ && index($0, dep) { print tid }
    ' "$TASKS_FILE")

    for dep_task in $DEPENDENTS; do
      awk -v task="## $dep_task" -v status="Status: ABANDONED" '
        { if (in_task && $0 ~ /^Status: (TODO|IN_PROGRESS)$/) { print status; next } }
        { if ($0 == task) { in_task=1 } else { in_task=0 } print }
      ' "$TASKS_FILE" > "$TMPFILE"
      mv "$TMPFILE" "$TASKS_FILE"
      echo "Cascaded ABANDONED to $dep_task (depends on $TASK_ID)"
    done
  fi
else
  sed "s/^Status: IN_PROGRESS$/Status: $_ESCAPED_STATUS/" "$TASKS_FILE" > "$TMPFILE"
fi

mv "$TMPFILE" "$TASKS_FILE"
[ -n "$MESSAGE" ] && echo "$MESSAGE"
