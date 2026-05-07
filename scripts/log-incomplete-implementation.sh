#!/usr/bin/env bash
# Log incomplete implementation — called when implement_loop ends with
# TODO or ABANDONED tasks remaining (max_iterations exhausted).
#
# Usage: log-incomplete-implementation.sh <todo_count> <abandoned_count> <in_progress_list>
#
# Exit 1 to signal workflow failure.

set -euo pipefail

TODO_COUNT="${1:-0}"
ABANDONED_COUNT="${2:-0}"
IN_PROGRESS="${3:-none}"

echo "================================================================" >&2
echo "IMPLEMENTATION INCOMPLETE" >&2
echo "================================================================" >&2
echo "  TODO tasks remaining:    $TODO_COUNT" >&2
echo "  ABANDONED tasks:         $ABANDONED_COUNT" >&2
echo "  In-progress tasks:       $IN_PROGRESS" >&2
echo "================================================================" >&2
echo "" >&2
echo "The implement_loop exited with remaining work. Possible causes:" >&2
echo "  1. max_iterations (50) was reached before all tasks completed" >&2
echo "  2. Tasks were abandoned due to unresolvable check failures" >&2
echo "  3. Circular dependencies or stagnation prevented progress" >&2
echo "" >&2
echo "Review .artifacts/abandoned-tasks-summary.md for details on abandoned tasks." >&2
echo "Manually resolve remaining tasks or increase max_iterations." >&2
echo "================================================================" >&2

exit 1
