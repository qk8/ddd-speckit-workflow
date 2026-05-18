#!/usr/bin/env bash
set -euo pipefail
# Usage: gate-threshold.sh <gate_type> <current_revision>
# Returns whether to show the revision option, auto-revise, or auto-approve
# When threshold is exceeded: returns AUTO_REVISE=true (triggers retrospect)
# Instead of silently auto-approving.
# Thresholds sourced from ddd-clean-arch/workflow-config.json revision_thresholds.*

GATE_TYPE="${1:?}"
REVISIONS="${2:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/ddd-clean-arch/workflow-config.json"

# Default threshold (used when config is missing or key not found)
THRESHOLD=3

if [ -f "$CONFIG" ]; then
  CONFIG_VALUE=$(bash "$SCRIPT_DIR/workflow-config.sh" "revision_thresholds.$GATE_TYPE" 2>/dev/null || echo "")
  if [ -n "$CONFIG_VALUE" ]; then
    THRESHOLD="$CONFIG_VALUE"
  fi
fi

if [ "$REVISIONS" -ge "$THRESHOLD" ]; then
  echo "AUTO_APPROVE=false"
  echo "AUTO_REVISE=true"
  echo "AUTO_REVISE_REASON=Exceeded revision threshold ($REVISIONS>=$THRESHOLD) — triggering retrospect to assess remaining tasks"
  echo "MESSAGE=Revision threshold exceeded. Retrospect will assess whether remaining tasks are worth pursuing."
else
  echo "AUTO_APPROVE=false"
  echo "AUTO_REVISE=false"
  echo "REMAINING=$((THRESHOLD - REVISIONS))"
fi
