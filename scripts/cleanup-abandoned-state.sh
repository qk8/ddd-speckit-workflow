#!/usr/bin/env bash
# Cleanup script for abort/stop paths in the workflow.
# Cleans up IN_PROGRESS tasks, partial artifacts, and stale state
# when the workflow is aborted or stopped.
#
# Usage: cleanup-abandoned-state.sh <feature_dir> [phase]
#   phase: optional identifier of which phase was aborted (e.g., "review-tdd")
#
# Actions:
#   1. Reset all IN_PROGRESS tasks to TODO (so next run can pick them up)
#   2. Remove partial .artifacts/ from incomplete batches
#   3. Write abort report to .artifacts/abort-report.md
#   4. Reset stagnation counter
#   5. Reset per-task revision counters

set -euo pipefail

FEATURE_DIR="${1:?Usage: cleanup-abandoned-state.sh <feature_dir> [phase]}"
PHASE="${2:-unknown}"

TASKS_FILE="$FEATURE_DIR/tasks.md"
ABORT_REPORT="$FEATURE_DIR/.artifacts/abort-report.md"
mkdir -p "$FEATURE_DIR/.artifacts"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

# ── Report header ──────────────────────────────────────────────
{
  echo "# Workflow Abort Report"
  echo ""
  echo "- **Aborted at**: $TIMESTAMP"
  echo "- **Phase**: $PHASE"
  echo "- **Feature dir**: $FEATURE_DIR"
  echo ""
} > "$ABORT_REPORT"

# ── 1. Reset IN_PROGRESS tasks ─────────────────────────────────
if [ -f "$TASKS_FILE" ]; then
  IN_PROGRESS_TASKS=$(awk '/^## TASK/{header=$0} /^Status: IN_PROGRESS$/{gsub(/^## /,"",header); print header}' "$TASKS_FILE" 2>/dev/null || true)

  if [ -n "$IN_PROGRESS_TASKS" ]; then
    {
      echo "## Reset IN_PROGRESS tasks"
      echo ""
      echo "$IN_PROGRESS_TASKS" | while read -r tid; do
        echo "- $tid → reset to TODO"
      done
      echo ""
    } >> "$ABORT_REPORT"

    # Reset each IN_PROGRESS task to TODO
    while IFS= read -r tid; do
      [ -z "$tid" ] && continue
      # Replace "Status: IN_PROGRESS" with "Status: TODO" after the task header
      # Use awk for portability (no in-place sed)
      awk -v target="$tid" '
        /^## TASK-/ { header = $0; in_target = 0 }
        header ~ ("TASK-" target) { in_target = 1 }
        in_target && /^Status: IN_PROGRESS$/ {
          sub(/Status: IN_PROGRESS/, "Status: TODO")
          in_target = 0
        }
        { print }
      ' "$TASKS_FILE" > "$TASKS_FILE.tmp" && mv "$TASKS_FILE.tmp" "$TASKS_FILE"
    done <<< "$IN_PROGRESS_TASKS"
  else
    {
      echo "## Reset IN_PROGRESS tasks"
      echo ""
      echo "- No IN_PROGRESS tasks found."
      echo ""
    } >> "$ABORT_REPORT"
  fi
else
  {
    echo "## Reset IN_PROGRESS tasks"
    echo ""
    echo "- tasks.md not found."
    echo ""
  } >> "$ABORT_REPORT"
fi

# ── 2. Reset stagnation counter ────────────────────────────────
if [ -f "$FEATURE_DIR/.stagnation_state" ]; then
  echo "0" > "$FEATURE_DIR/.stagnation_state"
  if [ -f "$FEATURE_DIR/.stagnation_state.consec" ]; then
    echo "0" > "$FEATURE_DIR/.stagnation_state.consec"
  fi
  echo "- Stagnation counter reset." >> "$ABORT_REPORT"
fi

# ── 3. Clean partial batch artifacts ───────────────────────────
if [ -d "$FEATURE_DIR/.artifacts/check-results" ]; then
  # Keep results from completed tasks, remove partial ones
  # A result is "complete" if it contains PASS or FAIL (not just SKIP)
  PARTIAL_COUNT=$(grep -rl "SKIP" "$FEATURE_DIR/.artifacts/check-results/" 2>/dev/null | wc -l || echo 0)
  PARTIAL_COUNT=$(echo "$PARTIAL_COUNT" | xargs)
  {
    echo "## Partial artifacts"
    echo ""
    echo "- $PARTIAL_COUNT partial check results removed."
    echo ""
  } >> "$ABORT_REPORT"
  rm -f "$FEATURE_DIR/.artifacts/check-results/"*.result 2>/dev/null || true
fi

# ── 4. Reset per-task revision counters for ABANDONED tasks only ──
REVISIONS_DIR="$FEATURE_DIR/.artifacts/task-revisions"
if [ -d "$REVISIONS_DIR" ] && [ -f "$TASKS_FILE" ]; then
  ABANDONED_TASKS=$(awk '/^## TASK/{header=$0} /^Status: ABANDONED$/{gsub(/^## /,"",header); print header}' "$TASKS_FILE" 2>/dev/null || true)
  RESET_COUNT=0
  if [ -n "$ABANDONED_TASKS" ]; then
    while IFS= read -r tid; do
      [ -z "$tid" ] && continue
      COUNT_FILE="$REVISIONS_DIR/${tid}.count"
      if [ -f "$COUNT_FILE" ]; then
        rm -f "$COUNT_FILE"
        RESET_COUNT=$((RESET_COUNT + 1))
        echo "- Reset revision counter for $tid (ABANDONED task)." >> "$ABORT_REPORT"
      fi
    done <<< "$ABANDONED_TASKS"
  fi
  {
    echo "## Per-task revision counters"
    echo ""
    echo "- $RESET_COUNT task revision counters reset (ABANDONED tasks only)."
    echo ""
  } >> "$ABORT_REPORT"
fi

echo "- Abort report written to: $ABORT_REPORT"
