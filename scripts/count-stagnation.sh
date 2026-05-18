#!/usr/bin/env bash
set -euo pipefail
# Usage: count-stagnation.sh <feature_dir>
# Increments stagnation counter, returns total and whether to force abort
# Delegates to state-engine.sh if state.json exists.
# Force abort threshold sourced from ddd-clean-arch/workflow-config.json
FEATURE_DIR="${1:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/ddd-clean-arch/workflow-config.json"

# Default force abort threshold
FORCE_ABORT_THRESHOLD=3
if [ -f "$CONFIG" ]; then
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" stagnation.total_abort_force 2>/dev/null || echo "")
  [ -n "$val" ] && FORCE_ABORT_THRESHOLD="$val"
fi

# ── Fast path: state.json ──
if [ -f "$FEATURE_DIR/state.json" ]; then
  CURRENT=$(bash scripts/state-engine.sh read "$FEATURE_DIR" stagnation.total_abort_count 2>/dev/null || echo 0)
  case "$CURRENT" in ''|*[!0-9]*) CURRENT=0 ;; esac
  NEW_COUNT=$((CURRENT + 1))
  bash scripts/state-engine.sh write "$FEATURE_DIR" stagnation.total_abort_count "$NEW_COUNT" >/dev/null
  if [ "$NEW_COUNT" -ge "$FORCE_ABORT_THRESHOLD" ]; then
    echo "FORCE_ABORT=true"
  else
    echo "FORCE_ABORT=false"
  fi
  echo "TOTAL=$NEW_COUNT"
  exit 0
fi

# ── Legacy path ──
STATE_FILE="$FEATURE_DIR/.stagnation_total"
COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
NEW_COUNT=$((COUNT + 1))
echo "$NEW_COUNT" > "$STATE_FILE"
if [ "$NEW_COUNT" -ge "$FORCE_ABORT_THRESHOLD" ]; then
  echo "FORCE_ABORT=true"
else
  echo "FORCE_ABORT=false"
fi
echo "TOTAL=$NEW_COUNT"
