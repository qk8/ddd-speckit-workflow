#!/usr/bin/env bash
# Usage: telemetry.sh <action> [args...]
# Actions: init, phase_start, phase_end, gate, task_done, stagnation, report
# Writes to {{feature_dir}}/.specify/state/telemetry.json

FEATURE_DIR="${FEATURE_DIR:-.}"
# Try to find feature dir if not set
if [ ! -d "$FEATURE_DIR/.specify" ] && [ -f "$FEATURE_DIR/tasks.md" ]; then
  : # use as-is
else
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo ".")
fi
STATE_DIR="$FEATURE_DIR/.specify/state"
TELEM_FILE="$STATE_DIR/telemetry.json"

ACTION="${1:-init}"
mkdir -p "$STATE_DIR"

case "$ACTION" in
  init)
    echo '{"version":1,"phases":{},"gates":[],"tasks":[],"started_at":"'$(date -u '+%Y-%m-%dT%H:%M:%SZ')'"}' > "$TELEM_FILE"
    ;;
  phase_start)
    PHASE_ID="${2:?}"
    TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    # Read current file, update phase start
    if [ -f "$TELEM_FILE" ]; then
      sed "s/\"$PHASE_ID\":.*}/\"$PHASE_ID\": {\"start\": \"$TIMESTAMP\"}}/" "$TELEM_FILE" > "$TELEM_FILE.tmp" 2>/dev/null || true
      mv "$TELEM_FILE.tmp" "$TELEM_FILE" 2>/dev/null || true
    fi
    ;;
  phase_end)
    PHASE_ID="${2:?}"
    DURATION="${3:-0}"
    TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if [ -f "$TELEM_FILE" ]; then
      sed "s/\"$PHASE_ID\":.*}/\"$PHASE_ID\": {\"start\": \"...\", \"end\": \"$TIMESTAMP\", \"duration_s\": $DURATION}}/" "$TELEM_FILE" > "$TELEM_FILE.tmp" 2>/dev/null || true
      mv "$TELEM_FILE.tmp" "$TELEM_FILE" 2>/dev/null || true
    fi
    ;;
  gate)
    GATE_ID="${2:?}"
    GATE_RESULT="${3:?}"
    TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if [ -f "$TELEM_FILE" ]; then
      # Append to gates array
      sed "s/\"gates\": \[/\"gates\": [{\"gate\": \"$GATE_ID\", \"result\": \"$GATE_RESULT\", \"at\": \"$TIMESTAMP\"}, /" "$TELEM_FILE" > "$TELEM_FILE.tmp" 2>/dev/null || true
      mv "$TELEM_FILE.tmp" "$TELEM_FILE" 2>/dev/null || true
    fi
    ;;
  task_done)
    TASK_ID="${2:?}"
    TASK_TYPE="${3:-}"
    TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if [ -f "$TELEM_FILE" ]; then
      sed "s/\"tasks\": \[/\"tasks\": [{\"task\": \"$TASK_ID\", \"type\": \"$TASK_TYPE\", \"completed_at\": \"$TIMESTAMP\"}, /" "$TELEM_FILE" > "$TELEM_FILE.tmp" 2>/dev/null || true
      mv "$TELEM_FILE.tmp" "$TELEM_FILE" 2>/dev/null || true
    fi
    ;;
  stagnation)
    COUNT="${2:?}"
    TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if [ -f "$TELEM_FILE" ]; then
      sed "s/\"stagnation_events\":.*/\"stagnation_events\": ${COUNT}, \"last_at\": \"$TIMESTAMP\"}/" "$TELEM_FILE" > "$TELEM_FILE.tmp" 2>/dev/null || true
      mv "$TELEM_FILE.tmp" "$TELEM_FILE" 2>/dev/null || true
    fi
    ;;
  report)
    if [ -f "$TELEM_FILE" ]; then
      cat "$TELEM_FILE"
    else
      echo "No telemetry data found."
    fi
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    exit 1
    ;;
esac
