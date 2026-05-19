#!/usr/bin/env bash
# ── Abandon Guard ────────────────────────────────────────────────
# Prevents infinite abandon/retry loops by tracking abandon history.
# Detects tasks that have been reset from ABANDONED -> TODO and
# failed again, flagging them for forced deletion.
#
# Usage: abandon-guard.sh <feature_dir>
#
# Output: GUARD=SAFE|LOOP_RISK|REQUIRES_DELETION
#         ABANDONED_TASKS=N
#         ABANDON_HISTORY-1=...
# Exit codes: 0 = SAFE, 1 = LOOP_RISK (with --enforce) or REQUIRES_DELETION

set -euo pipefail

FEATURE_DIR="${1:?Usage: abandon-guard.sh <feature_dir}"
TASKS_FILE="$FEATURE_DIR/tasks.md"
STATE_FILE="$FEATURE_DIR/state.json"

# ── Count abandoned tasks ───────────────────────────────────────
ABANDONED_COUNT=0
ABANDONED_TASKS=""

if [ -f "$TASKS_FILE" ]; then
  while IFS= read line; do
    [ -z "$line" ] && continue
    ABANDONED_COUNT=$((ABANDONED_COUNT + 1))
    ABANDONED_TASKS="${ABANDONED_TASKS}${line};"
  done < <(grep -E 'Status: ABANDONED' "$TASKS_FILE" 2>/dev/null || true)
fi

if [ "$ABANDONED_COUNT" -eq 0 ]; then
  echo "GUARD=SAFE"
  echo "ABANDONED_TASKS=0"
  exit 0
fi

# ── Check abandon history for each abandoned task ───────────────
LOOP_RISK=false
REQUIRES_DELETION=false
ABANDON_HISTORY=""
HISTORY_IDX=0

# Extract abandoned task IDs
while IFS= read ab_line; do
  [ -z "$ab_line" ] && continue
  local_tid=$(echo "$ab_line" | sed 's/^[[:space:]]*Status: ABANDONED[[:space:]]*\(.*\)/\1/' | sed 's/^[[:space:]]*//' | awk '{print $1}' || true)

  # If we couldn't extract task ID, try to get it from the ## TASK-N header
  if [ -z "$local_tid" ]; then
    local_tid=$(awk -v marker="Status: ABANDONED" '
      /^## TASK-/ { tid = $0; sub(/^## /, "", tid) }
      $0 == marker { print tid; exit }
    ' "$TASKS_FILE" 2>/dev/null || true)
  fi

  [ -z "$local_tid" ] && continue

  # Check if this task was previously reset from ABANDONED -> TODO
  # by looking at tasks.md history (if status was changed back)
  local_abandon_count=0
  local_abandon_count=$(grep -c "Status: ABANDONED" "$TASKS_FILE" 2>/dev/null || echo 0)

  # Check state.json for abandon history
  local_state_abandon_count=0
  if [ -f "$STATE_FILE" ]; then
    local_state_abandon_count=$(jq -r "[.history[] | select(.event == \"abandon\" and .task == \"$local_tid\")] | length" "$STATE_FILE" 2>/dev/null || echo 0)
    case "$local_state_abandon_count" in ''|*[!0-9]*) local_state_abandon_count=0 ;; esac
  fi

  # Check revision history for abandon->TODO transitions
  local_revision_abandon_count=0
  if [ -f "$FEATURE_DIR/.artifacts/revision-history.json" ]; then
    local_revision_abandon_count=$(jq -r "[.[] | select(.event == \"abandon_reset\")] | length" "$FEATURE_DIR/.artifacts/revision-history.json" 2>/dev/null || echo 0)
    case "$local_revision_abandon_count" in ''|*[!0-9]*) local_revision_abandon_count=0 ;; esac
  fi

  local_total_abandons=$((local_state_abandon_count + local_revision_abandon_count))

  HISTORY_IDX=$((HISTORY_IDX + 1))
  ABANDON_HISTORY="${ABANDON_HISTORY}ABANDON_HISTORY-${HISTORY_IDX}=${local_tid}: state_abandons=${local_state_abandon_count}, revision_abandons=${local_revision_abandon_count}; "

  # LOOP_RISK: task has been abandoned and likely reset before
  if [ "$local_state_abandon_count" -ge 1 ] || [ "$local_revision_abandon_count" -ge 1 ]; then
    LOOP_RISK=true
  fi

  # REQUIRES_DELETION: task has been abandoned 2+ times total
  if [ "$local_total_abandons" -ge 2 ]; then
    REQUIRES_DELETION=true
  fi

  # Also check: if there are multiple ABANDONED entries for same task in tasks.md
  if [ "$local_abandon_count" -ge 2 ]; then
    REQUIRES_DELETION=true
  fi

done <<< "$(grep -B5 'Status: ABANDONED' "$TASKS_FILE" 2>/dev/null | grep '^## TASK-' || true)"

# ── Determine overall guard status ──────────────────────────────
if [ "$REQUIRES_DELETION" = true ]; then
  echo "GUARD=REQUIRES_DELETION"
elif [ "$LOOP_RISK" = true ]; then
  echo "GUARD=LOOP_RISK"
else
  echo "GUARD=SAFE"
fi

echo "ABANDONED_TASKS=${ABANDONED_COUNT}"
if [ -n "$ABANDON_HISTORY" ]; then
  echo "$ABANDON_HISTORY" | tr ';' '\n' | while IFS= read line; do
    [ -n "$line" ] && echo "$line"
  done
fi

# Exit non-zero on REQUIRES_DELETION (always), LOOP_RISK (with --enforce)
if [ "$REQUIRES_DELETION" = true ]; then
  exit 1
fi
if [ "$LOOP_RISK" = true ] && [ "${ABANDON_GUARD_ENFORCE:-false}" = "true" ]; then
  exit 1
fi

exit 0
