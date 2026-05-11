#!/usr/bin/env bash
# batch-executor.sh — DEPRECATED: delegates to dag-executor.sh
#
# Legacy interface: parallel batch execution with conflict detection.
# New code should use: dag-executor.sh <feature_dir> [--max-parallel N]
#
# This script wraps dag-executor.sh and handles:
#   - Legacy --batch-size flag → --max-parallel
#   - Legacy --single-task flag → sequential mode (not supported in v2)
#   - Legacy tasks.md → state.json migration check

set -euo pipefail

FEATURE_DIR="${1:?Usage: batch-executor.sh <feature_dir> [--batch-size N] [--single-task TASK-N]}"
shift

BATCH_SIZE=""
SINGLE_TASK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --single-task) SINGLE_TASK="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# If single-task mode, run sequentially (legacy compatibility)
if [ -n "$SINGLE_TASK" ]; then
  echo "WARNING: --single-task mode is deprecated. Use state-engine.sh task-set to mark tasks." >&2
  bash "$SCRIPT_DIR/dag-executor.sh" "$FEATURE_DIR" "$([ -n "$BATCH_SIZE" ] && echo --max-parallel "$BATCH_SIZE")"
  exit $?
fi

# Build args for dag-executor.sh
DAG_ARGS=""
[ -n "$BATCH_SIZE" ] && DAG_ARGS="$DAG_ARGS --max-parallel $BATCH_SIZE"

bash "$SCRIPT_DIR/dag-executor.sh" "$FEATURE_DIR" $DAG_ARGS
exit $?
