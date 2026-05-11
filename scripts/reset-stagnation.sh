#!/usr/bin/env bash
# Resets stagnation state after troubleshooting.
# Delegates to state-engine.sh if state.json exists.
# Usage: reset-stagnation.sh <feature_dir>
set -euo pipefail

FEATURE_DIR="${1:?Usage: reset-stagnation.sh <feature_dir>}"

if [ -f "$FEATURE_DIR/state.json" ]; then
  bash scripts/state-engine.sh write "$FEATURE_DIR" stagnation.consecutive_no_progress 0 >/dev/null
  bash scripts/state-engine.sh write "$FEATURE_DIR" stagnation.consecutive_continues 0 >/dev/null
  echo "STAGNANT=false"
  echo "CONTEXT LOADED — resume from speckit.context"
  exit 0
fi

STATE_FILE="$FEATURE_DIR/.stagnation_state"
CONSEC_FILE="$STATE_FILE.consec"
TMPFILE=$(mktemp)
echo "0" > "$TMPFILE"
echo "0" >> "$TMPFILE"
mv "$TMPFILE" "$STATE_FILE"
echo "0" > "$CONSEC_FILE"
echo "STAGNANT=false"
echo "CONTEXT LOADED — resume from speckit.context"
