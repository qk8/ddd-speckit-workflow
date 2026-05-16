#!/usr/bin/env bash
# check-escalation.sh — Track check failure history and escalate
#
# Usage: bash scripts/check-escalation.sh <feature_dir>
#
# Tracks consecutive failures per check ID in state.json at
# checks_failure_count.<check_id>.
# If a check fails 2+ consecutive times: outputs ESCALATION=REQUIRED
# If a check passes after failures: resets the counter
# Outputs ESCALATION=NONE when everything is stable
# Always exits 0 (advisory, enforced by gate)

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-escalation.sh <feature_dir>}"
RESULTS_DIR="$FEATURE_DIR/.artifacts/check-results"
STATE_FILE="$FEATURE_DIR/state.json"

# Initialize state if missing
if [ ! -f "$STATE_FILE" ]; then
  echo "ESCALATION=NONE — no state.json"
  exit 0
fi

# Read existing failure counts
declare -A FAILURE_COUNTS
while IFS='=' read -r key val; do
  [ -n "$key" ] && FAILURE_COUNTS["$key"]="$val"
done < <(jq -r '.checks_failure_count // {} | to_entries[] | "\(.key)=\(.value)"' "$STATE_FILE" 2>/dev/null || true)

ESCALATION="NONE"
FAILED_CHECKS=""

for result_file in "$RESULTS_DIR"/*.result; do
  [ -f "$result_file" ] || continue
  check_id=$(basename "$result_file" .result)
  result=$(head -1 "$result_file" 2>/dev/null || echo "UNKNOWN")

  current_count="${FAILURE_COUNTS[$check_id]:-0}"
  case "$current_count" in ''|*[!0-9]*) current_count=0 ;; esac

  if [ "$result" = "FAIL" ]; then
    new_count=$(( current_count + 1 ))
    # Write updated count
    jq --arg id "$check_id" --argjson count "$new_count" \
      '.checks_failure_count[$id] = $count' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "$STATE_FILE" || true
    FAILURE_COUNTS["$check_id"]="$new_count"

    if [ "$new_count" -ge 2 ]; then
      ESCALATION="REQUIRED"
      FAILED_CHECKS="${FAILED_CHECKS}${FAILED_CHECKS:+, }${check_id} (consecutive failures: $new_count)"
    fi
  else
    # Pass or other result — reset counter
    if [ "$current_count" -gt 0 ]; then
      jq --arg id "$check_id" \
        'del(.checks_failure_count[$id])' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "$STATE_FILE" || true
    fi
    FAILURE_COUNTS["$check_id"]=0
  fi
done

echo "ESCALATION=$ESCALATION"
if [ -n "$FAILED_CHECKS" ]; then
  echo "FAILED_CHECKS: $FAILED_CHECKS"
fi

exit 0
