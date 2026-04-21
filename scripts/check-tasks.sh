#!/usr/bin/env bash
# Usage: ./scripts/check-tasks.sh
# Outputs shell variables for ddd-workflow.yml:
#   has_todo, done_count, todo_count, in_progress, abandoned_count

set -euo pipefail

SPECS_DIR=".specify/specs"
FEATURE_DIR=$(find "$SPECS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n 1)

if [ -z "$FEATURE_DIR" ] || [ ! -f "$FEATURE_DIR/tasks.md" ]; then
  echo "has_todo=false"; echo "done_count=0"; echo "todo_count=0"
  echo "in_progress="; echo "abandoned_count=0"; exit 0
fi

TASKS_FILE="$FEATURE_DIR/tasks.md"
DONE_COUNT=$(grep -c "^Status: DONE" "$TASKS_FILE" 2>/dev/null || echo 0)
TODO_COUNT=$(grep -c "^Status: TODO" "$TASKS_FILE" 2>/dev/null || echo 0)
IN_PROGRESS=$(grep -B1 "^Status: IN_PROGRESS" "$TASKS_FILE" 2>/dev/null | grep "^## TASK" | head -1 | sed 's/^## //' || true)
ABANDONED_COUNT=$(grep -c "^Status: ABANDONED" "$TASKS_FILE" 2>/dev/null || echo 0)

if [ -n "$IN_PROGRESS" ]; then
  echo "WARNING: Status: IN_PROGRESS found — previous session interrupted." >&2
  echo "  Task: $IN_PROGRESS" >&2
  echo "  Mark it TODO to restart, or ABANDONED to discard partial work." >&2
fi

if [ "$ABANDONED_COUNT" -gt 0 ]; then
  echo "WARNING: $ABANDONED_COUNT ABANDONED task(s) — review and clean up partial files." >&2
fi

[ "$TODO_COUNT" -gt 0 ] && HAS_TODO="true" || HAS_TODO="false"

echo "has_todo=$HAS_TODO"
echo "done_count=$DONE_COUNT"
echo "todo_count=$TODO_COUNT"
echo "in_progress=$IN_PROGRESS"
echo "abandoned_count=$ABANDONED_COUNT"
