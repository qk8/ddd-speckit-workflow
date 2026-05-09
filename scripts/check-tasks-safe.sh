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

# ── Helper: parse JSON field robustly ──────────────────────────
# Tries python3 first (most reliable), then jq, then falls back to grep/sed.
parse_json_field() {
  local key="$1"
  local file="$2"
  local result=""

  if command -v python3 &>/dev/null; then
    result=$(python3 -c "
import json, sys
try:
    with open('$file') as f:
        data = json.load(f)
    keys = '$key'.split('.')
    val = data
    for k in keys:
        val = val[k] if isinstance(val, dict) else val
    v = val if isinstance(val, (str, int, float, bool)) else str(val)
    print(v)
except Exception:
    pass
" 2>/dev/null) || true
  elif command -v jq &>/dev/null; then
    result=$(jq -r ".$key // empty" "$file" 2>/dev/null) || true
  fi

  if [ -z "$result" ]; then
    # Fallback: grep/sed (may match keys inside string values)
    result=$(grep "\"${key}\"" "$file" 2>/dev/null | sed 's/.*"'"${key}"'":[[:space:]]*//' | sed 's/[",]//g' | tr -d '[:space:]' || true)
  fi

  echo "$result" || true
}

parse_json_bool() {
  local key="$1"
  local file="$2"
  local result
  result=$(parse_json_field "$key" "$file")
  case "$result" in
    true|True|TRUE|1) echo "true" ;;
    false|False|FALSE|0) echo "false" ;;
    *) echo "$result" ;;
  esac
}

# ── Helper: validate numeric value ──────────────────────────────
ensure_numeric() {
  local val="$1" default="$2"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "$val"
  else
    echo "$default"
  fi
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
    _done=$(ensure_numeric "$_done" 0)
    _in_prog=$(ensure_numeric "$_in_prog" 0)
    _abandoned=$(ensure_numeric "$_abandoned" 0)
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
      IN_PROGRESS_ALL=$(echo "$IN_PROGRESS_ALL" | sed 's/,$//')
    fi
    IN_PROGRESS=$(echo "$IN_PROGRESS_ALL" | cut -d',' -f1)

    # Read metadata
    _complexity=$(parse_json_field "complexity" "$JSON_FILE")
    _complexity=${_complexity:-medium}
    _retro_interval=$(parse_json_field "interval" "$JSON_FILE")
    _retro_interval=$(ensure_numeric "${_retro_interval:-10}" 10)
    _next_due=$(parse_json_field "next_due" "$JSON_FILE")
    _next_due=$(ensure_numeric "${_next_due:-5}" 5)
    _done_count_check=${_done}

    # ── Stale state validation: cross-check against tasks.md ──
    _layer1_valid=true
    if [ -n "$FEATURE_DIR" ] && [ -f "$FEATURE_DIR/tasks.md" ]; then
      # Count actual DONE tasks in tasks.md
      _actual_done=$(grep -c "^Status: DONE$" "$FEATURE_DIR/tasks.md" 2>/dev/null || true)
      # If JSON done count differs from tasks.md by more than 1, skip layer 1
      _diff=$((_done - _actual_done))
      [ "$_diff" -lt 0 ] && _diff=$((_diff * -1))
      if [ "$_diff" -gt 1 ]; then
        _layer1_valid=false
      fi
    fi

    if [ "$_layer1_valid" = true ]; then
      # Determine retro_trigger using modulo formula (same as check-tasks.sh)
      _retro_trigger="false"
      if [ "$_done_count_check" -ge "$_next_due" ] 2>/dev/null; then
        _remainder=$(( (_done_count_check - _next_due) % _retro_interval ))
        if [ "$_remainder" -eq 0 ]; then
          _retro_trigger="true"
        fi
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
first_retro_threshold=${_next_due}
retro_trigger=${_retro_trigger}
feature_dir=${FEATURE_DIR}
todo_task_id=
todo_task_type=
    fi
    # If _layer1_valid is false, fall through to layer 2/3
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
    _done=$(ensure_numeric "${_done:-0}" 0)
    _todo=$(ensure_numeric "${_todo:-0}" 0)
    _abandoned=$(ensure_numeric "${_abandoned:-0}" 0)
    _total=$(ensure_numeric "${_total:-0}" 0)
    _retro_interval=$(ensure_numeric "${_retro_interval:-10}" 10)
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
feature_dir=${FEATURE_DIR}
todo_task_id=
todo_task_type=
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
has_todo=true
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
todo_task_id=
todo_task_type=
DEFAULTS
  exit 0
fi

echo "$OUTPUT"
exit 0
