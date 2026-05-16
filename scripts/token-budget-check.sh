#!/usr/bin/env bash
# token-budget-check.sh — Enforce LLM token budget against state.json
#
# Usage: bash scripts/token-budget-check.sh <feature_dir>
#
# Reads token_budget from state.json, computes usage ratio,
# and outputs BUDGET=OK|WARNING|CRITICAL.
#
# CRITICAL (ratio >= 0.9): requires human approval before continuing.
# WARNING  (ratio >= 0.8): logs warning, continues.
# OK       (ratio < 0.8):  no action needed.
#
# If estimated_total is 0 (never estimated), outputs BUDGET=UNKNOWN.
# If actual_used is 0 (never tracked), outputs BUDGET=ESTIMATED_ONLY.
#
# Output: stdout summary + .artifacts/token-budget-result.txt
# Exit code: 0 = OK/WARNING/UNKNOWN, 2 = CRITICAL (requires human gate)

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

# Read values from state.json
ESTIMATED=$(jq -r '.token_budget.estimated_total // 0' "$STATE_FILE" 2>/dev/null || echo 0)
ACTUAL=$(jq -r '.token_budget.actual_used // 0' "$STATE_FILE" 2>/dev/null || echo 0)
WARNING_THRESH=$(jq -r '.token_budget.warning_threshold // 0.8' "$STATE_FILE" 2>/dev/null || echo 0.8)
CRITICAL_THRESH=$(jq -r '.token_budget.critical_threshold // 0.9' "$STATE_FILE" 2>/dev/null || echo 0.9)

# Normalize thresholds to integer percentages for bash arithmetic
WARNING_PCT=$(echo "$WARNING_THRESH * 100" | bc 2>/dev/null | cut -d. -f1 || echo 80)
CRITICAL_PCT=$(echo "$CRITICAL_THRESH * 100" | bc 2>/dev/null | cut -d. -f1 || echo 90)

# Ensure numeric
case "$ESTIMATED" in ''|*[!0-9]*) ESTIMATED=0 ;; esac
case "$ACTUAL" in ''|*[!0-9]*) ACTUAL=0 ;; esac
case "$WARNING_PCT" in ''|*[!0-9]*) WARNING_PCT=80 ;; esac
case "$CRITICAL_PCT" in ''|*[!0-9]*) CRITICAL_PCT=90 ;; esac

# Compute ratio
if [ "$ESTIMATED" -eq 0 ]; then
  echo "BUDGET=UNKNOWN — estimated_total is 0 (run estimate-cost.sh first)"
  echo "BUDGET=UNKNOWN" > "$ARTIFACTS_DIR/token-budget-result.txt"
  exit 0
fi

if [ "$ACTUAL" -eq 0 ]; then
  RATIO_PCT=0
  STATUS="ESTIMATED_ONLY"
else
  RATIO_PCT=$(( ACTUAL * 100 / ESTIMATED ))
  STATUS="TRACKED"
fi

# Determine budget status
if [ "$RATIO_PCT" -ge "$CRITICAL_PCT" ]; then
  BUDGET_STATUS="CRITICAL"
elif [ "$RATIO_PCT" -ge "$WARNING_PCT" ]; then
  BUDGET_STATUS="WARNING"
else
  BUDGET_STATUS="OK"
fi

# Write result file
cat > "$ARTIFACTS_DIR/token-budget-result.txt" <<EOF
BUDGET=$BUDGET_STATUS
status=$STATUS
estimated_total=$ESTIMATED
actual_used=$ACTUAL
ratio_pct=$RATIO_PCT
warning_threshold=$WARNING_PCT
critical_threshold=$CRITICAL_PCT
EOF

# Output summary
echo "=== TOKEN BUDGET CHECK ==="
echo "  Estimated total:  $ESTIMATED tokens"
echo "  Actual used:      $ACTUAL tokens"
echo "  Usage:            $RATIO_PCT% (threshold: ${WARNING_PCT}% warning / ${CRITICAL_PCT}% critical)"
echo "  Status:           BUDGET=$BUDGET_STATUS"
echo "  Tracking mode:    $STATUS"

if [ "$BUDGET_STATUS" = "WARNING" ]; then
  echo "  WARNING: Approaching token budget limit."
  echo "  Consider: reducing context size, splitting large tasks, or increasing estimated budget."
elif [ "$BUDGET_STATUS" = "CRITICAL" ]; then
  echo "  CRITICAL: Token budget nearly exhausted ($RATIO_PCT% used)."
  echo "  Action required: human approval needed before continuing."
  echo "  Consider: context reset, splitting feature into smaller pieces."
fi

echo ""

case "$BUDGET_STATUS" in
  CRITICAL) exit 2 ;;
  *)        exit 0 ;;
esac
