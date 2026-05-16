#!/usr/bin/env bash
# Detects implementation stagnation: no tasks completed for N consecutive iterations.
# Delegates to state-engine.sh if state.json exists.
# Usage: check-stagnation.sh <feature_dir> <current_done> <total_tasks>
#        check-stagnation.sh --reset <feature_dir>
#        check-stagnation.sh --record-drift <feature_dir>
#        check-stagnation.sh --increment-continue <feature_dir>
# Outputs: STAGNANT=true|false, CONSECUTIVE_NO_PROGRESS=N, CONSECUTIVE_CONTINUES=N

set -euo pipefail

RESET_MODE=false
RECORD_DRIFT=false
INCREMENT_CONTINUE=false
if [ "${1:-}" = "--reset" ]; then
  RESET_MODE=true
  FEATURE_DIR="${2:?Usage: check-stagnation.sh --reset <feature_dir>}"
elif [ "${1:-}" = "--record-drift" ]; then
  RECORD_DRIFT=true
  FEATURE_DIR="${2:?Usage: check-stagnation.sh --record-drift <feature_dir>}"
elif [ "${1:-}" = "--increment-continue" ]; then
  INCREMENT_CONTINUE=true
  FEATURE_DIR="${2:?Usage: check-stagnation.sh --increment-continue <feature_dir>}"
else
  FEATURE_DIR="${1:?Usage: check-stagnation.sh <feature_dir> <current_done> <total_tasks> [task_type]}"
  CURRENT_DONE="${2:?}"
  TOTAL_TASKS="${3:?}"
  TASK_TYPE="${4:-}"
fi

# Source central config (provides compute_stagnation_threshold, compute_stagnation_threshold_by_type)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/revision-limits.sh"

# Use type-specific threshold if task type is provided
if [ -n "$TASK_TYPE" ]; then
  STAGNATION_THRESHOLD=$(compute_stagnation_threshold_by_type "$TASK_TYPE")
else
  STAGNATION_THRESHOLD=$(compute_stagnation_threshold "${TOTAL_TASKS:-10}")
fi

# ── State engine path ──
if [ -f "$FEATURE_DIR/state.json" ]; then
  if [ "$RESET_MODE" = true ]; then
    bash scripts/state-engine.sh write "$FEATURE_DIR" stagnation.consecutive_no_progress 0 >/dev/null
    bash scripts/state-engine.sh write "$FEATURE_DIR" stagnation.consecutive_continues 0 >/dev/null
    echo "STAGNANT=false"
    echo "CONSECUTIVE_NO_PROGRESS=0"
    exit 0
  fi
  if [ "$RECORD_DRIFT" = true ]; then
    bash scripts/state-engine.sh task-incr "$FEATURE_DIR" _stagnation drift_violations >/dev/null 2>&1 || true
    local_dv=$(bash scripts/state-engine.sh read "$FEATURE_DIR" stagnation.drift_violations 2>/dev/null || echo 0)
    echo "DRIFT_VIOLATION_COUNT=$local_dv"
    echo "STAGNANT=false"
    echo "CONSECUTIVE_NO_PROGRESS=0"
    exit 0
  fi
  if [ "$INCREMENT_CONTINUE" = true ]; then
    bash scripts/state-engine.sh task-incr "$FEATURE_DIR" _stagnation consecutive_continues >/dev/null 2>&1 || true
    local_cc=$(bash scripts/state-engine.sh read "$FEATURE_DIR" stagnation.consecutive_continues 2>/dev/null || echo 0)
    echo "CONSECUTIVE_CONTINUES=$local_cc"
    echo "STAGNANT=false"
    echo "CONSECUTIVE_NO_PROGRESS=0"
    exit 0
  fi
  # Main stagnation check
  local_prev=$(bash scripts/state-engine.sh read "$FEATURE_DIR" stagnation.last_done_count 2>/dev/null || echo "-1")
  case "$local_prev" in ''|*[!0-9-]*) local_prev=-1 ;; esac
  local_consec=$(bash scripts/state-engine.sh read "$FEATURE_DIR" stagnation.consecutive_no_progress 2>/dev/null || echo 0)
  case "$local_consec" in ''|*[!0-9]*) local_consec=0 ;; esac

  if [ "$CURRENT_DONE" -gt "$local_prev" ] || [ "$TOTAL_TASKS" -eq 0 ] || [ "$local_prev" -eq -1 ]; then
    echo "STAGNANT=false"
    bash scripts/state-engine.sh write "$FEATURE_DIR" stagnation.last_done_count "$CURRENT_DONE" >/dev/null
    bash scripts/state-engine.sh write "$FEATURE_DIR" stagnation.consecutive_no_progress 0 >/dev/null
  else
    local_new_consec=$((local_consec + 1))
    bash scripts/state-engine.sh write "$FEATURE_DIR" stagnation.consecutive_no_progress "$local_new_consec" >/dev/null
    bash scripts/state-engine.sh write "$FEATURE_DIR" stagnation.last_done_count "$CURRENT_DONE" >/dev/null
    if [ "$local_new_consec" -ge "$STAGNATION_THRESHOLD" ]; then
      if [ "$CURRENT_DONE" -eq "$local_prev" ] && [ "$local_prev" -ne -1 ]; then
        echo "REVISION_ONLY=true"
      else
        echo "REVISION_ONLY=false"
      fi
      echo "STAGNANT=true"
      echo "CONSECUTIVE_NO_PROGRESS=$local_new_consec"
    else
      echo "REVISION_ONLY=false"
      echo "STAGNANT=false"
      echo "CONSECUTIVE_NO_PROGRESS=$local_new_consec"
    fi
  fi
  local_cc=$(bash scripts/state-engine.sh read "$FEATURE_DIR" stagnation.consecutive_continues 2>/dev/null || echo 0)
  echo "CONSECUTIVE_CONTINUES=$local_cc"
  exit 0
fi

# ── Legacy flat-file path: cleaned up after migration ──
# After state.json migration, legacy files are backed up as .bak.
# This path handles pre-migration projects that haven't migrated yet.
# Once migrated, state.json takes over (see the block above).
LEGACY_STATE_FILE="$FEATURE_DIR/.stagnation_state"
LEGACY_CONSEC_FILE="$LEGACY_STATE_FILE.consec"
LEGACY_CONTINUE_FILE="$LEGACY_STATE_FILE.continue_count"
LEGACY_DRIFT_FILE="$LEGACY_STATE_FILE.drift_count"

if [ -f "$LEGACY_STATE_FILE" ] && [ ! -f "$FEATURE_DIR/state.json" ]; then
  mkdir -p "$FEATURE_DIR"

  if [ "$RESET_MODE" = true ]; then
    TMPFILE=$(mktemp)
    echo "0" > "$TMPFILE"
    echo "0" >> "$TMPFILE"
    mv "$TMPFILE" "$LEGACY_STATE_FILE"
    echo "0" > "$LEGACY_CONSEC_FILE"
    echo "0" > "$LEGACY_CONTINUE_FILE"
    echo "STAGNANT=false"
    echo "CONSECUTIVE_NO_PROGRESS=0"
    exit 0
  fi

  if [ "$RECORD_DRIFT" = true ]; then
    DRIFT_COUNT=$(cat "$LEGACY_DRIFT_FILE" 2>/dev/null || echo 0)
    case "$DRIFT_COUNT" in ''|*[!0-9]*) DRIFT_COUNT=0 ;; esac
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    echo "$DRIFT_COUNT" > "$LEGACY_DRIFT_FILE"
    echo "DRIFT_VIOLATION_COUNT=$DRIFT_COUNT"
    echo "STAGNANT=false"
    echo "CONSECUTIVE_NO_PROGRESS=0"
    exit 0
  fi

  if [ "$INCREMENT_CONTINUE" = true ]; then
    CURRENT_CONTINUES=$(cat "$LEGACY_CONTINUE_FILE" 2>/dev/null || echo 0)
    case "$CURRENT_CONTINUES" in ''|*[!0-9]*) CURRENT_CONTINUES=0 ;; esac
    echo "$((CURRENT_CONTINUES + 1))" > "$LEGACY_CONTINUE_FILE"
    echo "CONSECUTIVE_CONTINUES=$((CURRENT_CONTINUES + 1))"
    echo "STAGNANT=false"
    echo "CONSECUTIVE_NO_PROGRESS=0"
    exit 0
  fi

  PREV_DONE=$(cat "$LEGACY_STATE_FILE" 2>/dev/null || echo "-1")
  case "$PREV_DONE" in ''|*[!0-9-]*) PREV_DONE=-1 ;; esac
  CONSECUTIVE=$(cat "$LEGACY_CONSEC_FILE" 2>/dev/null || echo 0)
  case "$CONSECUTIVE" in ''|*[!0-9]*) CONSECUTIVE=0 ;; esac

  if [ "$CURRENT_DONE" -gt "$PREV_DONE" ]; then
    echo "STAGNANT=false"
    TMPFILE=$(mktemp)
    echo "$CURRENT_DONE" > "$TMPFILE"
    mv "$TMPFILE" "$LEGACY_STATE_FILE"
    echo "0" > "$LEGACY_CONSEC_FILE"
  elif [ "$TOTAL_TASKS" -eq 0 ] || [ "$PREV_DONE" -eq -1 ]; then
    echo "STAGNANT=false"
    TMPFILE=$(mktemp)
    echo "$CURRENT_DONE" > "$TMPFILE"
    mv "$TMPFILE" "$LEGACY_STATE_FILE"
    echo "0" > "$LEGACY_CONSEC_FILE"
  else
    NEW_CONSEC=$((CONSECUTIVE + 1))
    echo "$NEW_CONSEC" > "$LEGACY_CONSEC_FILE"
    TMPFILE=$(mktemp)
    echo "$CURRENT_DONE" > "$TMPFILE"
    mv "$TMPFILE" "$LEGACY_STATE_FILE"
    if [ "$NEW_CONSEC" -ge "$STAGNATION_THRESHOLD" ]; then
      if [ "$CURRENT_DONE" -eq "$PREV_DONE" ] && [ "$PREV_DONE" -ne -1 ]; then
        echo "REVISION_ONLY=true"
      else
        echo "REVISION_ONLY=false"
      fi
      echo "STAGNANT=true"
      echo "CONSECUTIVE_NO_PROGRESS=$NEW_CONSEC"
    else
      echo "REVISION_ONLY=false"
      echo "STAGNANT=false"
      echo "CONSECUTIVE_NO_PROGRESS=$NEW_CONSEC"
    fi
  fi

  CONSECUTIVE_CONTINUES=$(cat "$LEGACY_CONTINUE_FILE" 2>/dev/null || echo 0)
  case "$CONSECUTIVE_CONTINUES" in ''|*[!0-9]*) CONSECUTIVE_CONTINUES=0 ;; esac
  echo "CONSECUTIVE_CONTINUES=$CONSECUTIVE_CONTINUES"
  exit 0
fi

# If state.json exists but legacy files also exist (post-migration),
# clean up legacy files to prevent future dual-path confusion.
if [ -f "$FEATURE_DIR/state.json" ] && [ -f "$LEGACY_STATE_FILE" ]; then
  echo "CLEANUP: Legacy stagnation files found alongside state.json — removing." >&2
  rm -f "$LEGACY_STATE_FILE" "$LEGACY_CONSEC_FILE" "$LEGACY_CONTINUE_FILE" "$LEGACY_DRIFT_FILE" 2>/dev/null || true
fi
