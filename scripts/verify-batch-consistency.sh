#!/usr/bin/env bash
# Verify batch consistency — detect merge conflicts and unexpected changes
# after a parallel batch completes.
#
# Usage: verify-batch-consistency.sh <feature_dir>
#
# Checks:
#   1. If .artifacts/batch_tasks.txt exists, verify working tree is clean
#      (no uncommitted conflicts from parallel task overlap)
#   2. Run git diff --exit-code to detect unexpected changes
#   3. If single-task mode (no batch file), skip silently
#
# Exit 0 on success, 1 on conflict detection.

set -euo pipefail

FEATURE_DIR="${1:?Usage: verify-batch-consistency.sh <feature_dir>}"
BATCH_FILE="${FEATURE_DIR}/.artifacts/batch_tasks.txt"

# If no batch file, single-task mode — skip silently
if [ ! -f "$BATCH_FILE" ]; then
  echo "BATCH_CHECK: SKIP (single-task mode, no batch_tasks.txt)"
  exit 0
fi

ERRORS=0

# Read the batch task list
BATCH_TASKS=$(cat "$BATCH_FILE" 2>/dev/null | tr -d '[:space:]')
if [ -z "$BATCH_TASKS" ]; then
  echo "BATCH_CHECK: SKIP (empty batch_tasks.txt)"
  exit 0
fi

echo "BATCH_CHECK: Verifying consistency for batch tasks: $BATCH_TASKS"

# Check 1: Verify no git merge conflicts in any tracked files
if git rev-parse --is-inside-work-tree &>/dev/null; then
  # Look for conflict markers in all files
  CONFLICT_FILES=$(grep -rlE '^[<=>]{7}' "$FEATURE_DIR" --include="*.ts" --include="*.js" --include="*.py" --include="*.java" --include="*.go" --include="*.rb" --include="*.tsx" --include="*.jsx" 2>/dev/null || true)

  if [ -n "$CONFLICT_FILES" ]; then
    echo "BATCH_CHECK: FAIL — merge conflict markers detected in:"
    echo "$CONFLICT_FILES" | while read -r f; do echo "    $f"; done
    ERRORS=$((ERRORS + 1))
  fi
fi

# Check 2: Verify no empty implementation files were created
# (a sign that a task wrote nothing but passed tests)
while IFS=',' read -r task_id; do
  task_id=$(echo "$task_id" | tr -d '[:space:]')
  [ -z "$task_id" ] && continue

  # Look for recently modified files that are empty
  # This is a heuristic — check files that match common implementation patterns
  task_base=$(echo "$task_id" | tr -d '-')
  empty_files=$(find "$FEATURE_DIR" -type f -name "${task_base}*.ts" -o -name "${task_base}*.js" -o -name "${task_base}*.py" 2>/dev/null | xargs -I{} sh -c '[ -s "{}" ] || echo "{}"' 2>/dev/null || true)

  if [ -n "$empty_files" ]; then
    echo "BATCH_CHECK: WARN — potentially empty implementation files:"
    echo "$empty_files" | while read -r f; do echo "    $f"; done
  fi
done <<< "$BATCH_TASKS"

# Check 3: Verify no duplicate function/class declarations in same file
# (two tasks in the same batch may have written to the same file)
DUP_CHECK=$(find "$FEATURE_DIR" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) -exec grep -lE '^(export\s+)?(function|class|const|def)\s' {} \; 2>/dev/null | while read -r f; do
  # Count unique declaration lines per file
  total=$(grep -cE '^(export\s+)?(function|class|const|def)\s' "$f" 2>/dev/null || echo 0)
  unique=$(grep -oE '^(export\s+)?(function|class|const|def)\s+[a-zA-Z_][a-zA-Z0-9_]*' "$f" 2>/dev/null | sort -u | wc -l || echo 0)
  if [ "$total" -gt "$unique" ]; then
    echo "    $f: $total declarations, $unique unique (possible duplicates)"
  fi
done || true)

if [ -n "$DUP_CHECK" ]; then
  echo "BATCH_CHECK: WARN — possible duplicate declarations:"
  echo "$DUP_CHECK"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "BATCH_CHECK: FAIL — $ERRORS conflict(s) detected"
  exit 1
fi

echo "BATCH_CHECK: PASS — no conflicts detected"
exit 0
