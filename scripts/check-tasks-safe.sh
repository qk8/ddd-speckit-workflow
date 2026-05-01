#!/usr/bin/env bash
# Wrapper for check-tasks.sh that handles failures gracefully.
# Prefers JSON state file (.tasks-state.json) for fast parsing,
# falls back to sourcing check-tasks.sh output.
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

# ── Attempt 1: Read JSON state file ─────────────────────────────
if [ -n "$FEATURE_DIR" ] && [ -f "$FEATURE_DIR/.tasks-state.json" ]; then
  JSON_FILE="$FEATURE_DIR/.tasks-state.json"
  # Validate JSON is parseable (basic check: must contain expected keys)
  if grep -q '"done"' "$JSON_FILE" 2>/dev/null && \
     grep -q '"todo"' "$JSON_FILE" 2>/dev/null && \
     grep -q '"total"' "$JSON_FILE" 2>/dev/null; then

    # Parse JSON fields using grep/sed (bash 3.2 compatible, no jq dependency)
    parse_json_field() {
      local key="$1"
      local file="$2"
      local val
      val=$(grep "\"${key}\"" "$file" 2>/dev/null | sed 's/.*"'"${key}"'":[[:space:]]*//' | sed 's/[",]//g' | tr -d '[:space:]' || true)
      echo "$val"
    }

    parse_json_bool() {
      local key="$1"
      local file="$2"
      local val
      val=$(grep "\"${key}\"" "$file" 2>/dev/null | sed 's/.*"'"${key}"'":[[:space:]]*//' | sed 's/[,}[:space:]]*//' || true)
      echo "$val"
    }

    parse_json_array() {
      local key="$1"
      local file="$2"
      local val
      val=$(grep "\"${key}\"" "$file" 2>/dev/null | sed 's/.*"'"${key}"'":[[:space:]]*//' | tr -d '[:space:]' || true)
      echo "$val"
    }

    _done=$(parse_json_field "done" "$JSON_FILE")
    _todo=$(parse_json_field "todo" "$JSON_FILE")
    _abandoned=$(parse_json_field "abandoned" "$JSON_FILE")
    _total=$(parse_json_field "total" "$JSON_FILE")
    _complexity=$(parse_json_field "complexity" "$JSON_FILE")
    _retro_interval=$(parse_json_field "retro_interval" "$JSON_FILE")
    _retro_trigger=$(parse_json_bool "retro_trigger" "$JSON_FILE")
    _in_progress_raw=$(parse_json_array "in_progress" "$JSON_FILE")

    # Default missing values
    _done=${_done:-0}
    _todo=${_todo:-0}
    _abandoned=${_abandoned:-0}
    _total=${_total:-0}
    _complexity=${_complexity:-medium}
    _retro_interval=${_retro_interval:-10}
    _retro_trigger=${_retro_trigger:-false}

    # Parse in_progress array: ["TASK-3", "TASK-5"] -> "TASK-3"
    IN_PROGRESS=""
    IN_PROGRESS_ALL=""
    if [ -n "$_in_progress_raw" ] && [ "$_in_progress_raw" != "[]" ]; then
      # Extract quoted strings from the array
      IN_PROGRESS_ALL=$(echo "$_in_progress_raw" | sed 's/^\[//;s/\]$//' | tr -d '"' | tr -d ' ' || true)
      IN_PROGRESS=$(echo "$IN_PROGRESS_ALL" | cut -d',' -f1)
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

# ── Attempt 2: Fall back to source check-tasks.sh ───────────────
if [ -z "$OUTPUT" ]; then
  OUTPUT=$(bash scripts/check-tasks.sh 2>/dev/null) || true
fi

# ── Attempt 3: If both failed, signal error with safe defaults ──
if [ -z "$OUTPUT" ]; then
  TASKS_PARSE_ERROR=1
  echo "TASKS_PARSE_ERROR=1"
  echo "ERROR: Both JSON state file and check-tasks.sh failed — tasks.md may be missing or malformed" >&2
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
