#!/usr/bin/env bash
# Logs milestone progress at iterations 25, 50, 75, 100.
# Usage: log-iteration-progress.sh <iteration> <done_count> <total_tasks> <todo_count> <in_progress>
set -euo pipefail

ITER="${1:?}"
DONE="${2:?}"
TOTAL="${3:?}"
TODO="${4:-none}"
IN_PROGRESS="${5:-none}"

case "$ITER" in
  25|50|75|100)
    echo "=== ITERATION $ITER/100 ==="
    echo "Done: $DONE/$TOTAL tasks"
    echo "Todo: $TODO"
    echo "In-progress: $IN_PROGRESS"
    ;;
esac
