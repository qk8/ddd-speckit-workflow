#!/usr/bin/env bash
# Wrapper for check-tasks.sh that handles failures gracefully.
# Prefers .workflow-state.json (structured checkpoint) for fast parsing.
# Falls back to .tasks-state.json (legacy JSON), then check-tasks.sh output.
#
# If both fail, outputs TASKS_PARSE_ERROR=1 so the workflow can detect
# the condition instead of silently proceeding with wrong state.
#
# Usage: bash scripts/check-tasks-safe.sh
#
# Output: same key=value format as check-tasks.sh, plus TASKS_PARSE_ERROR=1
# on failure. Guaranteed to never exit non-zero.

set -euo pipefail

FEATURE_DIR="${FEATURE_DIR:-$(bash scripts/find-first-feature.sh 2>/dev/null || true)}"
FEATURE_DIR="${FEATURE_DIR:-}"

TASKS_PARSE_ERROR=0
OUTPUT=""

# ── Helper: parse JSON field with grep/sed (bash 3.2 compatible) ─
parse_json_field() {
  local key="$1"
  local file="$2"
  grep "\"${key}\"" "$file" 2>/dev/null | sed 's/.*"'"${key}"'":[[:space:]]*//' | sed 's/[",]//g' | tr -d '[:space:]' || true
}

parse_json_bool() {
  local key="$1"
  local file="$2"
  grep "\"${key}\"" "$file" 2>/dev/null | sed 's/.*"'"${key}"'":[[:space:]]*//' | sed 's/[,}[:space:]]*//' || true
}

# ── Attempt 1: Read .workflow-state.json (structured checkpoint) ──
if [ -n "$FEATURE_DIR" ] && [ -f "$FEATURE_DIR/.workflow-state.json" ]; then
  JSON_FILE="$FEATURE_DIR/.workflow-state.json"
  # Validate: must contain task entries with status field
  if grep -q '"status"' "$JSON_FILE" 2>/dev/null; then
    # Count task statuses from checkpoint
    _done=$(grep -c '"status"[[:space:]]*:[[:space:]]*"DONE"' "$JSON_FILE" 2>/dev/null || true)
    _in_prog=$(grep -c '"status"[[:space:]]*:[[:space:]]*"IN_PROGRESS"' "$JSON_FILE" 2>/dev/null || true)
    _abandoned=$(grep -c '"status"[[:space:]]*:[[:space:]]*"ABANDONED"' "$JSON_FILE" 2>/dev/null || true)
    _done=${_done:-0}
    _in_prog=${_in_prog:-0}
    _abandoned=${_abandoned:-0}
    _total=$(( _done + _in_prog + _abandoned ))
    _todo=$(( _total - _done ))
    _todo=${_todo:-0}
    [ "$_todo" -lt 0 ] 2>/dev/null && _todo=0

    # Extract IN_PROGRESS task IDs
    IN_PROGRESS_ALL=""
    if [ "$_in_prog" -gt 0 ] 2>/dev/null; then
      # Each task entry has "TASK-N": { ... "status": "IN_PROGRESS" ... }
      # Extract task IDs by finding lines with both TASK- and IN_PROGRESS
      IN_PROGRESS_ALL=$(awk '
        /"TASK-[0-9]+"/ {
          match($0, /"TASK-[0-9]+"/)
          tid = substr($0, RSTART+1, RLENGTH-2)
        }
        /"status"[[:space:]]*:[[:space:]]*"IN_PROGRESS"/ {
          if (tid != "") printf "%s,", tid
          tid = ""
        }
      ' "$JSON_FILE" 2>/dev/null || true)
      # Clean up trailing comma
      IN_PROGRESS_ALL=$(echo "$IN_PROGRESS_ALL" | sed 's/,$//')
    fi
    IN_PROGRESS=$(echo "$IN_PROGRESS_ALL" | cut -d',' -f1)

    # Read metadata
    _complexity=$(parse_json_field "complexity" "$JSON_FILE")
    _complexity=${_complexity:-medium}
    _retro_interval=$(parse_json_field "interval" "$JSON_FILE")
    _retro_interval=${_retro_interval:-10}
    _next_due=$(parse_json_field "next_due" "$JSON_FILE")
    _next_due=${_next_due:-5}
    _done_count_check=${_done}

    # Determine retro_trigger: true if done_count >= next_due
    _retro_trigger="false"
    if [ "$_done_count_check" -ge "$_next_due" ] 2>/dev/null; then
      # Check if we already triggered (no revision history would indicate this)
      _retro_trigger="true"
    fi

    # Determine has_todo
    if [ "$_todo" -gt 0 ] 2>/dev/null || [ -n "$IN_PROGRESS" ]; then
      HAS_TODO="true"
    else
      HAS_TODO="false"
    fi

    OUTPUT="has_todo=${HAS_TODO}
done_count=${_done}
todo_count=${_todo}
in_progress=${IN_PROGRESS}
in_progress_all=${IN_PROGRESS_ALL}
abandoned_count=${_abandoned}
total_tasks=${_total}
complexity=${_complexity}
retro_interval=${_retro_interval}
first_retro_threshold=5
retro_trigger=${_retro_trigger}
feature_dir=${FEATURE_DIR}"
  fi
fi

# ── Attempt 2: Read legacy .tasks-state.json ────────────────────
if [ -z "$OUTPUT" ] && [ -n "$FEATURE_DIR" ] && [ -f "$FEATURE_DIR/.tasks-state.json" ]; then
  JSON_FILE="$FEATURE_DIR/.tasks-state.json"
  if grep -q '"done"' "$JSON_FILE" 2>/dev/null && \
     grep -q '"todo"' "$JSON_FILE" 2>/dev/null && \
     grep -q '"total"' "$JSON_FILE" 2>/dev/null; then

    parse_json_array() {
      local key="$1"
      local file="$2"
      grep "\"${key}\"" "$file" 2>/dev/null | sed 's/.*"'"${key}"'":[[:space:]]*//' | tr -d '[:space:]' || true
    }

    _done=$(parse_json_field "done" "$JSON_FILE")
    _todo=$(parse_json_field "todo" "$JSON_FILE")
    _abandoned=$(parse_json_field "abandoned" "$JSON_FILE")
    _total=$(parse_json_field "total" "$JSON_FILE")
    _complexity=$(parse_json_field "complexity" "$JSON_FILE")
    _retro_interval=$(parse_json_field "retro_interval" "$JSON_FILE")
    _retro_trigger=$(parse_json_bool "retro_trigger" "$JSON_FILE")
    _in_progress_raw=$(parse_json_array "in_progress" "$JSON_FILE")

    _done=${_done:-0}
    _todo=${_todo:-0}
    _abandoned=${_abandoned:-0}
    _total=${_total:-0}
    _complexity=${_complexity:-medium}
    _retro_interval=${_retro_interval:-10}
    _retro_trigger=${_retro_trigger:-false}

    IN_PROGRESS=""
    IN_PROGRESS_ALL=""
    if [ -n "$_in_progress_raw" ] && [ "$_in_progress_raw" != "[]" ]; then
      IN_PROGRESS_ALL=$(echo "$_in_progress_raw" | sed 's/^\[//;s/\]$//' | tr -d '"' | tr -d ' ' || true)
      IN_PROGRESS=$(echo "$IN_PROGRESS_ALL" | cut -d',' -f1)
    fi

    if [ "$_todo" -gt 0 ] 2>/dev/null || [ -n "$IN_PROGRESS" ]; then
      HAS_TODO="true"
    else
      HAS_TODO="false"
    fi

    OUTPUT="has_todo=${HAS_TODO}
done_count=${_done}
todo_count=${_todo}
in_progress=${IN_PROGRESS}
in_progress_all=${IN_PROGRESS_ALL}
abandoned_count=${_abandoned}
total_tasks=${_total}
complexity=${_complexity}
retro_interval=${_retro_interval}
first_retro_threshold=5
retro_trigger=${_retro_trigger}
feature_dir=${FEATURE_DIR}"
  fi
fi

# ── Attempt 3: Fall back to source check-tasks.sh ───────────────
if [ -z "$OUTPUT" ]; then
  OUTPUT=$(bash scripts/check-tasks.sh 2>/dev/null) || true
fi

# ── Attempt 4: If all failed, signal error with safe defaults ───
if [ -z "$OUTPUT" ]; then
  TASKS_PARSE_ERROR=1
  echo "TASKS_PARSE_ERROR=1"
  echo "ERROR: Both JSON state files and check-tasks.sh failed — tasks.md may be missing or malformed" >&2
  echo "       Run: bash scripts/check-tasks.sh (without safe wrapper) to diagnose" >&2
  set +e
  source scripts/cadence-defaults.sh
  set -e
  cat <<DEFAULTS
has_todo=false
done_count=0
todo_count=0
in_progress=
in_progress_all=
abandoned_count=0
total_tasks=0
complexity=medium
retro_interval=${CADENCE_RETRO_INTERVAL_MEDIUM}
first_retro_threshold=${CADENCE_FIRST_RETRO_THRESHOLD}
retro_trigger=false
feature_dir=
DEFAULTS
  exit 0
fi

echo "$OUTPUT"
exit 0
