#!/usr/bin/env bash
# Usage: gate-threshold.sh <gate_type> <current_revision>
# Returns whether to show the revision option, auto-revise, or auto-approve
# When threshold is exceeded: returns AUTO_REVISE=true (triggers retrospect)
# Instead of silently auto-approving.
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
  echo "AUTO_APPROVE=false"
  echo "AUTO_REVISE=true"
  echo "AUTO_REVISE_REASON=Exceeded revision threshold ($REVISIONS>=$THRESHOLD) — triggering retrospect to assess remaining tasks"
  echo "MESSAGE=Revision threshold exceeded. Retrospect will assess whether remaining tasks are worth pursuing."
else
  echo "AUTO_APPROVE=false"
  echo "AUTO_REVISE=false"
  echo "REMAINING=$((THRESHOLD - REVISIONS))"
fi
