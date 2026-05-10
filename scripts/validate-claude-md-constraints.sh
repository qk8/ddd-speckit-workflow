#!/usr/bin/env bash
# Validates that CLAUDE.md §16 "What NOT to do" has exactly 10 constraints.
# Each constraint must follow the form: "Never [action] because [consequence]."
#
# Usage: bash scripts/validate-claude-md-constraints.sh [path-to-claude-md]
# Exit codes: 0 = PASS, 1 = FAIL

set -euo pipefail

CLAUDE_MD="${1:-CLAUDE.md}"
if [ ! -f "$CLAUDE_MD" ]; then
  echo "CHECK [FAIL]: CLAUDE.md not found at $CLAUDE_MD"
  echo "DRIFT_READINESS=FAIL"
  exit 1
fi

# Count constraints matching "1. Never ... because ..." pattern
NEVER_COUNT=$(grep -ciP '^\s*[0-9]+\.\s+Never ' "$CLAUDE_MD" 2>/dev/null || echo 0)
BECAUSE_COUNT=$(grep -ci ' because ' "$CLAUDE_MD" 2>/dev/null || echo 0)

if [ "$NEVER_COUNT" -lt 10 ]; then
  echo "CHECK [FAIL]: CLAUDE.md §16 has $NEVER_COUNT constraints (expected 10)"
  echo "DRIFT_READINESS=FAIL"
  exit 1
fi
if [ "$BECAUSE_COUNT" -lt 8 ]; then
  echo "CHECK [WARN]: Few constraints include 'because' consequence clause — ensure each constraint explains the consequence"
fi
echo "CHECK [PASS]: CLAUDE.md §16 has $NEVER_COUNT constraints with consequence clauses"
echo "DRIFT_READINESS=PASS"
exit 0
