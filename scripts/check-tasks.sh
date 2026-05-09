#!/usr/bin/env bash
# Usage: ./scripts/check-tasks.sh [--json]
# Outputs shell variables for ddd-workflow.yml:
#   has_todo, done_count, todo_count, in_progress, abandoned_count
#
# When --json is passed, also writes JSON state to {{feature_dir}}/.tasks-state.json

set -euo pipefail

JSON_MODE=false
if [ "${1:-}" = "--json" ]; then
  JSON_MODE=true
fi

FEATURE_DIR=$(bash scripts/find-first-feature.sh)

# Read cadence defaults from preset.yml (single source of truth)
source scripts/cadence-defaults.sh
PRESET_FILE="ddd-clean-arch/preset.yml"
DEFAULT_RETRO_INTERVAL="$CADENCE_RETRO_INTERVAL_MEDIUM"
DEFAULT_FIRST_RETRO_THRESHOLD="$CADENCE_FIRST_RETRO_THRESHOLD"
DEFAULT_DRIFT_CHECK_INTERVAL=15
DEFAULT_TRACEABILITY_CHECK_INTERVAL=20
if [ -f "$PRESET_FILE" ]; then
  DEFAULT_RETRO_INTERVAL=$(bash scripts/read-preset-cadence.sh medium "$PRESET_FILE" 2>/dev/null) || true
  [ -z "$DEFAULT_RETRO_INTERVAL" ] && DEFAULT_RETRO_INTERVAL="$CADENCE_RETRO_INTERVAL_MEDIUM"
  DEFAULT_FIRST_RETRO_THRESHOLD=$(bash scripts/read-preset-cadence.sh first_retro_threshold "$PRESET_FILE" 2>/dev/null) || true
  [ -z "$DEFAULT_FIRST_RETRO_THRESHOLD" ] && DEFAULT_FIRST_RETRO_THRESHOLD="$CADENCE_FIRST_RETRO_THRESHOLD"
  DEFAULT_DRIFT_CHECK_INTERVAL=$(bash scripts/read-preset-cadence.sh drift_check_interval "$PRESET_FILE" 2>/dev/null) || true
  [ -z "$DEFAULT_DRIFT_CHECK_INTERVAL" ] && DEFAULT_DRIFT_CHECK_INTERVAL="$CADENCE_RETRO_INTERVAL_MEDIUM"
  DEFAULT_TRACEABILITY_CHECK_INTERVAL=$(bash scripts/read-preset-cadence.sh traceability_check_interval "$PRESET_FILE" 2>/dev/null) || true
  [ -z "$DEFAULT_TRACEABILITY_CHECK_INTERVAL" ] && DEFAULT_TRACEABILITY_CHECK_INTERVAL=20
fi

if [ -z "$FEATURE_DIR" ] || [ ! -f "$FEATURE_DIR/tasks.md" ]; then
  echo "has_todo=false"; echo "done_count=0"; echo "todo_count=0"
  echo "in_progress="; echo "abandoned_count=0"; echo "total_tasks=0"
  echo "complexity=medium"; echo "retro_interval=$DEFAULT_RETRO_INTERVAL"; echo "first_retro_threshold=$DEFAULT_FIRST_RETRO_THRESHOLD"
  echo "drift_check_interval=$DEFAULT_DRIFT_CHECK_INTERVAL"
  echo "traceability_check_interval=$DEFAULT_TRACEABILITY_CHECK_INTERVAL"
  echo "retro_trigger=false"
  echo "feature_dir=${FEATURE_DIR:-}"
  if [ "$JSON_MODE" = true ] && [ -n "${FEATURE_DIR:-}" ]; then
    PARSED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$FEATURE_DIR/.tasks-state.json" <<EJSON
{
  "done": 0,
  "todo": 0,
  "in_progress": [],
  "abandoned": 0,
  "total": 0,
  "complexity": "medium",
  "retro_interval": ${DEFAULT_RETRO_INTERVAL},
  "drift_check_interval": ${DEFAULT_DRIFT_CHECK_INTERVAL},
  "traceability_check_interval": ${DEFAULT_TRACEABILITY_CHECK_INTERVAL},
  "retro_trigger": false,
  "parsed_at": "${PARSED_AT}"
}
EJSON
  fi
  exit 0
fi

TASKS_FILE="$FEATURE_DIR/tasks.md"

# Sanitize: strip \r (Windows line endings) only.
# Do NOT strip leading whitespace — indented scope blocks must be preserved.
SANITIZED_FILE=$(mktemp)
trap 'rm -f "$SANITIZED_FILE"' EXIT
sed 's/\r$//' "$TASKS_FILE" > "$SANITIZED_FILE"
TASKS_FILE="$SANITIZED_FILE"

# ── Block-aware parsing (Fixes 11 & 15) ──────────────────────
# Use awk to parse: only match Status lines that appear after a
# "## TASK-" header and before the next "## TASK-" or "###" header.
# This avoids false positives from Status-like text in task titles,
# scope blocks, or description paragraphs.
#
# Also outputs IN_PROGRESS_ALL as comma-separated task indices.
read -r DONE_COUNT TODO_COUNT ABANDONED_COUNT TOTAL_TASKS IN_PROGRESS_ALL <<< "$(
  awk '
    /^## TASK-/ {
      if (in_task && status == "IN_PROGRESS") {
        if (ip_count > 0) ip = ip ","
        ip = ip task_id
      }
      task_idx++
      # Extract task ID from header: "## TASK-1" -> "TASK-1"
      task_id = $0
      sub(/^## /, "", task_id)
      in_task = 1
      status = ""
      next
    }
    /^###/ { in_task = 0 }
    in_task && /^Status:/ {
      s = $0
      sub(/^Status:[[:space:]]*/, "", s)
      status = s
    }
    in_task && status == "DONE" { done++ }
    in_task && status == "TODO" { todo++ }
    in_task && status == "IN_PROGRESS" {
      if (first_ip == 0) { first_ip = 1; first = task_id }
      ip_count++
    }
    in_task && status == "ABANDONED" { abandoned++ }
    END {
      if (done == "") done = 0
      if (todo == "") todo = 0
      if (abandoned == "") abandoned = 0
      if (first_ip == 0) first = ""
      printf "%d %d %d %d %s %s\n", done, todo, abandoned, task_idx, first, ip
    }
  ' "$SANITIZED_FILE"
)"

TOTAL_TASKS=$(grep -c "^## TASK-" "$SANITIZED_FILE" || true)
# Ensure numeric
DONE_COUNT=${DONE_COUNT:-0}
TODO_COUNT=${TODO_COUNT:-0}
ABANDONED_COUNT=${ABANDONED_COUNT:-0}
IN_PROGRESS_ALL=${IN_PROGRESS_ALL:-}
# Keep IN_PROGRESS as first one for backward compatibility with workflow conditions
IN_PROGRESS=$(echo "$IN_PROGRESS_ALL" | cut -d',' -f1)

if [ -n "$IN_PROGRESS_ALL" ]; then
  if echo "$IN_PROGRESS_ALL" | grep -q ','; then
    echo "WARNING: Multiple IN_PROGRESS tasks detected — workflow state may be corrupted." >&2
    echo "  Tasks: $IN_PROGRESS_ALL" >&2
    echo "  Only the first task is active. Reset others to TODO or ABANDONED." >&2
  else
    echo "WARNING: Status: IN_PROGRESS found — previous session interrupted." >&2
    echo "  Task: $IN_PROGRESS" >&2
    echo "  Mark it TODO to restart, or ABANDONED to discard partial work." >&2
  fi
fi

if [ "$ABANDONED_COUNT" -gt 0 ]; then
  echo "WARNING: $ABANDONED_COUNT ABANDONED task(s) — review and clean up partial files." >&2
fi

if [ "$TODO_COUNT" -gt 0 ] || [ -n "$IN_PROGRESS" ]; then
  HAS_TODO="true"
else
  HAS_TODO="false"
fi

# Issue J: Extract the type of the first TODO task (for spec_revision routing)
# Read the Type field from the first TODO task block
TODO_TASK_ID=""
TODO_TASK_TYPE=""
if [ "$TODO_COUNT" -gt 0 ]; then
  # Find the first ## TASK- line followed by a TODO status
  _current_task=""
  _current_type=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE "^## TASK-"; then
      _current_task=$(echo "$line" | sed 's/^## //')
    fi
    if echo "$line" | grep -qE "^Type:" && [ -n "$_current_task" ]; then
      _current_type=$(echo "$line" | sed 's/^Type:[[:space:]]*//')
    fi
    if echo "$line" | grep -qE "^Status: TODO$" && [ -n "$_current_task" ]; then
      TODO_TASK_ID="$_current_task"
      TODO_TASK_TYPE="${_current_type:-backend-domain}"
      break
    fi
  done < "$TASKS_FILE"
fi

# Adaptive retrospective cadence based on total task count and complexity
# Complexity is read from project-brief.md; defaults to "medium"
# project-brief.md format: "## Complexity" header followed by value on next line
COMPLEXITY="medium"
if [ -f "project-brief.md" ]; then
  COMPLEXITY=$(awk '/^## Complexity/{found=1; next} found && /^[^ ]/{print tolower($1); exit}' project-brief.md)
  case "$COMPLEXITY" in
    simple|medium|complex) ;; # valid
    *) COMPLEXITY="medium" ;;
  esac
fi

# Determine retrospective interval based on complexity — read from preset.yml
RETRO_INTERVAL="$DEFAULT_RETRO_INTERVAL"
case "$COMPLEXITY" in
  simple)
    PRESET_SIMPLE=$(bash scripts/read-preset-cadence.sh simple "$PRESET_FILE" 2>/dev/null) || true
    [ -n "$PRESET_SIMPLE" ] && RETRO_INTERVAL="$PRESET_SIMPLE"
    ;;
  complex)
    PRESET_COMPLEX=$(bash scripts/read-preset-cadence.sh complex "$PRESET_FILE" 2>/dev/null) || true
    [ -n "$PRESET_COMPLEX" ] && RETRO_INTERVAL="$PRESET_COMPLEX"
    ;;
esac

# First retrospective threshold — read from preset.yml
FIRST_RETRO_THRESHOLD="$DEFAULT_FIRST_RETRO_THRESHOLD"

# Determine if retrospective should trigger
# Triggers at first_retro_threshold, then every retro_interval tasks thereafter
RETRO_TRIGGER=false
if [ "$DONE_COUNT" -ge "$FIRST_RETRO_THRESHOLD" ]; then
  if [ "$DONE_COUNT" -eq "$FIRST_RETRO_THRESHOLD" ]; then
    RETRO_TRIGGER=true
  elif [ $(( (DONE_COUNT - FIRST_RETRO_THRESHOLD) % RETRO_INTERVAL )) -eq 0 ]; then
    RETRO_TRIGGER=true
  fi
fi

echo "has_todo=$HAS_TODO"
echo "done_count=$DONE_COUNT"
echo "todo_count=$TODO_COUNT"
echo "in_progress=$IN_PROGRESS"
echo "in_progress_all=$IN_PROGRESS_ALL"
echo "abandoned_count=$ABANDONED_COUNT"
echo "total_tasks=$TOTAL_TASKS"
echo "complexity=$COMPLEXITY"
echo "retro_interval=$RETRO_INTERVAL"
echo "first_retro_threshold=$FIRST_RETRO_THRESHOLD"
echo "retro_trigger=$RETRO_TRIGGER"
echo "drift_check_interval=$DEFAULT_DRIFT_CHECK_INTERVAL"
echo "traceability_check_interval=$DEFAULT_TRACEABILITY_CHECK_INTERVAL"
echo "feature_dir=$FEATURE_DIR"
echo "todo_task_id=$TODO_TASK_ID"
echo "todo_task_type=$TODO_TASK_TYPE"

# ── JSON output (when --json flag is used) ──────────────────────
if [ "$JSON_MODE" = true ]; then
  # Build in_progress JSON array (bash 3.2 compatible)
  IN_PROGRESS_JSON="[]"
  if [ -n "$IN_PROGRESS_ALL" ]; then
    IN_PROGRESS_JSON="["
    first=true
    OLD_IFS="$IFS"
    IFS=','
    for item in $IN_PROGRESS_ALL; do
      item=$(echo "$item" | xargs)
      if [ "$first" = true ]; then
        IN_PROGRESS_JSON="${IN_PROGRESS_JSON}\"$item\""
        first=false
      else
        IN_PROGRESS_JSON="${IN_PROGRESS_JSON}, \"$item\""
      fi
    done
    IFS="$OLD_IFS"
    IN_PROGRESS_JSON="${IN_PROGRESS_JSON}]"
  fi

  PARSED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  JSON_OUT=$(cat <<STATEOF
{
  "done": ${DONE_COUNT},
  "todo": ${TODO_COUNT},
  "in_progress": ${IN_PROGRESS_JSON},
  "abandoned": ${ABANDONED_COUNT},
  "total": ${TOTAL_TASKS},
  "complexity": "${COMPLEXITY}",
  "retro_interval": ${RETRO_INTERVAL},
  "drift_check_interval": ${DEFAULT_DRIFT_CHECK_INTERVAL},
  "traceability_check_interval": ${DEFAULT_TRACEABILITY_CHECK_INTERVAL},
  "retro_trigger": ${RETRO_TRIGGER},
  "parsed_at": "${PARSED_AT}"
}
STATEOF
)

  if [ -n "$FEATURE_DIR" ]; then
    echo "$JSON_OUT" > "$FEATURE_DIR/.tasks-state.json"
    echo "Wrote task state to $FEATURE_DIR/.tasks-state.json" >&2
  fi
fi
