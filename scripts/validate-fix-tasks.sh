#!/usr/bin/env bash
# Lightweight task validation for fix tasks added during fix_needed_round
# or code_review phases. Runs in under 2 seconds.
#
# Usage: validate-fix-tasks.sh <feature_dir>
# Outputs: VALID=true|false, ERRORS=N, FIX_TASK_COUNT=N
#
# Checks:
#   1. All tasks have a "Do NOT" scope guard
#   2. All Depends-on references point to existing TASK-XXX
#   3. No circular dependencies (simple check: A->B->A)

set -euo pipefail

FEATURE_DIR="${1:?Usage: validate-fix-tasks.sh <feature_dir>}"
TASKS_FILE="$FEATURE_DIR/tasks.md"

if [ ! -f "$TASKS_FILE" ]; then
  echo "VALID=false"
  echo "ERRORS=1"
  echo "FIX_TASK_COUNT=0"
  echo "ERROR: tasks.md not found" >&2
  exit 1
fi

FIX_TASK_COUNT=$(grep -c "^## TASK" "$TASKS_FILE" 2>/dev/null || echo 0)
ERRORS=0

# Check 1: All tasks have a "Do NOT" scope guard
DO_NOT_MISSING=$(awk '
  /^## TASK-/ {
    if (found_accept && !has_do_not) bad++
    found_accept = 0
    has_do_not = 0
  }
  /^Do NOT:/ { has_do_not = 1 }
  /^Acceptance criteria:/ { found_accept = 1 }
  END {
    if (found_accept && !has_do_not) bad++
    print bad+0
  }
' "$TASKS_FILE")

if [ "$DO_NOT_MISSING" -gt 0 ]; then
  ERRORS=$((ERRORS + DO_NOT_MISSING))
  echo "WARNING: $DO_NOT_MISSING tasks missing 'Do NOT' scope guard." >&2
fi

# Check 2: All Depends-on references point to existing TASK-XXX
INVALID_DEPS=$(awk '
  /^## TASK-/ { current_task = $0; gsub(/^## /, "", current_task); has_dep = 0 }
  /^Depends on:/ {
    has_dep = 1
    deps = $0
    gsub(/^Depends on: /, "", deps)
    gsub(/ /, "", deps)
    if (deps != "none" && deps != "") {
      n = split(deps, dep_arr, ",")
      for (i = 1; i <= n; i++) {
        print current_task ":" dep_arr[i]
      }
    }
  }
' "$TASKS_FILE" | while IFS=: read -r task dep; do
  # Check if dep task exists (match exact TASK-XXX header)
  # dep already has TASK- prefix from the Depends on: line
  if ! grep -qx "## $dep" "$TASKS_FILE" 2>/dev/null; then
    echo "INVALID"
  fi
done | grep -c "INVALID" || true)

INVALID_DEPS=$(echo "$INVALID_DEPS" | tr -d ' ')
case "$INVALID_DEPS" in ''|*[!0-9]*) INVALID_DEPS=0 ;; esac
ERRORS=$((ERRORS + INVALID_DEPS))

# Check 3: Simple circular dependency check (A->B->A)
CIRCULAR=$(awk '
  /^## TASK-/ { current = $0; gsub(/^## /, "", current) }
  /^Depends on:/ {
    deps = $0
    gsub(/^Depends on: /, "", deps)
    gsub(/ /, "", deps)
    if (deps != "none" && deps != "") {
      n = split(deps, arr, ",")
      for (i = 1; i <= n; i++) {
        dep = arr[i]
        gsub(/ /, "", dep)
        edges[current ":" dep] = 1
      }
    }
  }
  END {
    # Check for 2-node cycles: A->B and B->A
    count = 0
    for (edge in edges) {
      split(edge, parts, ":")
      a = parts[1]
      b = parts[2]
      reverse = b ":" a
      if (reverse in edges && a < b) {
        count++
      }
    }
    print count
  }
' "$TASKS_FILE")

case "$CIRCULAR" in ''|*[!0-9]*) CIRCULAR=0 ;; esac
ERRORS=$((ERRORS + CIRCULAR))

if [ "$ERRORS" -eq 0 ]; then
  VALID=true
else
  VALID=false
fi

echo "VALID=$VALID"
echo "ERRORS=$ERRORS"
echo "FIX_TASK_COUNT=$FIX_TASK_COUNT"

if [ "$VALID" = "false" ]; then
  exit 1
fi
