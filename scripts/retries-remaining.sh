#!/usr/bin/env bash
# Aggregate all retry counters for one or all tasks in a feature directory.
# Provides a single view of "how many retries does this task have left
# across all dimensions: revisions, corrections, drift, global cap."
#
# Usage:
#   retries-remaining.sh <feature_dir> [task_id]
#   retries-remaining.sh <feature_dir>          # all tasks
#   retries-remaining.sh <feature_dir> TASK-5   # single task
#
# Output: key=value pairs for each task, plus a summary line.

set -euo pipefail

FEATURE_DIR="${1:?Usage: retries-remaining.sh <feature_dir> [task_id]}"

if [ ! -d "$FEATURE_DIR" ]; then
  echo "ERROR: Feature directory not found: $FEATURE_DIR" >&2
  exit 1
fi

# ── Per-task revision count ────────────────────────────────────────
get_revision_count() {
  local task_id="$1"
  local count=0

  if [ -f "$FEATURE_DIR/state.json" ]; then
    count=$(bash scripts/state-engine.sh read "$FEATURE_DIR" "revisions.per_task.$task_id" 2>/dev/null || echo 0)
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  echo "$count"
}

# ── Drift revision count (global, not per-task) ───────────────────
get_drift_revisions() {
  local count=0
  if [ -f "$FEATURE_DIR/.drift_revisions" ]; then
    count=$(cat "$FEATURE_DIR/.drift_revisions" 2>/dev/null || echo 0)
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  echo "$count"
}

# ── Spec revision count (global) ──────────────────────────────────
get_spec_revisions() {
  local count=0
  if [ -f "$FEATURE_DIR/state.json" ]; then
    count=$(bash scripts/state-engine.sh read "$FEATURE_DIR" "revisions.spec_total" 2>/dev/null || echo 0)
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  echo "$count"
}

# ── Global correction count for a task ────────────────────────────
get_corrections() {
  local task_id="$1"
  local count=0
  if [ -f "$FEATURE_DIR/state.json" ]; then
    count=$(bash scripts/state-engine.sh read "$FEATURE_DIR" corrections."$task_id" 2>/dev/null || echo 0)
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  echo "$count"
}

# ── Max revisions (from check-task-revisions.sh default) ──────────
MAX_REVISIONS=3
MAX_DRIFT_REVISIONS=2
MAX_SPEC_REVISIONS=3
GLOBAL_CORRECTION_CAP=10

# ── Collect task IDs ──────────────────────────────────────────────
if [ -n "${2:-}" ]; then
  TASK_IDS=("$2")
else
  # Discover all task IDs from tasks.md
  if [ -f "$FEATURE_DIR/tasks.md" ]; then
    TASK_IDS=($(grep "^## TASK-" "$FEATURE_DIR/tasks.md" | sed 's/^## //'))
  else
    echo "ERROR: No tasks.md found in $FEATURE_DIR" >&2
    exit 1
  fi
fi

# ── Output ────────────────────────────────────────────────────────
DRIFT_REVS=$(get_drift_revisions)
SPEC_REVS=$(get_spec_revisions)

total_tasks=${#TASK_IDS[@]}
total_remaining=0
at_risk=0

for task_id in "${TASK_IDS[@]}"; do
  rev_count=$(get_revision_count "$task_id")
  corrections=$(get_corrections "$task_id")

  rev_remaining=$((MAX_REVISIONS - rev_count))
  [ "$rev_remaining" -lt 0 ] && rev_remaining=0

  corr_remaining=$((GLOBAL_CORRECTION_CAP - corrections))
  [ "$corr_remaining" -lt 0 ] && corr_remaining=0

  total_remaining=$((total_remaining + rev_remaining + corr_remaining))

  # Count as "at risk" if any dimension is exhausted or near-exhausted
  if [ "$rev_remaining" -le 1 ] || [ "$corr_remaining" -le 2 ]; then
    at_risk=$((at_risk + 1))
  fi

  # Get task status from tasks.md
  status="unknown"
  if [ -f "$FEATURE_DIR/tasks.md" ]; then
    status=$(awk "/^## $task_id/{found=1} found && /^Status:/{print; exit}" "$FEATURE_DIR/tasks.md" 2>/dev/null | sed 's/Status: //' || echo "unknown")
  fi

  echo "$task_id: revisions_remaining=$rev_remaining corrections_remaining=$corr_remaining status=$status"
done

echo ""
echo "SUMMARY: $total_tasks tasks | $total_remaining total retries remaining | $at_risk at risk"
echo "  Revision limit: $MAX_REVISIONS per task | Drift limit: $MAX_DRIFT_REVISIONS (global) | Spec limit: $MAX_SPEC_REVISIONS (global) | Correction cap: $GLOBAL_CORRECTION_CAP per task"
echo "  Drift revisions used: $DRIFT_REVS/$MAX_DRIFT_REVISIONS | Spec revisions used: $SPEC_REVS/$MAX_SPEC_REVISIONS"
