#!/usr/bin/env bash
# estimate-cost.sh — Estimate LLM calls and token cost for a project
#
# Usage: bash scripts/estimate-cost.sh <feature_dir>
#
# N2: Cost estimator script.
# Estimates LLM calls based on number of tasks, checks per task,
# review rounds, and average token count per phase.
#
# Output: stdout summary + .artifacts/cost-estimate.json

set -euo pipefail

FEATURE_DIR="${1:?Usage: estimate-cost.sh <feature_dir>}"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

TASKS_FILE="$FEATURE_DIR/tasks.md"
PLAN_FILE="$FEATURE_DIR/plan.md"
PRESET_FILE="$(cd "$(dirname "$0")/../ddd-clean-arch" && pwd)/preset.yml"

# ── Read project parameters ─────────────────────────────────────
TOTAL_TASKS=0
if [ -f "$TASKS_FILE" ]; then
  TOTAL_TASKS=$(grep -c "^## TASK-" "$TASKS_FILE" 2>/dev/null || echo "0")
fi

COMPLEXITY="medium"
if [ -f "project-brief.md" ]; then
  _C=$(awk '/^## Complexity/{found=1; next} found && /^[^ ]/{print tolower($1); exit}' project-brief.md 2>/dev/null || true)
  case "$_C" in
    simple|medium|complex) COMPLEXITY="$_C" ;;
  esac
fi

# ── Read cadence from preset.yml ────────────────────────────────
RETRO_INTERVAL=10
if [ -f "$PRESET_FILE" ]; then
  _RI=$(bash scripts/read-preset-cadence.sh "$COMPLEXITY" "$PRESET_FILE" 2>/dev/null || true)
  [ -n "$_RI" ] && RETRO_INTERVAL="$_RI"
fi

FIRST_RETRO=5
if [ -f "$PRESET_FILE" ]; then
  _FR=$(bash scripts/read-preset-cadence.sh first_retro_threshold "$PRESET_FILE" 2>/dev/null || true)
  [ -n "$_FR" ] && FIRST_RETRO="$_FR"
fi

# ── Cost model (LLM calls per phase) ────────────────────────────
# These are estimates based on typical Claude Code sessions.
# Adjust based on actual measurements.

# Phase 1: Clarify (bounded)
CLARIFY_CALLS=3        # 1 prompt + 1 gate prompt per round, max 3 rounds

# Phase 2: Spec
SPEC_CALLS=1           # speckit.specify
AUDIT_CALLS=3          # max 3 audit rounds
SPEC_TOTAL=$((1 + AUDIT_CALLS))

# Phase 3: Plan (3 batches)
PLAN_CALLS=3           # 3 plan batches
PLAN_REVIEW_CALLS=3    # max 3 review rounds
DESIGN_CALLS=3         # max 3 design review rounds

# Phase 4: Tasks
TASKS_CALLS=1          # speckit.tasks
TASKS_VALIDATE_CALLS=1 # validate-tasks

# Phase 5: Implement loop (per task)
# Per-task costs:
WRITE_TEST_CALLS=1     # speckit.write-test
IMPLEMENT_CALLS=1      # speckit.implement
VERIFY_CALLS=1         # speckit.implement-verify
GATE_CALLS=3           # 3 review gates (acceptance, checks, TDD)
# Periodic checks (every RETRO_INTERVAL tasks):
RETRO_CALLS=2          # speckit.retrospect + speckit.check
TRACE_CALLS=1          # traceability-check

# Average correction rounds per task (realistic: 20% of tasks need 1 correction)
CORRECTION_RATE=0.2
CORRECTION_CALLS=1     # 1 extra call per correction

# Total implement loop calls
IMPLEMENT_LOOP_CALLS=$(( TOTAL_TASKS * (WRITE_TEST_CALLS + IMPLEMENT_CALLS + VERIFY_CALLS + GATE_CALLS) ))
IMPLEMENT_CORRECTION_CALLS=$(( TOTAL_TASKS * CORRECTION_RATE * CORRECTION_CALLS ))
PERIODIC_ROUNDS=$(( (TOTAL_TASKS - FIRST_RETRO) / RETRO_INTERVAL ))
if [ "$PERIODIC_ROUNDS" -lt 0 ]; then PERIODIC_ROUNDS=0; fi
PERIODIC_CALLS=$(( PERIODIC_ROUNDS * (RETRO_CALLS + TRACE_CALLS) ))

# Phase 6: Code review
HARDENING_CALLS=1      # speckit.code-review (adversarial)
CODE_REVIEW_CALLS=3    # max 3 rounds
CODE_REVIEW_FIX_CALLS=2 # average fix tasks per round

# Phase 7: Final verify
FINAL_VERIFY_CALLS=1   # speckit.verify
FIX_NEEDED_CALLS=2     # max 2 rounds

# ── Total estimates ─────────────────────────────────────────────
TOTAL_CALLS=$((
  CLARIFY_CALLS +
  SPEC_TOTAL +
  PLAN_CALLS + PLAN_REVIEW_CALLS + DESIGN_CALLS +
  TASKS_CALLS + TASKS_VALIDATE_CALLS +
  IMPLEMENT_LOOP_CALLS + IMPLEMENT_CORRECTION_CALLS + PERIODIC_CALLS +
  HARDENING_CALLS + CODE_REVIEW_CALLS + (CODE_REVIEW_FIX_CALLS * 3) +
  FINAL_VERIFY_CALLS + FIX_NEEDED_CALLS
))

# ── Token estimates ─────────────────────────────────────────────
# Average tokens per call (rough estimates)
# Simple projects: smaller context, fewer tokens
# Complex projects: larger context, more tokens

case "$COMPLEXITY" in
  simple)
    AVG_TOKENS_PER_CALL=8000
    ;;
  medium)
    AVG_TOKENS_PER_CALL=15000
    ;;
  complex)
    AVG_TOKENS_PER_CALL=25000
    ;;
esac

TOTAL_TOKENS=$((TOTAL_CALLS * AVG_TOKENS_PER_CALL))

# ── Cost estimates (Claude API pricing as of 2025) ──────────────
# Sonnet: $3/1M input, $15/1M output
# Opus: $15/1M input, $75/1M output
# Using Sonnet as default assumption

INPUT_COST=$(echo "scale=4; $TOTAL_TOKENS * 3 / 1000000" | bc 2>/dev/null || echo "N/A")
OUTPUT_COST=$(echo "scale=4; $TOTAL_TOKENS * 15 / 1000000" | bc 2>/dev/null || echo "N/A")
TOTAL_COST=$(echo "scale=4; $INPUT_COST + $OUTPUT_COST" | bc 2>/dev/null || echo "N/A")

# ── Output summary ──────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  LLM Call & Cost Estimate"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Project complexity:    $COMPLEXITY"
echo "  Estimated tasks:       $TOTAL_TASKS"
echo ""
echo "  Phase breakdown:"
echo "    Clarify:             $CLARIFY_CALLS calls"
echo "    Spec:                $SPEC_TOTAL calls"
echo "    Plan:                $((PLAN_CALLS + PLAN_REVIEW_CALLS + DESIGN_CALLS)) calls"
echo "    Tasks:               $((TASKS_CALLS + TASKS_VALIDATE_CALLS)) calls"
echo "    Implement loop:      $((IMPLEMENT_LOOP_CALLS + IMPLEMENT_CORRECTION_CALLS + PERIODIC_CALLS)) calls"
echo "    Code review:         $((HARDENING_CALLS + CODE_REVIEW_CALLS + CODE_REVIEW_FIX_CALLS * 3)) calls"
echo "    Final verify:        $((FINAL_VERIFY_CALLS + FIX_NEEDED_CALLS)) calls"
echo ""
echo "  ─────────────────────────────────────────"
echo "  Total estimated calls: $TOTAL_CALLS"
echo "  Avg tokens/call:       ~$AVG_TOKENS_PER_CALL"
echo "  Total tokens:          ~$TOTAL_TOKENS"
echo ""
echo "  Estimated cost (Sonnet):"
echo "    Input:               \$$INPUT_COST"
echo "    Output:              \$$OUTPUT_COST"
echo "    Total:               \$$TOTAL_COST"
echo ""
echo "  ─────────────────────────────────────────"
echo "  Notes:"
echo "    - Correction rate: ${CORRECTION_RATE*100}% of tasks need 1 extra call"
echo "    - Periodic retro every $RETRO_INTERVAL tasks"
echo "    - First retro after $FIRST_RETRO tasks"
echo "    - Max 3 code review rounds, ~$CODE_REVIEW_FIX_CALLS fix tasks/round"
echo "    - Costs based on Claude API pricing (Sonnet: \$3/\$15 per 1M tokens)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Write JSON output ───────────────────────────────────────────
cat > "$ARTIFACTS_DIR/cost-estimate.json" <<EOF
{
  "complexity": "${COMPLEXITY}",
  "total_tasks": ${TOTAL_TASKS},
  "calls": {
    "clarify": ${CLARIFY_CALLS},
    "spec": ${SPEC_TOTAL},
    "plan": $((PLAN_CALLS + PLAN_REVIEW_CALLS + DESIGN_CALLS)),
    "tasks": $((TASKS_CALLS + TASKS_VALIDATE_CALLS)),
    "implement_loop": $((IMPLEMENT_LOOP_CALLS + IMPLEMENT_CORRECTION_CALLS + PERIODIC_CALLS)),
    "code_review": $((HARDENING_CALLS + CODE_REVIEW_CALLS + CODE_REVIEW_FIX_CALLS * 3)),
    "final_verify": $((FINAL_VERIFY_CALLS + FIX_NEEDED_CALLS))
  },
  "total_calls": ${TOTAL_CALLS},
  "avg_tokens_per_call": ${AVG_TOKENS_PER_CALL},
  "total_tokens": ${TOTAL_TOKENS},
  "estimated_cost_usd": {
    "input": ${INPUT_COST},
    "output": ${OUTPUT_COST},
    "total": ${TOTAL_COST}
  }
}
EOF

echo "Cost estimate saved to $ARTIFACTS_DIR/cost-estimate.json"
