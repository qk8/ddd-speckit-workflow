#!/usr/bin/env bash
# Resolve ALL IN_PROGRESS tasks, not just the first one.
# Called by the workflow when multiple tasks are stuck from a crash.
#
# Usage: resolve-all-in-progress.sh <tasks_file> <action> [message]
# Actions: TODO (restart all), ABANDONED (cascade abandon all)

set -euo pipefail

# Determine repo root (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TASKS_FILE="${1:?Usage: resolve-all-in-progress.sh <tasks_file> <action> [message]}"
ACTION="${2:?}"
MESSAGE="${3:-}"

if [ ! -f "$TASKS_FILE" ]; then
  echo "ERROR: tasks.md not found" >&2
  exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# Find ALL IN_PROGRESS task IDs
# Uses two-pass approach to avoid awk single-pass pattern interaction bugs
IN_PROGRESS_TASKS=$(awk '
  /^## TASK-/ { header = $0 }
  /^Status: IN_PROGRESS$/ {
    tmp = header
    gsub(/^## /, "", tmp)
    print tmp
  }
' "$TASKS_FILE")

COUNT=0
while IFS= read -r task_id; do
  [ -z "$task_id" ] && continue
  bash "$REPO_ROOT/scripts/set-task-status.sh" "$TASKS_FILE" "$ACTION" "$task_id" "$MESSAGE" >/dev/null 2>&1 || true
  COUNT=$((COUNT + 1))
done <<< "$IN_PROGRESS_TASKS"

# If cascade mode, also cascade abandon dependents for each
if [ "$ACTION" = "ABANDONED" ] && [ -n "$IN_PROGRESS_TASKS" ]; then
  while IFS= read -r task_id; do
    [ -z "$task_id" ] && continue
    bash "$REPO_ROOT/scripts/set-task-status.sh" "$TASKS_FILE" "ABANDONED" --cascade "$task_id" "Cascade from crash recovery" >/dev/null 2>&1 || true
  done <<< "$IN_PROGRESS_TASKS"
fi

echo "RESOLVED_ALL=$COUNT"
