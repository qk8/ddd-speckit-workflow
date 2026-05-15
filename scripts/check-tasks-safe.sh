#!/usr/bin/env bash
# Wrapper for check-tasks.sh that handles failures gracefully.
# Prefers state.json (unified state engine), then .workflow-state.json,
# then .tasks-state.json (legacy JSON), then check-tasks.sh output.
#
# If all fail, outputs TASKS_PARSE_ERROR=1 so the workflow can detect
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

# ── Helpers ──────────────────────────────────────────────────────

# Validate numeric: return value if digits-only, else default
ensure_numeric() {
  local val="$1" default="$2"
  if [[ "$val" =~ ^[0-9]+$ ]]; then echo "$val"; else echo "$default"; fi
}

# Parse a JSON field: python3 > jq > grep fallback
parse_json_field() {
  local key="$1" file="$2" result=""
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
    # Match exact key (not partial: "done" must not match "done_count")
    result=$(grep -E "\"${key}\"[[:space:]]*:" "$file" 2>/dev/null | head -1 | sed 's/.*"'"${key}"'"[[:space:]]*:[[:space:]]*//' | sed 's/[",]//g' | tr -d '[:space:]' || true)
  fi
  echo "$result" || true
}

# ── normalize_state: parse any supported JSON format ────────────
# Reads a single JSON file and outputs a normalized key=value block:
#   _N_DONE, _N_IN_PROG, _N_ABANDONED, _N_TOTAL, _N_TODO,
#   _N_IN_PROGRESS_ALL, _N_COMPLEXITY, _N_RETRO_INTERVAL, _N_NEXT_DUE
# Returns 0 on success, 1 on failure.
normalize_state() {
  local json_file="$1"

  # Count task statuses from JSON
  local done_count in_prog abandoned
  done_count=$(jq '[.tasks // {} | to_entries[] | select(.value.status == "DONE")] | length' "$json_file" 2>/dev/null || echo 0)
  in_prog=$(jq '[.tasks // {} | to_entries[] | select(.value.status == "IN_PROGRESS")] | length' "$json_file" 2>/dev/null || echo 0)
  abandoned=$(jq '[.tasks // {} | to_entries[] | select(.value.status == "ABANDONED")] | length' "$json_file" 2>/dev/null || echo 0)

  done_count=$(ensure_numeric "$done_count" 0)
  in_prog=$(ensure_numeric "$in_prog" 0)
  abandoned=$(ensure_numeric "$abandoned" 0)

  local total=$(( done_count + in_prog + abandoned ))
  local todo=$(( total - done_count ))
  [ "$todo" -lt 0 ] 2>/dev/null && todo=0

  # Extract IN_PROGRESS task IDs
  local in_progress_all=""
  if [ "$in_prog" -gt 0 ] 2>/dev/null; then
    in_progress_all=$(jq -r '[.tasks // {} | to_entries[] | select(.value.status == "IN_PROGRESS") | .key] | join(",")' "$json_file" 2>/dev/null || true)
  fi

  # Read metadata with fallback defaults
  local complexity="medium" retro_interval=10 next_due=5
  local cj ij nj
  cj=$(parse_json_field "complexity" "$json_file")
  [ -n "$cj" ] && complexity="$cj"
  ij=$(parse_json_field "interval" "$json_file")
  [ -n "$ij" ] && retro_interval=$(ensure_numeric "$ij" 10)
  nj=$(parse_json_field "next_due" "$json_file")
  [ -n "$nj" ] && next_due=$(ensure_numeric "$nj" 5)

  # Export normalized values
  _N_DONE=$done_count
  _N_IN_PROG=$in_prog
  _N_ABANDONED=$abandoned
  _N_TOTAL=$total
  _N_TODO=$todo
  _N_IN_PROGRESS_ALL="$in_progress_all"
  _N_COMPLEXITY="$complexity"
  _N_RETRO_INTERVAL=$retro_interval
  _N_NEXT_DUE=$next_due
}

# ── normalize_legacy: parse .tasks-state.json format ────────────
# Different schema: top-level { done, todo, abandoned, total, ... }
normalize_legacy() {
  local json_file="$1"

  local done_count todo_count abandoned total
  done_count=$(parse_json_field "done" "$json_file")
  todo_count=$(parse_json_field "todo" "$json_file")
  abandoned=$(parse_json_field "abandoned" "$json_file")
  total=$(parse_json_field "total" "$json_file")

  done_count=$(ensure_numeric "${done_count:-0}" 0)
  todo_count=$(ensure_numeric "${todo_count:-0}" 0)
  abandoned=$(ensure_numeric "${abandoned:-0}" 0)
  total=$(ensure_numeric "${total:-0}" 0)

  local complexity retro_interval retro_trigger in_progress_raw
  complexity=$(parse_json_field "complexity" "$json_file")
  complexity="${complexity:-medium}"
  retro_interval=$(parse_json_field "retro_interval" "$json_file")
  retro_interval=$(ensure_numeric "${retro_interval:-10}" 10)
  retro_trigger=$(parse_json_field "retro_trigger" "$json_file")
  case "$retro_trigger" in
    true|True|TRUE|1) retro_trigger="true" ;; *) retro_trigger="false" ;;
  esac

  in_progress_raw=$(parse_json_field "in_progress" "$json_file")
  local in_progress_all="" in_progress=""
  if [ -n "$in_progress_raw" ] && [ "$in_progress_raw" != "[]" ]; then
    in_progress_all=$(echo "$in_progress_raw" | sed 's/^\[//;s/\]$//' | tr -d '"' | tr -d ' ')
    in_progress=$(echo "$in_progress_all" | cut -d',' -f1)
  fi

  # Compute derived fields
  local in_prog_count=0
  [ -n "$in_progress_all" ] && in_prog_count=1
  local actual_total=$(( done_count + in_prog_count + abandoned ))
  local actual_todo=$(( actual_total - done_count ))
  [ "$actual_todo" -lt 0 ] 2>/dev/null && actual_todo=0

  local next_due=5
  local retro_trigger_final="false"
  if [ "$done_count" -ge "$next_due" ] 2>/dev/null; then
    local remainder=$(( (done_count - next_due) % retro_interval ))
    [ "$remainder" -eq 0 ] && retro_trigger_final="true"
  fi

  # Export normalized values
  _N_DONE=$done_count
  _N_IN_PROG=$in_prog_count
  _N_ABANDONED=$abandoned
  _N_TOTAL=$actual_total
  _N_TODO=$actual_todo
  _N_IN_PROGRESS_ALL="$in_progress_all"
  _N_COMPLEXITY="$complexity"
  _N_RETRO_INTERVAL=$retro_interval
  _N_NEXT_DUE=$next_due
}

# ── compute_output: build final key=value from normalized state ─
compute_output() {
  local feature_dir="$1"

  local in_progress="${_N_IN_PROGRESS_ALL:-}"
  [ -n "$in_progress" ] && in_progress=$(echo "$in_progress" | cut -d',' -f1)

  local has_todo="false"
  if [ "$_N_TODO" -gt 0 ] 2>/dev/null || [ -n "${_N_IN_PROGRESS_ALL:-}" ]; then
    has_todo="true"
  fi

  local retro_trigger="false"
  if [ "$_N_DONE" -ge "$_N_NEXT_DUE" ] 2>/dev/null; then
    local remainder=$(( (_N_DONE - _N_NEXT_DUE) % _N_RETRO_INTERVAL ))
    [ "$remainder" -eq 0 ] && retro_trigger="true"
  fi

  OUTPUT="has_todo=${has_todo}
done_count=${_N_DONE}
todo_count=${_N_TODO}
in_progress=${in_progress}
in_progress_all=${_N_IN_PROGRESS_ALL:-}
abandoned_count=${_N_ABANDONED}
total_tasks=${_N_TOTAL}
complexity=${_N_COMPLEXITY}
retro_interval=${_N_RETRO_INTERVAL}
first_retro_threshold=${_N_NEXT_DUE}
retro_trigger=${retro_trigger}
feature_dir=${feature_dir}
todo_task_id=
todo_task_type="
}

# ── Attempt 0: state.json (unified state engine) ────────────────
if [ -n "$FEATURE_DIR" ] && [ -f "$FEATURE_DIR/state.json" ]; then
  if jq -e 'has("version") and has("tasks")' "$FEATURE_DIR/state.json" >/dev/null 2>&1; then
    normalize_state "$FEATURE_DIR/state.json"

    # Stale state validation: cross-check against tasks.md
    _layer1_valid=true
    if [ -f "$FEATURE_DIR/tasks.md" ]; then
      _actual_done=$(grep -c "^Status: DONE$" "$FEATURE_DIR/tasks.md" 2>/dev/null || true)
      _diff=$((_N_DONE - _actual_done))
      [ "$_diff" -lt 0 ] && _diff=$((_diff * -1))
      [ "$_diff" -gt 1 ] && _layer1_valid=false
    fi

    if [ "$_layer1_valid" = true ]; then
      compute_output "$FEATURE_DIR"
    fi
  fi
fi

# ── Attempt 1: .workflow-state.json (structured checkpoint) ─────
if [ -z "$OUTPUT" ] && [ -n "$FEATURE_DIR" ] && [ -f "$FEATURE_DIR/.workflow-state.json" ]; then
  if grep -q '"status"' "$FEATURE_DIR/.workflow-state.json" 2>/dev/null; then
    normalize_state "$FEATURE_DIR/.workflow-state.json"

    # Stale state validation
    _layer1_valid=true
    if [ -f "$FEATURE_DIR/tasks.md" ]; then
      _actual_done=$(grep -c "^Status: DONE$" "$FEATURE_DIR/tasks.md" 2>/dev/null || true)
      _diff=$((_N_DONE - _actual_done))
      [ "$_diff" -lt 0 ] && _diff=$((_diff * -1))
      [ "$_diff" -gt 1 ] && _layer1_valid=false
    fi

    if [ "$_layer1_valid" = true ]; then
      compute_output "$FEATURE_DIR"
    fi
  fi
fi

# ── Attempt 2: .tasks-state.json (legacy JSON) ──────────────────
if [ -z "$OUTPUT" ] && [ -n "$FEATURE_DIR" ] && [ -f "$FEATURE_DIR/.tasks-state.json" ]; then
  if grep -q '"done"' "$FEATURE_DIR/.tasks-state.json" 2>/dev/null && \
     grep -q '"todo"' "$FEATURE_DIR/.tasks-state.json" 2>/dev/null && \
     grep -q '"total"' "$FEATURE_DIR/.tasks-state.json" 2>/dev/null; then
    normalize_legacy "$FEATURE_DIR/.tasks-state.json"
    compute_output "$FEATURE_DIR"
  fi
fi

# ── Attempt 3: Fall back to check-tasks.sh ──────────────────────
if [ -z "$OUTPUT" ]; then
  OUTPUT=$(bash scripts/check-tasks.sh 2>/dev/null) || true
fi

# ── Attempt 4: Error with safe defaults ─────────────────────────
if [ -z "$OUTPUT" ]; then
  TASKS_PARSE_ERROR=1
  echo "TASKS_PARSE_ERROR=1"
  {
    echo "ERROR: All task state parsing methods failed." >&2
    echo "  Attempted (in order):" >&2
    echo "    1. state.json (unified state engine) — $(if [ -f "$FEATURE_DIR/state.json" ]; then echo 'found, but missing required fields (version/tasks)'; else echo 'not found'; fi)" >&2
    echo "    2. .workflow-state.json (checkpoint) — $(if [ -f "$FEATURE_DIR/.workflow-state.json" ]; then echo 'found, but missing status field'; else echo 'not found'; fi)" >&2
    echo "    3. .tasks-state.json (legacy JSON) — $(if [ -f "$FEATURE_DIR/.tasks-state.json" ]; then echo 'found, but missing done/todo/total fields'; else echo 'not found'; fi)" >&2
    echo "    4. check-tasks.sh (direct parse) — $(if [ -f "scripts/check-tasks.sh" ]; then echo 'failed to parse tasks.md'; else echo 'script not found'; fi)" >&2
    echo "" >&2
    echo "  Possible causes:" >&2
    echo "    - tasks.md is missing, empty, or has malformed formatting" >&2
    echo "    - state.json was corrupted or is from an older format" >&2
    echo "    - FEATURE_DIR is not set correctly" >&2
    echo "" >&2
    echo "  Fix: Run 'bash scripts/check-tasks.sh' directly to diagnose." >&2
  } >&2
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
todo_task_id=
todo_task_type=
DEFAULTS
  exit 0
fi

# Adjust retro_interval based on risk_profile (from project-brief.md)
if [ -n "$FEATURE_DIR" ] && [ -f "${FEATURE_DIR}/project-brief.md" ]; then
  RISK_PROFILE=$(grep -A1 '^## Risk profile' "${FEATURE_DIR}/project-brief.md" 2>/dev/null | grep -oE '(low|medium|high|critical)' | head -1 || true)
  if [ "$RISK_PROFILE" = "high" ] || [ "$RISK_PROFILE" = "critical" ]; then
    OLD_INTERVAL=$(echo "$OUTPUT" | grep '^retro_interval=' | head -1 | cut -d= -f2)
    if [ -n "$OLD_INTERVAL" ] && [ "$OLD_INTERVAL" -gt 0 ] 2>/dev/null; then
      NEW_INTERVAL=$(( (OLD_INTERVAL + 1) / 2 ))
      OUTPUT=$(echo "$OUTPUT" | sed "s/^retro_interval=${OLD_INTERVAL}$/retro_interval=${NEW_INTERVAL}/")
    fi
  fi
  unset RISK_PROFILE
fi

echo "$OUTPUT"
exit 0
