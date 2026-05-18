#!/usr/bin/env bash
# Logs implementation complete summary.
# Usage: log-impl-complete.sh <done_count> <total_tasks> <abandoned_count>
set -euo pipefail

DONE="${1:?}"
TOTAL="${2:?}"
ABANDONED="${3:-0}"

echo "=== IMPLEMENTATION COMPLETE ==="
echo "Tasks: $DONE/$TOTAL done"
if [ "$ABANDONED" -gt 0 ]; then
  echo "WARNING: $ABANDONED task(s) ABANDONED"
  # Clean up abandoned task artifacts
  FEATURE_DIR="${FEATURE_DIR:-$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")}"
  if [ -n "$FEATURE_DIR" ] && [ -f "$FEATURE_DIR/tasks.md" ]; then
    bash scripts/recovery-engine.sh abandoned "$FEATURE_DIR" 2>/dev/null || true
  fi
fi
