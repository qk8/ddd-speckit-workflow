#!/usr/bin/env bash
# Periodic cleanup of stale artifacts to prevent context window exhaustion.
# Called at iteration boundaries when cleanup is triggered.
#
# Usage: cleanup-artifacts.sh <feature_dir> <iteration_number>
# Cleans up:
#   - Old prompt contexts (tasks with revision count > 1)

set -euo pipefail

FEATURE_DIR="${1:?}"
ITERATION="${2:?}"

# Only run cleanup at iteration 25 and 40
if [ "$ITERATION" -lt 25 ] && [ "$ITERATION" -ne 40 ]; then
  echo "CLEANUP_SKIPPED=true"
  exit 0
fi

CLEANED=0

# Clean old prompt contexts for tasks with revision count > 1
PROMPTS_DIR="$FEATURE_DIR/.artifacts/prompts"
if [ -d "$PROMPTS_DIR" ]; then
  if [ -f "$FEATURE_DIR/state.json" ]; then
    # Read revision counts from state.json
    for task_id in $(jq -r '.revisions.per_task // {} | keys[]' "$FEATURE_DIR/state.json" 2>/dev/null); do
      count=$(jq -r ".revisions.per_task.$task_id // 0" "$FEATURE_DIR/state.json" 2>/dev/null || echo 0)
      case "$count" in
        ''|*[!0-9]*) count=0 ;;
      esac
      if [ "$count" -gt 1 ] && [ -d "$PROMPTS_DIR/$task_id" ]; then
        rm -rf "$PROMPTS_DIR/$task_id"
        CLEANED=$((CLEANED + 1))
      fi
    done
  else
    # Legacy: read from .count files
    for count_file in "$FEATURE_DIR/.artifacts/task-revisions"/*.count; do
      [ -f "$count_file" ] || continue
      task_id=$(basename "$count_file" .count)
      count=$(cat "$count_file" 2>/dev/null || echo 0)
      case "$count" in
        ''|*[!0-9]*) count=0 ;;
      esac
      if [ "$count" -gt 1 ] && [ -d "$PROMPTS_DIR/$task_id" ]; then
        rm -rf "$PROMPTS_DIR/$task_id"
        CLEANED=$((CLEANED + 1))
      fi
    done
  fi
fi

echo "CLEANUP_COMPLETED=true"
echo "ARTIFACTS_CLEANED=$CLEANED"
