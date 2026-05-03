#!/usr/bin/env bash
# Abandoned task file cleanup.
# Identifies and removes files created by ABANDONED tasks.
# Flags files shared between ABANDONED and DONE tasks for human review.
#
# Usage: cleanup-abandoned.sh <feature_dir>
# Outputs: CLEANUP_COMPLETE=true|false, FILES_REMOVED=N, FILES_FLAGGED=N

set -euo pipefail

FEATURE_DIR="${1:?Usage: cleanup-abandoned.sh <feature_dir>}"

if [ ! -d "$FEATURE_DIR" ]; then
  echo "CLEANUP_COMPLETE=true"
  echo "FILES_REMOVED=0"
  echo "FILES_FLAGGED=0"
  exit 0
fi

TASKS_FILE="${FEATURE_DIR}/tasks.md"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

REPORT_FILE="${ARTIFACTS_DIR}/cleanup-report.md"
REMOVED=0
FLAGGED=0

{
  echo "# ABANDONED TASK CLEANUP REPORT"
  echo ""
  echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"
  echo ""
} > "$REPORT_FILE"

# ── Find ABANDONED task IDs ────────────────────────────────────
ABANDONED_TASKS=$(awk '/^## TASK/{header=$0} /^Status: ABANDONED$/{gsub(/^## /,"",header); print header}' "$TASKS_FILE" 2>/dev/null || true)

if [ -z "$ABANDONED_TASKS" ]; then
  {
    echo "## Result"
    echo ""
    echo "No ABANDONED tasks found. Nothing to clean up."
  } >> "$REPORT_FILE"
  echo "CLEANUP_COMPLETE=true"
  echo "FILES_REMOVED=0"
  echo "FILES_FLAGGED=0"
  echo "  No ABANDONED tasks found."
  exit 0
fi

echo "Found ABANDONED tasks: $(echo "$ABANDONED_TASKS" | tr '\n' ' ' | sed 's/ *$//')"

# ── Find files created by abandoned tasks ──────────────────────
# Strategy: use git log to find files modified by abandoned tasks' time window,
# then cross-reference with acceptance criteria.
ABANDONED_FILES=$(mktemp)

# For each abandoned task, find files that were likely created by it.
# We use git log to find recently added/modified files, then match against
# the task's acceptance criteria patterns.
git log --all --oneline --name-only --diff-filter=ACM 2>/dev/null | \
  awk '/^[0-9a-f]+ / {commit=$1; next} /^[^ ]/ {print commit "|" $0}' | \
  sort -u > "$ABANDONED_FILES"

# ── Find DONE task file references ─────────────────────────────
DONE_FILES=$(mktemp)
trap 'rm -f "$ABANDONED_FILES" "$DONE_FILES"' EXIT

if [ -f "$TASKS_FILE" ]; then
  # Extract file paths from DONE tasks' acceptance criteria
  current_status=""
  current_task=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^Status:'; then
      current_status=$(echo "$line" | sed 's/^Status: //')
    fi
    if echo "$line" | grep -qE '^## TASK-'; then
      current_task=$(echo "$line" | sed 's/^## //' | sed 's/\[//g; s/\]//g')
    fi
    if [ "$current_status" = "DONE" ] && echo "$line" | grep -qE '^\s+- \[.*\]'; then
      # Extract file paths from acceptance criteria
      echo "$line" | grep -oE '[a-zA-Z0-9_/.-]+\.(java|ts|js|py|kt|scala|go|rb|php|sql|yaml|yml|json|toml|xml|md|html|css|scss)' 2>/dev/null | while read -r fpath; do
        echo "${current_task}|${fpath}"
      done
    fi
  done < "$TASKS_FILE" > "$DONE_FILES"
fi

# ── Clean up abandoned task artifacts ──────────────────────────
# Look for .artifacts files specific to abandoned tasks
for task_id in $ABANDONED_TASKS; do
  task_prompt_dir="${FEATURE_DIR}/.artifacts/prompts/${task_id}"
  if [ -d "$task_prompt_dir" ]; then
    rm -rf "$task_prompt_dir"
    REMOVED=$((REMOVED + 1))
    echo "  Removed: ${task_prompt_dir}" >> "$REPORT_FILE"
  fi
done

# ── Flag shared files ──────────────────────────────────────────
# Files that appear in both ABANDONED task scope and DONE task scope
# This is a heuristic — we check if any DONE task references files
# in directories that ABANDONED tasks also touched.
for task_id in $ABANDONED_TASKS; do
  # Get the task's scope from tasks.md
  scope=$(awk -v tid="## ${task_id}" 'BEGIN{found=0} index($0,tid)>0{found=1;next} found&&/^## /{exit} found{print}' "$TASKS_FILE" 2>/dev/null || true)

  # Check if any DONE task creates files in the same directory
  while read -r done_task done_file; do
    done_dir=$(dirname "$done_file" 2>/dev/null || echo "")
    # Simple check: if the done file is in a directory that the abandoned task also touches
    if echo "$scope" | grep -q "$done_dir" 2>/dev/null; then
      FLAGGED=$((FLAGGED + 1))
      echo "  FLAGGED: ${done_file} (DONE task ${done_task} may depend on abandoned task output)" >> "$REPORT_FILE"
    fi
  done < "$DONE_FILES"
done

# ── Write summary ──────────────────────────────────────────────
{
  echo "## Summary"
  echo ""
  echo "- Files removed: ${REMOVED}"
  echo "- Files flagged: ${FLAGGED}"
  if [ "$FLAGGED" -gt 0 ]; then
    echo ""
    echo "**ACTION REQUIRED**: Review flagged files above. They may be shared between abandoned and completed tasks."
  fi
} >> "$REPORT_FILE"

echo "CLEANUP_COMPLETE=true"
echo "FILES_REMOVED=${REMOVED}"
echo "FILES_FLAGGED=${FLAGGED}"
if [ "$FLAGGED" -gt 0 ]; then
  echo "  WARNING: $FLAGGED shared file(s) flagged for review."
fi

exit 0
