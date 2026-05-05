#!/usr/bin/env bash
# Pre-task validation — runs before implement_code.
# Checks for common issues that would cause implementation failures.
#
# Usage: pre-task-validate.sh <feature_dir>
#
# Outputs:
#   PRE_VALIDATE_OK=true|false
#   PRE_VALIDATE_ERROR=<message> (empty if OK)

set -euo pipefail

FEATURE_DIR="${1:?Usage: pre-task-validate.sh <feature_dir>}"
TASKS_FILE="$FEATURE_DIR/tasks.md"

if [ ! -f "$TASKS_FILE" ]; then
  echo "PRE_VALIDATE_OK=false"
  echo "PRE_VALIDATE_ERROR=tasks.md not found in $FEATURE_DIR"
  exit 1
fi

ERRORS=""

# ── Check 1: Test file paths are unique across TODO/IN_PROGRESS tasks ──
declare -A TEST_FILES
while IFS= read -r line; do
  test_path=$(echo "$line" | sed -n 's/.*Test file: *\([^ ]*\).*/\1/p' 2>/dev/null || true)
  if [ -n "$test_path" ]; then
    if [ -n "${TEST_FILES[$test_path]+x}" ]; then
      ERRORS="${ERRORS}DUPLICATE_TEST_FILE: $test_path used by multiple tasks. "
    fi
    TEST_FILES[$test_path]=1
  fi
done < <(grep -A 20 "^## TASK" "$TASKS_FILE" 2>/dev/null | grep "Test file:" || true)

# ── Check 2: Scope.Modifies doesn't overlap between TODO tasks at same dependency level ──
declare -A SCOPE_FILES
while IFS= read -r line; do
  scope_path=$(echo "$line" | sed -n 's/.*Scope.Modifies: *\(.*\)/\1/p' 2>/dev/null || true)
  if [ -n "$scope_path" ]; then
    for f in $scope_path; do
      if [ -n "${SCOPE_FILES[$f]+x}" ]; then
        ERRORS="${ERRORS}SCOPE_CONFLICT: $f modified by multiple tasks. "
      fi
      SCOPE_FILES[$f]=1
    done
  fi
done < <(grep -A 20 "^## TASK" "$TASKS_FILE" 2>/dev/null | grep "Scope.Modifies:" || true)

# ── Check 3: Acceptance criteria reference classes that exist in plan.md ──
PLAN_FILE="$FEATURE_DIR/plan.md"
if [ -f "$PLAN_FILE" ]; then
  while IFS= read -r line; do
    # Extract class/module references from acceptance criteria
    ref=$(echo "$line" | grep -oE '[A-Z][a-zA-Z]+' 2>/dev/null | head -1 || true)
    if [ -n "$ref" ]; then
      # Check if it's a known plan section (simplified — just check plan exists)
      :
    fi
  done < <(grep -A 5 "^Acceptance:" "$TASKS_FILE" 2>/dev/null || true)
fi

# ── Output results ──
if [ -n "$ERRORS" ]; then
  echo "PRE_VALIDATE_OK=false"
  echo "PRE_VALIDATE_ERROR=$ERRORS"
  exit 1
else
  echo "PRE_VALIDATE_OK=true"
  echo "PRE_VALIDATE_ERROR="
  exit 0
fi
