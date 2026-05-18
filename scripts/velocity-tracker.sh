#!/usr/bin/env bash
# velocity-tracker.sh — Track implementation velocity and estimate remaining time.
#
# Records timestamps for task completions and computes average time per task.
# When velocity drops below a threshold, triggers proactive context management.
#
# Usage:
#   velocity-tracker.sh record <feature_dir> <task_id>
#   velocity-tracker.sh status <feature_dir> [--threshold-minutes N]
#
# Reads: state.json (task timestamps, completion history)
# Writes: state.json (velocity metrics, timestamps)

set -euo pipefail

ACTION="${1:-status}"
FEATURE_DIR="${2:?Usage: velocity-tracker.sh <record|status> <feature_dir> [task_id]}"
STATE_FILE="$FEATURE_DIR/state.json"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

DEFAULT_THRESHOLD=120  # minutes

if [ "$ACTION" = "record" ]; then
  TASK_ID="${3:?Usage: velocity-tracker.sh record <feature_dir> <task_id>}"

  if [ ! -f "$STATE_FILE" ]; then
    echo "VELOCITY: SKIP — no state.json"
    exit 0
  fi

  # Record completion timestamp
  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  EPOCH=$(date +%s 2>/dev/null || echo 0)

  # Append to velocity log
  echo "$EPOCH $TASK_ID $TIMESTAMP" >> "$ARTIFACTS_DIR/velocity-log.txt"

  # Update state.json with latest completion
  TMP=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg ts "$TIMESTAMP" \
     --arg tid "$TASK_ID" \
     --argjson epoch "$EPOCH" \
     '.tasks[$tid].completed_at = $ts | .tasks[$tid].completion_epoch = $epoch | .metadata.updated_at = $ts' \
     "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"

  echo "VELOCITY: Recorded completion for $TASK_ID at $TIMESTAMP"
  exit 0
fi

if [ "$ACTION" = "status" ]; then
  THRESHOLD="$DEFAULT_THRESHOLD"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --threshold-minutes) THRESHOLD="${2:-$DEFAULT_THRESHOLD}"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ ! -f "$STATE_FILE" ]; then
    echo "VELOCITY: SKIP — no state.json"
    exit 0
  fi

  # Read velocity log
  VELOCITY_LOG="$ARTIFACTS_DIR/velocity-log.txt"
  if [ ! -f "$VELOCITY_LOG" ]; then
    echo "VELOCITY: SKIP — no velocity log"
    exit 0
  fi

  # Compute velocity metrics
  COMPLETION_COUNT=$(wc -l < "$VELOCITY_LOG" | tr -d ' ')
  if [ "$COMPLETION_COUNT" -lt 2 ]; then
    echo "VELOCITY: INSUFFICIENT_DATA — only $COMPLETION_COUNT task(s) completed"
    exit 0
  fi

  # Get first and last completion epochs
  FIRST_EPOCH=$(head -1 "$VELOCITY_LOG" | awk '{print $1}')
  LAST_EPOCH=$(tail -1 "$VELOCITY_LOG" | awk '{print $1}')
  ELAPSED_SECONDS=$((LAST_EPOCH - FIRST_EPOCH))
  ELAPSED_MINUTES=$((ELAPSED_SECONDS / 60))

  if [ "$ELAPSED_MINUTES" -le 0 ]; then
    echo "VELOCITY: SKIP — insufficient time elapsed"
    exit 0
  fi

  # Average time per task
  AVG_PER_TASK=$((ELAPSED_MINUTES / (COMPLETION_COUNT - 1)))
  [ "$AVG_PER_TASK" -le 0 ] && AVG_PER_TASK=1

  # Remaining tasks
  REMAINING=$(jq '[.tasks | to_entries[] | select(.value.status == "TODO" or .value.status == "IN_PROGRESS")] | length' "$STATE_FILE" 2>/dev/null || echo 0)

  # Estimated remaining time
  ETA_MINUTES=$((REMAINING * AVG_PER_TASK))
  ETA_HOURS=$((ETA_MINUTES / 60))
  ETA_REMAINING_MIN=$((ETA_MINUTES % 60))

  # Health assessment
  HEALTH="GOOD"
  if [ "$AVG_PER_TASK" -gt "$THRESHOLD" ]; then
    HEALTH="CRITICAL"
  elif [ "$AVG_PER_TASK" -gt $((THRESHOLD / 2)) ]; then
    HEALTH="DEGRADED"
  elif [ "$AVG_PER_TASK" -gt $((THRESHOLD / 4)) ]; then
    HEALTH="FAIR"
  fi

  # Output
  echo "=== VELOCITY TRACKING ==="
  echo "  Tasks completed:    $COMPLETION_COUNT"
  echo "  Average per task:   ${AVG_PER_TASK} minutes"
  echo "  Remaining tasks:    $REMAINING"
  echo "  Estimated time:     ${ETA_HOURS}h ${ETA_REMAINING_MIN}m"
  echo "  Health:             $HEALTH"

  # If velocity is degrading, trigger proactive measures
  if [ "$HEALTH" = "CRITICAL" ] || [ "$HEALTH" = "DEGRADED" ]; then
    echo ""
    echo "WARNING: Implementation velocity is $HEALTH (avg ${AVG_PER_TASK} min/task)."
    echo "Consider:"
    echo "  - Running /speckit.context to compact context"
    echo "  - Breaking remaining tasks into smaller units"
    echo "  - Taking a session break"

    # Record velocity alert in state.json
    if [ -f "$STATE_FILE" ]; then
      TMP=$(mktemp "${STATE_FILE}.XXXXXX")
      jq --arg health "$HEALTH" \
         --argjson avg "$AVG_PER_TASK" \
         --argjson eta "$ETA_MINUTES" \
         '.velocity = {
            "health": $health,
            "avg_minutes_per_task": $avg,
            "estimated_remaining_minutes": $eta,
            "last_checked": (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
          } | .metadata.updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
         "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
    fi
  fi

  exit 0
fi

echo "ERROR: Unknown action '$ACTION'. Use 'record' or 'status'." >&2
exit 1
