#!/usr/bin/env bash
# traceability-cadence.sh — Independent traceability check cadence
#
# Usage: scripts/traceability-cadence.sh <feature_dir>
#
# Checks if traceability counter has reached its interval.
# Fires independently of retro drift checks.
# Outputs: TRACEABILITY_DUE=true|false, TRACEABILITY_COUNTER=<n>

set -euo pipefail

FEATURE_DIR="${1:?Usage: scripts/traceability-cadence.sh <feature_dir>}"
STATE_FILE="${FEATURE_DIR}/state.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "TRACEABILITY_DUE=false"
  echo "TRACEABILITY_COUNTER=0"
  exit 0
fi

# Read cadence state
COUNTER=$(jq -r '.cadence.traceability_counter // 0' "$STATE_FILE" 2>/dev/null || echo 0)
INTERVAL=$(jq -r '.cadence.traceability_interval // 15' "$STATE_FILE" 2>/dev/null || echo 15)

if [ "$COUNTER" -ge "$INTERVAL" ]; then
  echo "TRACEABILITY_DUE=true"
  echo "TRACEABILITY_COUNTER=${COUNTER}"
else
  echo "TRACEABILITY_DUE=false"
  echo "TRACEABILITY_COUNTER=${COUNTER}"
fi
echo "TRACEABILITY_INTERVAL=${INTERVAL}"
