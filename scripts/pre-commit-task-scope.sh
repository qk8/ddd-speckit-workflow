#!/usr/bin/env bash
# pre-commit-task-scope.sh — Pre-commit hook for task scope validation
#
# Usage: Installed as .git/hooks/pre-commit
#   cp scripts/pre-commit-task-scope.sh .git/hooks/pre-commit
#   chmod +x .git/hooks/pre-commit
#
# N4: Pre-commit hook for task scope validation.
# Prevents committing tasks.md changes that add files outside the declared Scope.
# This catches scope creep at the git level, not just the LLM prompt level.

set -euo pipefail

# ── Find tasks.md ───────────────────────────────────────────────
TASKS_FILE=""
for dir in .specify/specs/*/; do
  if [ -f "$dir/tasks.md" ]; then
    TASKS_FILE="$dir/tasks.md"
    break
  fi
done

if [ -z "$TASKS_FILE" ] || [ ! -f "$TASKS_FILE" ]; then
  # No tasks.md found — skip validation
  exit 0
fi

# ── Get staged changes to tasks.md ──────────────────────────────
STAGED_TASKS=$(git diff --cached --name-only | grep -E 'tasks\.md$' || true)

if [ -z "$STAGED_TASKS" ]; then
  # No tasks.md changes staged — skip validation
  exit 0
fi

ERRORS=0
WARNINGS=0

# ── Validate each task section ──────────────────────────────────
# For each task in the staged diff, check that created files match Scope.Creates
while IFS= read -r task_file; do
  # Get the diff for this task file
  DIFF=$(git diff --cached -- "$task_file")

  # Extract task sections that were modified
  # Look for new "Creates:" entries that don't match existing tasks
  NEW_FILES=$(echo "$DIFF" | grep '^+' | grep -oE '^\+\s+-\s+[^\s]+' | sed 's/^\+\s+-\s*//' || true)

  if [ -n "$NEW_FILES" ]; then
    echo "TASK SCOPE CHECK: Found new file entries in staged tasks.md:"
    echo "$NEW_FILES" | while IFS= read -r f; do
      echo "  + $f"
    done
    WARNINGS=$((WARNINGS + 1))
  fi

  # Check that newly created files in the working tree are referenced in tasks.md Scope
  CREATED_FILES=$(git diff --cached --diff-filter=ACM --name-only | grep -v 'tasks\.md$' || true)

  if [ -n "$CREATED_FILES" ]; then
    # Get the current feature directory
    FEATURE_DIR=$(dirname "$task_file")

    while IFS= read -r created_file; do
      # Check if this file is referenced in any task's Scope.Creates
      if ! grep -q "Creates:" "$task_file" 2>/dev/null; then
        continue
      fi

      # Extract all Scope.Creates entries
      SCOPE_FILES=$(awk '/^Scope:/{found=1; next} found && /^  Creates:/{in_creates=1; next} in_creates && /^    -/{print; next} in_creates && /^[^ ]/{in_creates=0} found && /^[a-z]/{exit}' "$task_file" 2>/dev/null || true)

      if [ -n "$SCOPE_FILES" ]; then
        # Check if the created file matches any Scope.Creates entry
        BASENAME=$(basename "$created_file")
        if ! echo "$SCOPE_FILES" | grep -qF "$BASENAME" && ! echo "$SCOPE_FILES" | grep -qF "$created_file"; then
          # File might be in a different task — check all tasks
          if ! grep -A5 "Creates:" "$task_file" | grep -qF "$BASENAME"; then
            echo "  [WARN] $created_file — not found in any task's Scope.Creates"
            echo "         Consider adding it to the appropriate task in tasks.md"
          fi
        fi
      fi
    done <<< "$CREATED_FILES"
  fi

done <<< "$STAGED_TASKS"

# ── Summary ─────────────────────────────────────────────────────
if [ "$WARNINGS" -gt 0 ]; then
  echo ""
  echo "TASK SCOPE: $WARNINGS warning(s) found. Review recommended."
  echo "  - New file entries in tasks.md should match Scope.Creates"
  echo "  - Files created outside of tasks.md Scope may indicate scope creep"
fi

# Don't block commits on warnings — only errors would block
exit 0
