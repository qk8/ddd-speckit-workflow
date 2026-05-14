#!/usr/bin/env bash
# workflow-resume.sh — Check for saved pause state and resume from it
#
# Usage: scripts/workflow-resume.sh <feature_dir>
#
# Checks for saved pause state (from save-pause-state.sh).
# If pause state exists, restores task state from pause point.
# Outputs: RESUME_OK=true|false, RESUME_TASK=<task_id>

set -euo pipefail

FEATURE_DIR="${1:?Usage: scripts/workflow-resume.sh <feature_dir>}"

PAUSE_FILE="${FEATURE_DIR}/workflow_state.json"

# Check if pause state exists
if [ ! -f "$PAUSE_FILE" ]; then
  echo "RESUME_OK=false"
  echo "RESUME_TASK="
  echo "REASON=no-pause-state"
  exit 0
fi

# Check if state.json exists and has tasks
STATE_FILE="${FEATURE_DIR}/state.json"
if [ ! -f "$STATE_FILE" ]; then
  echo "RESUME_OK=false"
  echo "RESUME_TASK="
  echo "REASON=no-state-json"
  exit 0
fi

# Read pause state
PAUSE_STEP=$(jq -r '.step // ""' "$PAUSE_FILE" 2>/dev/null || echo "")

if [ -z "$PAUSE_STEP" ] || [ "$PAUSE_STEP" = "null" ]; then
  echo "RESUME_OK=false"
  echo "RESUME_TASK="
  echo "REASON=empty-pause-step"
  exit 0
fi

# Find the first IN_PROGRESS task and resume it
TASK_ID=$(jq -r '.tasks | to_entries[] | select(.value.status == "IN_PROGRESS") | .key' "$STATE_FILE" 2>/dev/null | head -1 || echo "")

if [ -z "$TASK_ID" ]; then
  echo "RESUME_OK=false"
  echo "RESUME_TASK="
  echo "REASON=no-in-progress-task"
  exit 0
fi

# Reset pause state
rm -f "$PAUSE_FILE"

echo "RESUME_OK=true"
echo "RESUME_TASK=${TASK_ID}"
echo "RESUME_STEP=${PAUSE_STEP}"
