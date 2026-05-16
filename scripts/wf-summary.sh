#!/usr/bin/env bash
# wf-summary.sh — One-page implementation report.
#
# Reads state.json, checkpoints, and token logs to produce a summary:
# - Total iterations
# - Tasks completed / abandoned / in-progress
# - Fix-needed cycles
# - Estimated token cost
# - Check pass rates
# - Wall-clock duration
#
# Usage: scripts/wf-summary.sh <feature_dir>

set -euo pipefail

FEATURE_DIR="${1:?Usage: wf-summary.sh <feature_dir>}"
STATE_FILE="$FEATURE_DIR/state.json"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"

if [ ! -f "$STATE_FILE" ]; then
  echo "ERROR: state.json not found at $STATE_FILE" >&2
  exit 1
fi

# ── Task counts ───────────────────────────────────────────────────
TOTAL_TASKS=$(jq '.tasks | length' "$STATE_FILE" 2>/dev/null || echo 0)
DONE_TASKS=$(jq '[.tasks | to_entries[] | select(.value.status == "DONE")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
TODO_TASKS=$(jq '[.tasks | to_entries[] | select(.value.status == "TODO")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
IN_PROGRESS_TASKS=$(jq '[.tasks | to_entries[] | select(.value.status == "IN_PROGRESS")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
ABANDONED_TASKS=$(jq '[.tasks | to_entries[] | select(.value.status == "ABANDONED")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
BLOCKED_TASKS=$(jq '[.tasks | to_entries[] | select(.value.status == "BLOCKED")] | length' "$STATE_FILE" 2>/dev/null || echo 0)

# ── Iteration count ───────────────────────────────────────────────
ITERATION_COUNT=0
if [ -f "$ARTIFACTS_DIR/iteration-count" ]; then
  ITERATION_COUNT=$(cat "$ARTIFACTS_DIR/iteration-count" 2>/dev/null || echo 0)
fi
case "$ITERATION_COUNT" in ''|*[!0-9]*) ITERATION_COUNT=0 ;; esac

# ── Fix-needed cycles ────────────────────────────────────────────
FIX_CYCLES=$(jq '.fix_cycles // 0' "$STATE_FILE" 2>/dev/null || echo 0)
case "$FIX_CYCLES" in ''|*[!0-9]*) FIX_CYCLES=0 ;; esac

# ── Token cost ────────────────────────────────────────────────────
ESTIMATED_COST=$(jq -r '.token_budget.estimated_cost // "N/A"' "$STATE_FILE" 2>/dev/null || echo "N/A")
PROJECTED_COST=$(jq -r '.token_budget.projected_cost // "N/A"' "$STATE_FILE" 2>/dev/null || echo "N/A")
TOTAL_TOKENS=$(jq -r '(.token_budget.actual_input_tokens // 0) + (.token_budget.actual_output_tokens // 0)' "$STATE_FILE" 2>/dev/null || echo 0)

# ── Check pass rates ─────────────────────────────────────────────
TOTAL_CHECKS=0
PASS_CHECKS=0
FAIL_CHECKS=0
SKIP_CHECKS=0

if [ -d "$ARTIFACTS_DIR/check-results" ]; then
  for result_file in "$ARTIFACTS_DIR/check-results/"*.result; do
    [ -f "$result_file" ] || continue
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    first_line=$(head -1 "$result_file" 2>/dev/null || echo "SKIP")
    case "$first_line" in
      PASS*) PASS_CHECKS=$((PASS_CHECKS + 1)) ;;
      FAIL*) FAIL_CHECKS=$((FAIL_CHECKS + 1)) ;;
      *)     SKIP_CHECKS=$((SKIP_CHECKS + 1)) ;;
    esac
  done
fi

# ── Wall-clock duration ──────────────────────────────────────────
START_TIME=""
END_TIME=""
if [ -d "$ARTIFACTS_DIR/checkpoints" ]; then
  first_cp=$(ls -1 "$ARTIFACTS_DIR/checkpoints/" 2>/dev/null | sort | head -1 || true)
  last_cp=$(ls -1 "$ARTIFACTS_DIR/checkpoints/" 2>/dev/null | sort | tail -1 || true)

  if [ -n "$first_cp" ] && [ -f "$ARTIFACTS_DIR/checkpoints/$first_cp/state.json" ]; then
    START_TIME=$(jq -r '.metadata.created_at // empty' "$ARTIFACTS_DIR/checkpoints/$first_cp/state.json" 2>/dev/null || true)
  fi
  if [ -n "$last_cp" ] && [ -f "$ARTIFACTS_DIR/checkpoints/$last_cp/state.json" ]; then
    END_TIME=$(jq -r '.metadata.updated_at // empty' "$ARTIFACTS_DIR/checkpoints/$last_cp/state.json" 2>/dev/null || true)
  fi
fi

# ── Stagnation data ──────────────────────────────────────────────
STAG_CONSEC=$(jq '.stagnation.consecutive_no_progress // 0' "$STATE_FILE" 2>/dev/null || echo 0)
STAG_CONTINUES=$(jq '.stagnation.consecutive_continues // 0' "$STATE_FILE" 2>/dev/null || echo 0)
STAG_DRIFT=$(jq '.stagnation.drift_violations // 0' "$STATE_FILE" 2>/dev/null || echo 0)

# ── Token risk ───────────────────────────────────────────────────
TOKEN_RISK=$(jq -r '.token_budget.risk // "OK"' "$STATE_FILE" 2>/dev/null || echo "OK")

# ── Print summary ────────────────────────────────────────────────
echo "=============================================="
echo "  WORKFLOW IMPLEMENTATION SUMMARY"
echo "=============================================="
echo ""
echo "  Tasks:      $DONE_TASKS/$TOTAL_TASKS done, $TODO_TASKS TODO, $IN_PROGRESS_TASKS in-progress, $ABANDONED_TASKS abandoned, $BLOCKED_TASKS blocked"
echo "  Iterations: $ITERATION_COUNT"
echo "  Fix cycles: $FIX_CYCLES (max 3)"
echo ""
echo "  Tokens:     $TOTAL_TOKENS total"
echo "  Cost:       $ESTIMATED_COST (estimated) / $PROJECTED_COST (projected)"
echo "  Token risk: $TOKEN_RISK"
echo ""
echo "  Checks:     $PASS_CHECKS pass / $FAIL_CHECKS fail / $SKIP_CHECKS skip / $TOTAL_CHECKS total"
echo ""
echo "  Stagnation: $STAG_CONSEC consecutive no-progress, $STAG_CONTINUES force-continued, $STAG_DRIFT drift violations"
echo ""
if [ -n "$START_TIME" ]; then
  echo "  Started:    $START_TIME"
fi
if [ -n "$END_TIME" ]; then
  echo "  Updated:    $END_TIME"
fi
echo ""
if [ "$FAIL_CHECKS" -gt 0 ]; then
  echo "  WARNING: $FAIL_CHECKS failed checks detected. Review .artifacts/check-results/"
elif [ "$ABANDONED_TASKS" -gt 0 ]; then
  echo "  NOTICE: $ABANDONED_TASKS tasks abandoned. Review .artifacts/abandoned-tasks-summary.md"
else
  echo "  STATUS: No outstanding issues."
fi
echo ""
echo "=============================================="
