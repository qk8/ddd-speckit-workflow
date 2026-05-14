#!/usr/bin/env bash
# complexity-analyzer.sh — Analyze project risk profile from brief + plan
#
# Usage: scripts/complexity-analyzer.sh <feature_dir>
#
# Reads project-brief.md and generated plan.md to determine risk profile.
# Outputs: RISK_PROFILE=[low|medium|high|critical]
#
# Analysis dimensions:
#   - Bounded context count (from plan.md §3)
#   - Distributed transactions (from plan.md §4)
#   - External dependency count (from plan.md §8, §9)
#   - Data consistency requirements (from plan.md §12)
#   - Compliance indicators (from project-brief.md)

set -euo pipefail

FEATURE_DIR="${1:?Usage: scripts/complexity-analyzer.sh <feature_dir>}"

BRIEF="${FEATURE_DIR}/project-brief.md"
PLAN="${FEATURE_DIR}/plan.md"

# Default: low risk
RISK_PROFILE="low"

# Check project-brief.md for explicit risk_profile field
if [ -f "$BRIEF" ]; then
  explicit=$(grep -A1 '^## Risk profile' "$BRIEF" 2>/dev/null | grep -oE '(low|medium|high|critical)' | head -1 || true)
  if [ -n "$explicit" ]; then
    RISK_PROFILE="$explicit"
  fi
fi

# If plan.md exists, do structural analysis to potentially escalate risk
if [ -f "$PLAN" ]; then
  CONTEXT_COUNT=$(grep -c '^### §3' "$PLAN" 2>/dev/null || echo 0)
  EXT_DEPS=$(grep -cE '(External|upstream|downstream|third.party|external.service|external.api)' "$PLAN" 2>/dev/null || echo 0)
  HAS_DIST_TXN=$(grep -cE '(distributed.transaction|two.phase|SAGA|outbox.pattern|compensating.transaction)' "$PLAN" 2>/dev/null || echo 0)
  HAS_COMPLIANCE=$(grep -cE '(HIPAA|GDPR|SOC2|PCI.DSS|PII|PHI|financial.record)' "$PLAN" 2>/dev/null || echo 0)

  # Escalate if structural analysis indicates higher risk
  ESCALATED="no"

  if [ "$CONTEXT_COUNT" -ge 3 ] && [ "$HAS_DIST_TXN" -gt 0 ]; then
    ESCALATED="yes"
  fi

  if [ "$EXT_DEPS" -ge 5 ]; then
    ESCALATED="yes"
  fi

  if [ "$HAS_COMPLIANCE" -gt 0 ]; then
    ESCALATED="yes"
  fi

  if [ "$ESCALATED" = "yes" ]; then
    # Determine escalation level
    SCORE=$(( CONTEXT_COUNT + EXT_DEPS + HAS_DIST_TXN + HAS_COMPLIANCE ))

    if [ "$SCORE" -ge 6 ] || [ "$HAS_COMPLIANCE" -gt 0 ]; then
      RISK_PROFILE="critical"
    elif [ "$SCORE" -ge 4 ]; then
      RISK_PROFILE="high"
    elif [ "$RISK_PROFILE" = "low" ]; then
      RISK_PROFILE="medium"
    fi
  fi
fi

echo "RISK_PROFILE=${RISK_PROFILE}"
