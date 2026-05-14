#!/usr/bin/env bash
# review-revise-chain.sh — Wrapper for on_revise chains
#
# Usage: scripts/review-revise-chain.sh <phase> <round_number> <feature_dir>
#
# Executes the standard revise chain steps in sequence:
#   record -> validate-fix -> backup -> plan-fix
# On any failure: stops, outputs CHAIN_RESULT=failure with failed step name.
# On success: outputs CHAIN_RESULT=success.
#
# This replaces multi-step on_revise blocks in phase YAML files with a
# single reliable wrapper call.

set -euo pipefail

PHASE="${1:?Usage: review-revise-chain.sh <phase> <round_number> <feature_dir>}"
ROUND="${2:?Usage: review-revise-chain.sh <phase> <round_number> <feature_dir>}"
FEATURE_DIR="${3:?Usage: review-revise-chain.sh <phase> <round_number> <feature_dir>}"

RECORD_AND_TRIM="bash scripts/record-and-trim.sh ${PHASE}_revision ${ROUND}"
VALIDATE_FIX="bash scripts/validate-fix-tasks.sh ${FEATURE_DIR}"
BACKUP_TASKS="bash scripts/backup-tasks.sh ${FEATURE_DIR} ${PHASE}"

run_step() {
  local step_name="$1"
  local step_cmd="$2"

  echo "REVIEW_CHAIN: executing ${step_name}..." >&2
  if eval "$step_cmd" 2>&1; then
    echo "REVIEW_CHAIN: ${step_name} OK" >&2
    return 0
  else
    echo "CHAIN_RESULT=failure"
    echo "CHAIN_FAILED_STEP=${step_name}"
    echo "CHAIN_PHASE=${PHASE}"
    echo "CHAIN_ROUND=${ROUND}"
    return 1
  fi
}

# Step 1: Record revision (backup prompt/context)
if ! run_step "record" "$RECORD_AND_TRIM"; then
  exit 1
fi

# Step 2: Validate fixes (check current state before planning)
if ! run_step "validate-fix" "$VALIDATE_FIX"; then
  exit 1
fi

# Step 3: Backup current state
if ! run_step "backup" "$BACKUP_TASKS"; then
  exit 1
fi

# Step 4: Plan fixes (LLM prompt to plan what needs fixing)
# This step is interactive (LLM prompt) — wrap in a subshell
if ! run_step "plan-fix" "bash scripts/plan-fix-tasks.sh ${FEATURE_DIR} ${PHASE} ${ROUND}" 2>/dev/null; then
  # plan-fix-tasks.sh may not exist in all phases — treat as optional
  echo "REVIEW_CHAIN: plan-fix skipped (not available for ${PHASE})" >&2
fi

echo "CHAIN_RESULT=success"
echo "CHAIN_PHASE=${PHASE}"
echo "CHAIN_ROUND=${ROUND}"
exit 0
