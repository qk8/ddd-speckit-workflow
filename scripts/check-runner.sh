#!/usr/bin/env bash
# check-runner.sh — DEPRECATED: delegates to check-runner-v2.sh
#
# Legacy interface: deterministic check execution engine.
# New code should use: check-runner-v2.sh <feature_dir> <task_type> [--tier critical|secondary]
#
# This script wraps check-runner-v2.sh and handles:
#   - Legacy check IDs → dimension aliases (resolved by v2)
#   - --batch mode: runs critical then secondary tiers sequentially
#   - --changed-only: passed through to individual check scripts

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-runner.sh <feature_dir> <task_type> [--batch] [--changed-only]}"
TASK_TYPE="${2:?Usage: check-runner.sh <feature_dir> <task_type> [--batch] [--changed-only]}"
BATCH_MODE=false
CHANGED_ONLY=false

# Parse optional flags
for arg in "$@"; do
  case "$arg" in
    --batch) BATCH_MODE=true ;;
    --changed-only) CHANGED_ONLY=true ;;
  esac
done

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$BATCH_MODE" = true ]; then
  # Run critical tier first, then secondary
  echo "=== Running critical checks ==="
  bash "$SCRIPTS_DIR/check-runner-v2.sh" "$FEATURE_DIR" "$TASK_TYPE" --tier critical "$([ "$CHANGED_ONLY" = true ] && echo --changed-only)" || exit 1
  echo ""
  echo "=== Running secondary checks ==="
  bash "$SCRIPTS_DIR/check-runner-v2.sh" "$FEATURE_DIR" "$TASK_TYPE" --tier secondary "$([ "$CHANGED_ONLY" = true ] && echo --changed-only)" || exit 1
else
  # Default: critical tier only
  bash "$SCRIPTS_DIR/check-runner-v2.sh" "$FEATURE_DIR" "$TASK_TYPE" --tier critical "$([ "$CHANGED_ONLY" = true ] && echo --changed-only)"
fi
