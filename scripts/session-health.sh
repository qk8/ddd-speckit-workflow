#!/usr/bin/env bash
# Session health dashboard — compact overview of feature session state.
# Aggregates task progress, revision counts, file tracking, and quality metrics.
#
# Usage: scripts/session-health.sh <feature_dir> [--json]
#
# Output: Compact dashboard with progress, quality, and risk indicators.

set -euo pipefail

FEATURE_DIR="${1:?Usage: session-health.sh <feature_dir> [--json]}"
JSON_OUTPUT=false

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUTPUT=true ;;
  esac
  shift
done

TASKS_FILE="$FEATURE_DIR/tasks.md"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
REVISIONS_DIR="$ARTIFACTS_DIR/task-revisions"
CREATED_DIR="$ARTIFACTS_DIR/created-files"
HEALTH_FILE="$ARTIFACTS_DIR/test-health.json"

# ── Task progress ──────────────────────────────────────────────
TOTAL=0
DONE=0
IN_PROGRESS=0
TODO=0
BLOCKED=0
ABANDONED=0

if [ -f "$TASKS_FILE" ]; then
  TOTAL=$(grep -c '^## TASK-' "$TASKS_FILE" || true)
  DONE=$(grep -c 'Status: DONE' "$TASKS_FILE" || true)
  IN_PROGRESS=$(grep -c 'Status: IN_PROGRESS' "$TASKS_FILE" || true)
  # Ensure numeric
  case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac
  case "$DONE" in ''|*[!0-9]*) DONE=0 ;; esac
  case "$IN_PROGRESS" in ''|*[!0-9]*) IN_PROGRESS=0 ;; esac
  TODO=$(grep -c 'Status: TODO' "$TASKS_FILE" || true)
  BLOCKED=$(grep -c 'Status: BLOCKED' "$TASKS_FILE" || true)
  ABANDONED=$(grep -c 'Status: ABANDONED' "$TASKS_FILE" || true)
  # Ensure numeric
  case "$TODO" in ''|*[!0-9]*) TODO=0 ;; esac
  case "$BLOCKED" in ''|*[!0-9]*) BLOCKED=0 ;; esac
  case "$ABANDONED" in ''|*[!0-9]*) ABANDONED=0 ;; esac
fi

# Progress bar
if [ "$TOTAL" -gt 0 ]; then
  PCT=$((DONE * 100 / TOTAL))
  FILLED=$((PCT / 5))
  EMPTY=$((20 - FILLED))
  BAR=$(printf '%0.s#' $(seq 1 $FILLED 2>/dev/null || true))$(printf '%0.s-' $(seq 1 $EMPTY 2>/dev/null || true))
else
  PCT=0
  BAR="--------------------"
fi

# ── Revision stats ─────────────────────────────────────────────
TOTAL_REVISIONS=0
MAX_REVISION=0
if [ -d "$REVISIONS_DIR" ]; then
  for f in "$REVISIONS_DIR"/*.count; do
    [ -f "$f" ] || continue
    c=$(cat "$f" 2>/dev/null || echo 0)
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    TOTAL_REVISIONS=$((TOTAL_REVISIONS + c))
    [ "$c" -gt "$MAX_REVISION" ] && MAX_REVISION=$c
  done
fi

# ── File tracking ──────────────────────────────────────────────
TOTAL_TRACKED=0
if [ -d "$CREATED_DIR" ]; then
  for f in "$CREATED_DIR"/*.files; do
    [ -f "$f" ] || continue
    n=$(wc -l < "$f" | tr -d ' ')
    TOTAL_TRACKED=$((TOTAL_TRACKED + n))
  done
fi

# ── Stagnation check ───────────────────────────────────────────
STAGNANT=false
if [ "$IN_PROGRESS" -gt 0 ] && [ "$MAX_REVISION" -ge 3 ]; then
  STAGNANT=true
fi

# ── Risk assessment ────────────────────────────────────────────
RISK="LOW"
if [ "$MAX_REVISION" -ge 5 ]; then
  RISK="CRITICAL"
elif [ "$MAX_REVISION" -ge 3 ] || [ "$BLOCKED" -gt 0 ]; then
  RISK="HIGH"
elif [ "$TOTAL_REVISIONS" -gt $((TOTAL * 2)) ] 2>/dev/null; then
  RISK="MEDIUM"
fi

# ── Output ─────────────────────────────────────────────────────
if [ "$JSON_OUTPUT" = true ]; then
  echo "{\"total\": $TOTAL, \"done\": $DONE, \"in_progress\": $IN_PROGRESS, \"todo\": $TODO, \"blocked\": $BLOCKED, \"abandoned\": $ABANDONED, \"progress_pct\": $PCT, \"total_revisions\": $TOTAL_REVISIONS, \"max_revisions\": $MAX_REVISION, \"total_tracked_files\": $TOTAL_TRACKED, \"stagnant\": $STAGNANT, \"risk\": \"$RISK\"}"
else
  echo "=== SESSION HEALTH ==="
  echo "Progress: [$BAR] $PCT% ($DONE/$TOTAL tasks)"
  echo "Status: $DONE done, $IN_PROGRESS in progress, $TODO todo, $BLOCKED blocked, $ABANDONED abandoned"
  echo "Revisions: $TOTAL_REVISIONS total, $MAX_REVISION max (single task)"
  echo "Files tracked: $TOTAL_TRACKED"
  echo "Risk: $RISK"
  if [ "$STAGNANT" = true ]; then
    echo "WARNING: Task may be stagnant (in_progress with $MAX_REVISION revisions)"
  fi
fi
