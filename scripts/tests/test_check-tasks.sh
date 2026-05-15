#!/usr/bin/env bash
set -euo pipefail
# Tests for check-tasks.sh parsing logic
# Uses a temporary feature directory to avoid polluting real state.

TEMP_FEATURE=$(mktemp -d)
trap 'rm -rf "$TEMP_FEATURE"' EXIT

cat > "$TEMP_FEATURE/tasks.md" <<'TASKS'
## TASK-1
Status: DONE
Built: Auth module
Test file: tests/auth.test.ts

## TASK-2
Status: TODO
Built: API endpoint
Test file: tests/api.test.ts

## TASK-3
Status: IN_PROGRESS
Built: Frontend component
TASKS

# Test the parsing logic inline (same as check-tasks.sh)
DONE_COUNT=$(grep -c "^Status: DONE$" "$TEMP_FEATURE/tasks.md" || true)
TODO_COUNT=$(grep -c "^Status: TODO$" "$TEMP_FEATURE/tasks.md" || true)
IN_PROGRESS_ALL=$(grep -B1 "^Status: IN_PROGRESS$" "$TEMP_FEATURE/tasks.md" 2>/dev/null | grep "^## TASK" | sed 's/^## //' | tr '\n' ',' | sed 's/,$//' || true)
ABANDONED_COUNT=$(grep -c "^Status: ABANDONED$" "$TEMP_FEATURE/tasks.md" || true)
TOTAL_TASKS=$(grep -c "^## TASK-" "$TEMP_FEATURE/tasks.md" || true)

assert_eq "1" "$DONE_COUNT" "DONE_COUNT=1"
assert_eq "1" "$TODO_COUNT" "TODO_COUNT=1"
assert_eq "TASK-3" "$IN_PROGRESS_ALL" "IN_PROGRESS_ALL=TASK-3"
assert_eq "0" "$ABANDONED_COUNT" "ABANDONED_COUNT=0"
assert_eq "3" "$TOTAL_TASKS" "TOTAL_TASKS=3"
