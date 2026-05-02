#!/usr/bin/env bash
# Usage: bash scripts/set-task-status.sh <tasks_file> <new_status>
# Sets all IN_PROGRESS tasks in tasks.md to <new_status>.
#
# Used by: ddd-workflow.yml (on_restart → TODO, on_abandon → ABANDONED)

set -euo pipefail

TASKS_FILE="${1:?Usage: bash scripts/set-task-status.sh <tasks_file> <new_status> [message]}"
NEW_STATUS="${2:?}"
MESSAGE="${3:-}"

# Use temp file for cross-platform compatibility (GNU sed vs BSD sed).
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
_ESCAPED_STATUS=$(printf '%s\n' "$NEW_STATUS" | sed 's/[&/\]/\\&/g')
sed "s/^Status: IN_PROGRESS$/Status: $_ESCAPED_STATUS/" "$TASKS_FILE" > "$TMPFILE"
mv "$TMPFILE" "$TASKS_FILE"

if [ -n "$MESSAGE" ]; then
  echo "$MESSAGE"
fi
