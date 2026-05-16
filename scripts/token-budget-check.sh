#!/usr/bin/env bash
# token-budget-check.sh — Check actual LLM token budget from state.json
#
# Reads token_budget from state.json (populated by track-token-budget.sh),
# computes risk level, and outputs BUDGET=OK|WARNING|CRITICAL.
#
# Output: stdout summary + .artifacts/token-budget-result.txt
# Exit code: 0 = OK/WARNING, 2 = CRITICAL (requires human gate)

set -euo pipefail

FEATURE_DIR="${1:?Usage: token-budget-check.sh <feature_dir>}"
STATE_FILE="$FEATURE_DIR/state.json"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

if [ ! -f "$STATE_FILE" ]; then
  echo "BUDGET=UNKNOWN — no state.json found"
  echo "BUDGET=UNKNOWN" > "$ARTIFACTS_DIR/token-budget-result.txt"
  exit 0
fi

# Read actual token data from state.json
ACTUAL_INPUT=$(jq -r '.token_budget.actual_input_tokens // 0' "$STATE_FILE" 2>/dev/null || echo 0)
ACTUAL_OUTPUT=$(jq -r '.token_budget.actual_output_tokens // 0' "$STATE_FILE" 2>/dev/null || echo 0)
PROJECTED=$(jq -r '.token_budget.projected_total // 0' "$STATE_FILE" 2>/dev/null || echo 0)
RISK=$(jq -r '.token_budget.risk // "UNKNOWN"' "$STATE_FILE" 2>/dev/null || echo "UNKNOWN")
ESTIMATED_COST=$(jq -r '.token_budget.estimated_cost // "0.00"' "$STATE_FILE" 2>/dev/null || echo "0.00")
PROJECTED_COST=$(jq -r '.token_budget.projected_cost // "0.00"' "$STATE_FILE" 2>/dev/null || echo "0.00")
SESSIONS=$(jq -r '.token_budget.sessions_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)

TOTAL_USED=$((ACTUAL_INPUT + ACTUAL_OUTPUT))

case "$ACTUAL_INPUT" in ''|*[!0-9]*) ACTUAL_INPUT=0 ;; esac
case "$ACTUAL_OUTPUT" in ''|*[!0-9]*) ACTUAL_OUTPUT=0 ;; esac
case "$PROJECTED" in ''|*[!0-9]*) PROJECTED=0 ;; esac
case "$SESSIONS" in ''|*[!0-9]*) SESSIONS=0 ;; esac

# Determine budget status from tracked risk
BUDGET_STATUS="$RISK"

# Write result file
cat > "$ARTIFACTS_DIR/token-budget-result.txt" <<EOF
BUDGET=$BUDGET_STATUS
risk=$RISK
actual_input=$ACTUAL_INPUT
actual_output=$ACTUAL_OUTPUT
projected_total=$PROJECTED
estimated_cost=$ESTIMATED_COST
projected_cost=$PROJECTED_COST
sessions=$SESSIONS
EOF

# Output summary
echo "=== TOKEN BUDGET CHECK ==="
echo "  Sessions:         $SESSIONS"
echo "  Total used:       $TOTAL_USED tokens"
echo "  Projected total:  $PROJECTED tokens"
echo "  Estimated cost:   $ESTIMATED_COST"
echo "  Projected cost:   $PROJECTED_COST"
echo "  Status:           BUDGET=$BUDGET_STATUS"

if [ "$BUDGET_STATUS" = "WARNING" ]; then
  echo "  WARNING: Approaching token budget limit."
  echo "  Consider: reducing context size, splitting large tasks."
elif [ "$BUDGET_STATUS" = "CRITICAL" ]; then
  echo "  CRITICAL: Token budget nearly exhausted."
  echo "  Action required: human approval needed before continuing."
  echo "  Consider: context reset, splitting feature into smaller pieces."
fi

echo ""

case "$BUDGET_STATUS" in
  CRITICAL) exit 2 ;;
  *)        exit 0 ;;
esac
