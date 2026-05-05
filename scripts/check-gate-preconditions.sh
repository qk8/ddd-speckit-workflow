#!/usr/bin/env bash
# Check deterministic check results and set gate blocking state.
# Usage: check-gate-preconditions.sh <feature_dir> <gate_name>
#
# Outputs:
#   GATE_BLOCKED=true|false
#   FAILING_CHECKS=<comma-separated check IDs>
#
# If GATE_BLOCKED=true, the review gate should NOT offer approve.

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-gate-preconditions.sh <feature_dir> <gate_name>}"
GATE_NAME="${2:-}"
RESULTS_DIR="$FEATURE_DIR/.artifacts/check-results"

FAILING=""
if [ -d "$RESULTS_DIR" ]; then
  for result_file in "$RESULTS_DIR"/*.result; do
    [ -f "$result_file" ] || continue
    result=$(head -1 "$result_file" 2>/dev/null || true)
    check_id=$(basename "$result_file" .result)
    if [ "$result" = "FAIL" ]; then
      if [ -n "$FAILING" ]; then
        FAILING="$FAILING,$check_id"
      else
        FAILING="$check_id"
      fi
    fi
  done
fi

if [ -n "$FAILING" ]; then
  echo "GATE_BLOCKED=true"
  echo "FAILING_CHECKS=$FAILING"
else
  echo "GATE_BLOCKED=false"
  echo "FAILING_CHECKS="
fi
