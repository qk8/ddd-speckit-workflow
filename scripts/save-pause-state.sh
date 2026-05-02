#!/usr/bin/env bash
# Saves workflow pause state for resume.
# Usage: save-pause-state.sh <feature_dir> <step_name>
set -euo pipefail

FEATURE_DIR="${1:?}"
STEP_NAME="${2:?}"

mkdir -p "$FEATURE_DIR"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "{\"step\": \"$STEP_NAME\", \"paused_at\": \"$TIMESTAMP\"}" \
  > "$FEATURE_DIR/workflow_state.json"
echo "Workflow paused at $STEP_NAME. Run 'bash scripts/resume-workflow.sh' to continue."
