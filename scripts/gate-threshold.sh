#!/usr/bin/env bash
# Usage: gate-threshold.sh <gate_type> <current_revision>
# Returns whether to show the revision option or auto-approve
GATE_TYPE="${1:?}"
REVISIONS="${2:?}"

case "$GATE_TYPE" in
  clarify)       THRESHOLD=2 ;;
  spec)          THRESHOLD=1 ;;
  plan)          THRESHOLD=2 ;;
  tasks)         THRESHOLD=3 ;;
  implement)     THRESHOLD=2 ;;
  design)        THRESHOLD=3 ;;
  code-review)   THRESHOLD=2 ;;
  *)             THRESHOLD=3 ;;
esac

if [ "$REVISIONS" -ge "$THRESHOLD" ]; then
  echo "AUTO_APPROVE=true"
  echo "MESSAGE=Exceeded revision threshold ($REVISIONS>=$THRESHOLD). Auto-approving."
else
  echo "AUTO_APPROVE=false"
  echo "REMAINING=$((THRESHOLD - REVISIONS))"
fi
