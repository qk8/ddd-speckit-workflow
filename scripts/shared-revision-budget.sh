#!/usr/bin/env bash
# shared-revision-budget.sh — Shared revision budget across retro-time checks.
#
# Retro-time checks (retrospect, drift detection, traceability) share a single
# revision budget. Once exhausted, no more retro-time revisions are allowed.
#
# Usage:
#   <feature_dir> check [--budget N]   — Check remaining budget
#   <feature_dir> consume [--budget N] — Decrement budget by 1
#   <feature_dir> reset [--budget N]   — Reset to default budget
#
# Stores state in state.json under key "revision_budget".
# Default budget: 5 revisions per implement loop cycle.

set -euo pipefail

FEATURE_DIR="${1:?Usage: shared-revision-budget.sh <feature_dir> <check> [--budget N]}"
CHECK="${2:?Usage: shared-revision-budget.sh <feature_dir> <check> [--budget N]}"
BUDGET="${3:-5}"

# Parse optional --budget flag
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --budget) BUDGET="${2:-5}"; shift 2 ;;
    *) shift ;;
  esac
done

STATE_FILE="$FEATURE_DIR/state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# Initialize state.json if it doesn't exist
if [ ! -f "$STATE_FILE" ]; then
  echo '{}' > "$STATE_FILE"
fi

get_remaining() {
  jq -r '.revision_budget.remaining // empty' "$STATE_FILE" 2>/dev/null || echo ""
}

set_remaining() {
  local val="$1"
  local TMP
  TMP=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --argjson v "$val" '.revision_budget.remaining = $v | .metadata.updated_at = (now | todate)' "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
}

case "$CHECK" in
  check)
    REMAINING=$(get_remaining)
    if [ -z "$REMAINING" ]; then
      # Initialize to default budget
      set_remaining "$BUDGET"
      REMAINING="$BUDGET"
    fi
    TOTAL_USED=$((BUDGET - REMAINING))
    if [ "$REMAINING" -le 0 ]; then
      echo "TOTAL_USED=$TOTAL_USED"
      echo "REMAINING=0"
      echo "BUDGET_EXCEEDED=true"
    else
      echo "TOTAL_USED=$TOTAL_USED"
      echo "REMAINING=$REMAINING"
      echo "BUDGET_EXCEEDED=false"
    fi
    ;;
  consume)
    REMAINING=$(get_remaining)
    if [ -z "$REMAINING" ]; then
      set_remaining "$BUDGET"
      REMAINING="$BUDGET"
    fi
    NEW_REMAINING=$((REMAINING - 1))
    set_remaining "$NEW_REMAINING"
    echo "NEW_REMAINING=$NEW_REMAINING"
    if [ "$NEW_REMAINING" -le 0 ]; then
      echo "BUDGET_EXCEEDED=true"
    else
      echo "BUDGET_EXCEEDED=false"
    fi
    ;;
  reset)
    set_remaining "$BUDGET"
    echo "REMAINING=$BUDGET"
    echo "BUDGET_EXCEEDED=false"
    ;;
  *)
    echo "ERROR: Unknown check '$CHECK'. Use: check, consume, reset" >&2
    exit 1
    ;;
esac
