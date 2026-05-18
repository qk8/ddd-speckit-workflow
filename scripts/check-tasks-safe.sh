#!/usr/bin/env bash
# Check task state via the unified state engine (state-engine.sh).
#
# Single source of truth: state.json managed by state-engine.sh.
# If state.json is stale (diverges from tasks.md), falls through to
# direct tasks.md parse via check-tasks.sh.
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
OUTPUT=""

# ── Helpers ──────────────────────────────────────────────────────

ensure_numeric() {
  local val="$1" default="$2"
  if [[ "$val" =~ ^[0-9]+$ ]]; then echo "$val"; else echo "$default"; fi
}

# ── Compute final key=value output from normalized variables ─────
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

# ── Attempt 0: state.json via state-engine.sh (single source of truth) ──
if [ -n "$FEATURE_DIR" ]; then
  # Ensure migration has run if state.json doesn't exist yet
  if [ ! -f "$FEATURE_DIR/state.json" ]; then
    bash scripts/state-engine.sh migrate "$FEATURE_DIR" 2>/dev/null || true
  fi

  if [ -f "$FEATURE_DIR/state.json" ]; then
    # Read tasks object from state.json (compact JSON for safe piping)
    TASKS_JSON=$(jq -c '.tasks // {}' "$FEATURE_DIR/state.json" 2>/dev/null) || true

    if [ -n "$TASKS_JSON" ]; then
      # Count task statuses from JSON
      _N_DONE=$(echo "$TASKS_JSON" | jq '[to_entries[] | select(.value.status == "DONE")] | length' 2>/dev/null || echo 0)
      _N_IN_PROG=$(echo "$TASKS_JSON" | jq '[to_entries[] | select(.value.status == "IN_PROGRESS")] | length' 2>/dev/null || echo 0)
      _N_ABANDONED=$(echo "$TASKS_JSON" | jq '[to_entries[] | select(.value.status == "ABANDONED")] | length' 2>/dev/null || echo 0)

      _N_DONE=$(ensure_numeric "$_N_DONE" 0)
      _N_IN_PROG=$(ensure_numeric "$_N_IN_PROG" 0)
      _N_ABANDONED=$(ensure_numeric "$_N_ABANDONED" 0)

      _N_TOTAL=$(( _N_DONE + _N_IN_PROG + _N_ABANDONED ))
      _N_TODO=$(( _N_TOTAL - _N_DONE ))
      [ "$_N_TODO" -lt 0 ] 2>/dev/null && _N_TODO=0

      # Extract IN_PROGRESS task IDs
      _N_IN_PROGRESS_ALL=$(echo "$TASKS_JSON" | jq -r '[to_entries[] | select(.value.status == "IN_PROGRESS") | .key] | join(",")' 2>/dev/null || true)

      # Read metadata from full state.json
      _N_COMPLEXITY=$(jq -r '.metadata.risk_profile // .metadata.complexity // "medium"' "$FEATURE_DIR/state.json" 2>/dev/null || echo "medium")
      _N_RETRO_INTERVAL=$(jq -r '.cadence.retro_interval // 10' "$FEATURE_DIR/state.json" 2>/dev/null || echo 10)
      _N_RETRO_INTERVAL=$(ensure_numeric "$_N_RETRO_INTERVAL" 10)
      _N_NEXT_DUE=$(jq -r '.cadence.first_retro_threshold // 5' "$FEATURE_DIR/state.json" 2>/dev/null || echo 5)
      _N_NEXT_DUE=$(ensure_numeric "$_N_NEXT_DUE" 5)

      # Stale state validation: cross-check against tasks.md
      _stale=false
      if [ -f "$FEATURE_DIR/tasks.md" ]; then
        _actual_done=$(grep -c "^Status: DONE$" "$FEATURE_DIR/tasks.md" 2>/dev/null || true)
        _diff=$(( _N_DONE - _actual_done ))
        [ "$_diff" -lt 0 ] && _diff=$(( _diff * -1 ))
        [ "$_diff" -gt 1 ] && _stale=true
      fi

      if [ "$_stale" = true ]; then
        # State.json is out of sync with tasks.md — use tasks.md directly
        OUTPUT=$(bash scripts/check-tasks.sh 2>/dev/null) || true
        OUTPUT="${OUTPUT}
state_source=stale_tasks_md"
      else
        compute_output "$FEATURE_DIR"
      fi
    fi
  fi
fi

# ── Attempt 1: Fall back to check-tasks.sh ──────────────────────
if [ -z "$OUTPUT" ]; then
  OUTPUT=$(bash scripts/check-tasks.sh 2>/dev/null) || true
fi

# ── Attempt 2: Error with safe defaults ─────────────────────────
if [ -z "$OUTPUT" ]; then
  TASKS_PARSE_ERROR=1
  echo "TASKS_PARSE_ERROR=1"
  {
    echo "ERROR: Task state parsing failed." >&2
    echo "  Attempted (in order):" >&2
    echo "    1. state.json (unified state engine) — $(if [ -f "$FEATURE_DIR/state.json" ]; then echo 'found, but unreadable'; else echo 'not found'; fi)" >&2
    echo "    2. check-tasks.sh (direct parse of tasks.md) — $(if [ -f "scripts/check-tasks.sh" ]; then echo 'failed to parse'; else echo 'script not found'; fi)" >&2
    echo "" >&2
    echo "  Possible causes:" >&2
    echo "    - tasks.md is missing, empty, or has malformed formatting" >&2
    echo "    - state.json was corrupted" >&2
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
