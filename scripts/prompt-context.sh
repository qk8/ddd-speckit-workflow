#!/usr/bin/env bash
# prompt-context.sh — Find first TODO task and generate prompt context
#
# Usage: scripts/prompt-context.sh <feature_dir>
#
# Finds the first task in tasks.md, extracts its ID and type,
# then runs prompt-factory.sh to generate targeted context.
set -euo pipefail

FEATURE_DIR="${1:?Usage: prompt-context.sh <feature_dir>}"
TASKS_FILE="$FEATURE_DIR/tasks.md"

# Find first task heading
FIRST_TASK=$(awk '/## TASK-/{f=1; print; next} f && /^## /{exit} f' "$TASKS_FILE" | head -1)
TASK_ID=$(echo "$FIRST_TASK" | sed 's/## TASK-\[\{0,1\}\([0-9]*\)\]*/TASK-\1/')
TASK_TYPE=$(awk -v t="$FIRST_TASK" 'BEGIN{f=0} index($0,t){f=1;next} f&&/^## /{exit} f&&/Type:/{s=$0; sub(/.*Type: */,"",s); print s; exit}' "$TASKS_FILE")

# Include spec_version from state.json (for drift detection)
STATE_FILE="$FEATURE_DIR/state.json"
SPEC_VERSION="1"
if [ -f "$STATE_FILE" ]; then
  SV=$(jq -r '.spec.version // 1' "$STATE_FILE" 2>/dev/null || echo 1)
  SPEC_VERSION="$SV"
fi
echo "SPEC_VERSION: ${SPEC_VERSION}"

bash scripts/prompt-factory.sh "$FEATURE_DIR" "$TASK_ID" "$TASK_TYPE" 2>/dev/null || true
