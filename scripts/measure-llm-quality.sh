#!/usr/bin/env bash
# Measure LLM quality/fatigue metrics for a feature session.
# Analyzes revision counts, drift patterns, and correction iterations
# to produce a quality score that degrades with fatigue.
#
# Usage: scripts/measure-llm-quality.sh <feature_dir> [--json]
#
# Outputs:
#   Quality score (0-100), where 100 = perfect (no revisions needed)
#   Per-task revision counts
#   Fatigue warning if score drops below threshold
#
# Reads:
#   .artifacts/task-revisions/<task_id>.count  (revision counters)
#   tasks.md                                   (task statuses and spec revisions)

set -euo pipefail

FEATURE_DIR="${1:?Usage: measure-llm-quality.sh <feature_dir> [--json]}"
JSON_OUTPUT=false

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUTPUT=true ;;
  esac
  shift
done

REVISIONS_DIR="$FEATURE_DIR/.artifacts/task-revisions"
TASKS_FILE="$FEATURE_DIR/tasks.md"

# ── Collect revision counts per task ───────────────────────────
TOTAL_TASKS=0
COMPLETED_TASKS=0
TOTAL_REVISIONS=0
MAX_REVISIONS=0
HIGH_FATIGUE_TASKS=0  # tasks with >= 3 revisions

if [ -d "$REVISIONS_DIR" ]; then
  for count_file in "$REVISIONS_DIR"/*.count; do
    [ -f "$count_file" ] || continue
    task_id=$(basename "$count_file" .count)
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    case "$count" in
      ''|*[!0-9]*) count=0 ;;
    esac

    TOTAL_TASKS=$((TOTAL_TASKS + 1))
    TOTAL_REVISIONS=$((TOTAL_REVISIONS + count))
    if [ "$count" -gt "$MAX_REVISIONS" ]; then
      MAX_REVISIONS=$count
    fi
    if [ "$count" -ge 3 ]; then
      HIGH_FATIGUE_TASKS=$((HIGH_FATIGUE_TASKS + 1))
    fi
  done
fi

# Count completed tasks from tasks.md
if [ -f "$TASKS_FILE" ]; then
  COMPLETED_TASKS=$(grep -c 'Status: DONE' "$TASKS_FILE" 2>/dev/null || echo 0)
  TOTAL_TASKS_FROM_MD=$(grep -c '^## TASK-' "$TASKS_FILE" 2>/dev/null || echo 0)
  if [ "$TOTAL_TASKS_FROM_MD" -gt "$TOTAL_TASKS" ]; then
    TOTAL_TASKS=$TOTAL_TASKS_FROM_MD
  fi
fi

# ── Calculate quality score ────────────────────────────────────
# Score formula: start at 100, penalize for revisions
# - Each revision: -3 points
# - Tasks with 3+ revisions: additional -5 per task (fatigue indicator)
# - Max revisions > 3: additional -10 (severe fatigue)

SCORE=100
REVISION_PENALTY=$((TOTAL_REVISIONS * 3))
SCORE=$((SCORE - REVISION_PENALTY))

FATIGUE_PENALTY=$((HIGH_FATIGUE_TASKS * 5))
SCORE=$((SCORE - FATIGUE_PENALTY))

if [ "$MAX_REVISIONS" -gt 3 ]; then
  SEVERE_PENALTY=$(( (MAX_REVISIONS - 3) * 10 ))
  SCORE=$((SCORE - SEVERE_PENALTY))
fi

# Minimum score is 0
if [ "$SCORE" -lt 0 ]; then
  SCORE=0
fi

# ── Determine health label ─────────────────────────────────────
if [ "$SCORE" -ge 85 ]; then
  LABEL="GOOD"
elif [ "$SCORE" -ge 70 ]; then
  LABEL="FAIR"
elif [ "$SCORE" -ge 50 ]; then
  LABEL="DEGRADED"
else
  LABEL="CRITICAL"
fi

# ── Output ─────────────────────────────────────────────────────
if [ "$JSON_OUTPUT" = true ]; then
  echo "{\"score\": $SCORE, \"label\": \"$LABEL\", \"total_tasks\": $TOTAL_TASKS, \"completed_tasks\": $COMPLETED_TASKS, \"total_revisions\": $TOTAL_REVISIONS, \"max_revisions\": $MAX_REVISIONS, \"high_fatigue_tasks\": $HIGH_FATIGUE_TASKS}"
else
  echo "=== LLM QUALITY METRICS ==="
  echo "Session quality score: $SCORE / 100 ($LABEL)"
  echo "Tasks: $COMPLETED_TASKS / $TOTAL_TASKS completed"
  echo "Total revisions: $TOTAL_REVISIONS (avg: $TOTAL_TASKS; $(( TOTAL_REVISIONS * 100 / (TOTAL_TASKS > 0 ? TOTAL_TASKS : 1) ))% per task)"
  echo "Max revisions on single task: $MAX_REVISIONS"
  echo "High-fatigue tasks (3+ revisions): $HIGH_FATIGUE_TASKS"
  echo ""
  if [ "$LABEL" = "CRITICAL" ] || [ "$LABEL" = "DEGRADED" ]; then
    echo "WARNING: LLM fatigue detected. Consider:"
    echo "  - Breaking tasks into smaller units"
    echo "  - Taking a session break"
    echo "  - Reviewing tasks for ambiguity causing rework"
  fi
fi
