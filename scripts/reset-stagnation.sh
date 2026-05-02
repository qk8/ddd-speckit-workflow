#!/usr/bin/env bash
# Resets stagnation state after troubleshooting.
# Usage: reset-stagnation.sh <feature_dir>
set -euo pipefail

FEATURE_DIR="${1:?Usage: reset-stagnation.sh <feature_dir>}"
STATE_FILE="$FEATURE_DIR/.stagnation_state"
CONSEC_FILE="$STATE_FILE.consec"

echo "STAGNANT=false" > "$STATE_FILE"
echo "0" > "$CONSEC_FILE"
echo "CONTEXT LOADED — resume from speckit.context"
