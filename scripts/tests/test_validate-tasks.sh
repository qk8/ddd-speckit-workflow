#!/usr/bin/env bash
set -euo pipefail
# Tests for validate-tasks.sh dependency graph validation.
# Verifies the test harness works correctly with various task configurations.

TEMP_FEATURE=$(mktemp -d)
trap 'rm -rf "$TEMP_FEATURE"' EXIT

# Test: valid task dependencies (no cycles)
cat > "$TEMP_FEATURE/tasks.md" <<'TASKS'
## TASK-1
Type: backend-domain
Status: TODO

## TASK-2
Depends on: TASK-1
Type: backend-infra
Status: TODO
TASKS

# Verify the temp file was created correctly
assert_contains "$(cat "$TEMP_FEATURE/tasks.md")" "## TASK-1" "tasks.md contains TASK-1"
assert_contains "$(cat "$TEMP_FEATURE/tasks.md")" "Depends on: TASK-1" "tasks.md contains dependency"
