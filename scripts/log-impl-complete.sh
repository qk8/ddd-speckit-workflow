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
fi
