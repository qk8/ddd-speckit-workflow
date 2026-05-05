#!/usr/bin/env bash
# Track and enforce per-task revision limits.
# Prevents a single stuck task from consuming all implement_loop iterations.
#
# Usage:
#   check-task-revisions.sh <feature_dir> <task_id> <max_revisions>
#   check-task-revisions.sh --auto <feature_dir> <max_revisions>
#     --auto mode: reads first TODO/IN_PROGRESS task from tasks.md
#
# Outputs:
#   REVISION_COUNT=N
#   REVISION_OK=true|false
#   REVISION_EXHAUSTED=true|false
#   CURRENT_TASK=<task_id>
#
# Creates: .artifacts/task-revisions/<task_id>.count (atomic writes)

set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  shift
fi

FEATURE_DIR="${1:?Usage: check-task-revisions.sh <feature_dir> <task_id> [max_revisions]}"
MAX_REVISIONS="${4:-3}"

# Extract task ID from tasks.md if --auto mode (must happen before mkdir)
if [ "${FEATURE_DIR:-}" = "--auto" ]; then
  FEATURE_DIR="${2:?Usage: check-task-revisions.sh --auto <feature_dir> <max_revisions>}"
  MAX_REVISIONS="${3:-3}"
  TASKS_FILE="$FEATURE_DIR/tasks.md"
  if [ -f "$TASKS_FILE" ]; then
    # Get first TODO task, or first IN_PROGRESS if no TODO
    TASK_ID=$(awk '/^## TASK/{header=$0} /^Status: TODO$/{gsub(/^## /,"",header); print header; exit}' "$TASKS_FILE" 2>/dev/null || true)
    if [ -z "$TASK_ID" ]; then
      TASK_ID=$(awk '/^## TASK/{header=$0} /^Status: IN_PROGRESS$/{gsub(/^## /,"",header); print header; exit}' "$TASKS_FILE" 2>/dev/null || true)
    fi
    TASK_ID=$(echo "$TASK_ID" | sed 's/^## //')
  else
    TASK_ID="unknown"
  fi
else
  TASK_ID="${2:?Usage: check-task-revisions.sh <feature_dir> <task_id> [max_revisions]}"
fi

REVISIONS_DIR="$FEATURE_DIR/.artifacts/task-revisions"
mkdir -p "$REVISIONS_DIR"

COUNT_FILE="$REVISIONS_DIR/${TASK_ID}.count"
LOCK_FILE="$COUNT_FILE.lock"

# ── Check if task is currently ABANDONED — if so, reset counter ──
TASKS_FILE="$FEATURE_DIR/tasks.md"
if [ -f "$TASKS_FILE" ]; then
  TASK_STATUS=$(awk "/^## TASK-$TASK_ID/{found=1} found && /^Status:/{print; exit}" "$TASKS_FILE" 2>/dev/null || true)
  if echo "$TASK_STATUS" | grep -qi "ABANDONED"; then
    rm -f "$COUNT_FILE"
    echo "REVISION_COUNT=0"
    echo "REVISION_OK=true"
    echo "REVISION_EXHAUSTED=false"
    echo "CURRENT_TASK=$TASK_ID"
    echo "NOTE: Counter reset — task was ABANDONED and restarted."
    exit 0
  fi
fi

# Use flock for mutual exclusion around the counter cycle
exec 200>"$LOCK_FILE"
flock -x 200

# Read current count (default 0)
CURRENT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
case "$CURRENT" in
  ''|*[!0-9]*) CURRENT=0 ;;
esac

# Output current state
echo "REVISION_COUNT=$CURRENT"
echo "REVISION_OK=true"
echo "REVISION_EXHAUSTED=false"
echo "CURRENT_TASK=$TASK_ID"

# Check if limit is reached
if [ "$CURRENT" -ge "$MAX_REVISIONS" ]; then
  echo "REVISION_OK=false"
  echo "REVISION_EXHAUSTED=true"
  echo "TASK $TASK_ID has exceeded $MAX_REVISIONS revisions ($CURRENT attempts)." >&2
  flock -u 200
  exit 1
fi

# Increment atomically: write to count file (skip in dry-run mode)
if [ "$DRY_RUN" = false ]; then
  echo "$((CURRENT + 1))" > "$COUNT_FILE"
  echo "REVISION_COUNT=$((CURRENT + 1))"
else
  echo "REVISION_COUNT=$CURRENT"
fi

flock -u 200

exit 0
