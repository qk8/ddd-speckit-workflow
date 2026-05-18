#!/usr/bin/env bash
# post-batch-semantic-check.sh — Detect semantic conflicts between parallel tasks.
#
# When two tasks in the same DAG level modify files in the same module/package,
# they can introduce contradictory logic even if they don't touch the same file.
# This script identifies such cases and runs focused integration tests.
#
# Usage: post-batch-semantic-check.sh <feature_dir>
#
# Output: .artifacts/semantic-check-result.json

set -euo pipefail

FEATURE_DIR="${1:?Usage: post-batch-semantic-check.sh <feature_dir>}"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
RESULT_FILE="$ARTIFACTS_DIR/semantic-check-result.json"
mkdir -p "$ARTIFACTS_DIR"

BATCH_FILE="$ARTIFACTS_DIR/batch_tasks.txt"
STATE_FILE="$FEATURE_DIR/state.json"

# Exit silently if no batch context
if [ ! -f "$BATCH_FILE" ]; then
  echo "SEMANTIC_CHECK: SKIPPED — no batch context"
  exit 0
fi

# Read batch tasks
BATCH_TASKS=$(cat "$BATCH_FILE" | tr '\n' ' ')

# Build a map of file -> task from git diff
declare -A FILE_TO_TASK=()
for task_id in $BATCH_TASKS; do
  [ -z "$task_id" ] && continue
  # Get files modified by this task from git diff
  cd "$FEATURE_DIR"
  while IFS= read -r fpath; do
    [ -z "$fpath" ] && continue
    # Skip artifacts, node_modules, build dirs
    case "$fpath" in
      .artifacts/*|.git/*|node_modules/*|dist/*|build/*|*.lock|*.pid) continue ;;
    esac
    # Record which task claims this file
    if [ -n "${FILE_TO_TASK[$fpath]:-}" ]; then
      # Multiple tasks touching same file — already caught by verify-batch-consistency.sh
      :
    else
      FILE_TO_TASK["$fpath"]="$task_id"
    fi
  done < <(git diff --name-only HEAD 2>/dev/null || true)
  cd - > /dev/null
done

# Group files by module/package
# A "module" is determined by the directory path relative to the source root
declare -A MODULE_FILES=()
declare -A MODULE_TASKS=()

for fpath in "${!FILE_TO_TASK[@]}"; do
  # Get the directory of the file (module boundary)
  fdir=$(dirname "$fpath")
  # Normalize: remove language-specific test dirs
  case "$fdir" in
    */test*|*/spec*|*/tests*) continue ;;
  esac
  # Use the top-level source directory as the module
  # e.g., "src/domain/user" -> "src/domain"
  module_dir=$(echo "$fdir" | sed 's|/[^/]*$||')
  [ -z "$module_dir" ] && module_dir="."

  if [ -n "${MODULE_FILES[$module_dir]:-}" ]; then
    MODULE_FILES["$module_dir"]="${MODULE_FILES[$module_dir]}|$fpath"
  else
    MODULE_FILES["$module_dir"]="$fpath"
  fi

  # Track which tasks touch this module
  task="${FILE_TO_TASK[$fpath]}"
  if ! echo "${MODULE_TASKS[$module_dir]:-}" | grep -q "$task" 2>/dev/null; then
    if [ -n "${MODULE_TASKS[$module_dir]:-}" ]; then
      MODULE_TASKS["$module_dir"]="${MODULE_TASKS[$module_dir]},$task"
    else
      MODULE_TASKS["$module_dir"]="$task"
    fi
  fi
done

# Find modules touched by multiple tasks
CONFLICTS=0
CONFLICT_DETAILS=""
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

for module_dir in "${!MODULE_TASKS[@]}"; do
  task_list="${MODULE_TASKS[$module_dir]}"
  # Count unique tasks in this module
  task_count=$(echo "$task_list" | tr ',' '\n' | sort -u | wc -l | tr -d ' ')
  if [ "$task_count" -gt 1 ]; then
    CONFLICTS=$((CONFLICTS + 1))
    files="${MODULE_FILES[$module_dir]}"
    CONFLICT_DETAILS="${CONFLICT_DETAILS}Module: $module_dir | Tasks: $task_list | Files: $files
"
  fi
done

# If no cross-task modules found, exit clean
if [ "$CONFLICTS" -eq 0 ]; then
  cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "status": "PASS",
  "conflicts": 0,
  "details": "No cross-task module conflicts detected",
  "modules_checked": $(echo "${!MODULE_TASKS[@]}" | wc -w | tr -d ' ')
}
EOF
  echo "SEMANTIC_CHECK: PASS — ${#MODULE_TASKS[@]} modules checked, 0 conflicts"
  exit 0
fi

# For each conflict, try to run a focused test
# We look for test files that cover the shared module
for module_dir in "${!MODULE_TASKS[@]}"; do
  task_list="${MODULE_TASKS[$module_dir]}"
  task_count=$(echo "$task_list" | tr ',' '\n' | sort -u | wc -l | tr -d ' ')
  if [ "$task_count" -le 1 ]; then
    continue
  fi

  # Try to find and run tests for this module
  cd "$FEATURE_DIR"
  test_pattern=$(echo "$module_dir" | sed 's|/|_|g')
  found_test=false

  # Search for test files matching this module
  while IFS= read -r test_file; do
    [ -z "$test_file" ] && continue
    found_test=true
    # Run the test and capture result
    test_exit=0
    if command -v pytest &>/dev/null; then
      pytest "$test_file" -q 2>&1 || test_exit=$?
    elif command -v go &>/dev/null; then
      go test "$test_file" 2>&1 || test_exit=$?
    else
      # No test runner — flag for manual review
      echo "SEMANTIC_CHECK: MANUAL_REVIEW — No test runner for module $module_dir"
      break
    fi

    if [ "$test_exit" -ne 0 ]; then
      echo "SEMANTIC_CHECK: FAIL — Module $module_dir integration test failed"
      cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "status": "FAIL",
  "conflicts": $CONFLICTS,
  "details": "Module $module_dir integration test failed (exit $test_exit)",
  "modules_checked": $(echo "${!MODULE_TASKS[@]}" | wc -w | tr -d ' ')
}
EOF
      cd - > /dev/null
      exit 1
    fi
  done < <(find "$FEATURE_DIR" -path "*/test*" -name "*${test_pattern}*" -type f 2>/dev/null | head -3)

  if [ "$found_test" = false ]; then
    echo "SEMANTIC_CHECK: ADVISORY — Module $module_dir has cross-task conflicts but no test file found"
  fi
  cd - > /dev/null
done

# Write result
if [ "$CONFLICTS" -gt 0 ]; then
  cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "status": "ADVISORY",
  "conflicts": $CONFLICTS,
  "details": "Cross-task module conflicts detected — review manually",
  "conflicts_detail": $(echo "$CONFLICT_DETAILS" | head -c 500),
  "modules_checked": $(echo "${!MODULE_TASKS[@]}" | wc -w | tr -d ' ')
}
EOF
  echo "SEMANTIC_CHECK: ADVISORY — $CONFLICTS cross-task module conflict(s) detected"
  echo "SEMANTIC_CHECK: Review $RESULT_FILE for details"
fi

exit 0
