#!/usr/bin/env bash
# Records a phase revision with auto-generated label.
# Usage: record-phase-revision.sh <step_id> <iteration>
# Maps step_id to a human-readable label automatically.
set -euo pipefail

STEP_ID="${1:?Usage: record-phase-revision.sh <step_id> <iteration>}"
ITERATION="${2:?}"

case "$STEP_ID" in
  clarify_round)           LABEL="Clarification round" ;;
  audit_round)             LABEL="Adversarial audit revision round" ;;
  plan_review_revision)    LABEL="Plan review revision round" ;;
  design_review_round)     LABEL="Design review revision round" ;;
  tasks_phase)             LABEL="Tasks revision round" ;;
  validation_revision)     LABEL="Validation revision round" ;;
  code_review_round)       LABEL="Code review revision round" ;;
  *)                       LABEL="$STEP_ID revision round" ;;
esac

bash scripts/record-revision.sh "$STEP_ID" "$ITERATION" "$LABEL $ITERATION"
