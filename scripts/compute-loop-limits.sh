#!/usr/bin/env bash
# compute-loop-limits.sh — Compute while-loop max_iterations
#
# Usage: scripts/compute-loop-limits.sh --floor N --multiplier M --total_tasks T
#
# Computes max_iterations = max(floor, total_tasks * multiplier)
# Outputs: LOOP_MAX_ITERATIONS=N
#
# Defaults: --floor 50 --multiplier 2 --total_tasks 0

set -euo pipefail

FLOOR=50
MULTIPLIER=2
TOTAL_TASKS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --floor) FLOOR="$2"; shift 2 ;;
    --multiplier) MULTIPLIER="$2"; shift 2 ;;
    --total_tasks) TOTAL_TASKS="$2"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

COMPUTED=$((TOTAL_TASKS * MULTIPLIER))
if [ "$COMPUTED" -gt "$FLOOR" ]; then
  LOOP_MAX_ITERATIONS="$COMPUTED"
else
  LOOP_MAX_ITERATIONS="$FLOOR"
fi

echo "LOOP_MAX_ITERATIONS=${LOOP_MAX_ITERATIONS}"
