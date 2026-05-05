#!/usr/bin/env bash
# Post-verify checkpoint — writes lightweight JSON checkpoint after
# implement_verify, before review gates. Enables recovery if session
# crashes between verify and review-tdd.
#
# Usage: post-verify-checkpoint.sh <feature_dir>
#
# Writes: .artifacts/checkpoint.json

set -euo pipefail

FEATURE_DIR="${1:?Usage: post-verify-checkpoint.sh <feature_dir>}"
TASKS_FILE="$FEATURE_DIR/tasks.md"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"

mkdir -p "$ARTIFACTS_DIR"

# Read current task state
TASK_ID=""
DONE_COUNT=0
IN_PROGRESS=""

if [ -f "$TASKS_FILE" ]; then
  # Get first IN_PROGRESS task
  IN_PROGRESS=$(awk '/^## TASK/{header=$0} /^Status: IN_PROGRESS$/{gsub(/^## /,"",header); print header; exit}' "$TASKS_FILE" 2>/dev/null || true)
  IN_PROGRESS=$(echo "$IN_PROGRESS" | sed 's/^## //')

  # Count DONE tasks
  DONE_COUNT=$(grep -c "^Status: DONE" "$TASKS_FILE" 2>/dev/null || echo 0)
fi

# Write checkpoint
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

cat > "$ARTIFACTS_DIR/checkpoint.json" <<EOF
{
  "phase": "implement_loop",
  "checkpoint": "post_verify",
  "timestamp": "$TIMESTAMP",
  "task_id": "${IN_PROGRESS:-unknown}",
  "done_count": $DONE_COUNT,
  "in_progress_count": $([ -n "$IN_PROGRESS" ] && echo 1 || echo 0)
}
EOF

echo "Checkpoint written: $ARTIFACTS_DIR/checkpoint.json"
