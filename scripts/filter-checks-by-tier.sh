#!/usr/bin/env bash
# filter-checks-by-tier.sh — Filter checks by tier and task type
#
# Usage:  filter-checks-by-tier.sh <task_type> <tier>
#   task_type: module type from preset.yml (e.g. backend-domain, all)
#   tier:      critical | secondary | tertiary
#
# Output: comma-separated check IDs, e.g. "A,BC,D,I,L,Z"

PRESET_DIR="$(cd "$(dirname "$0")/../ddd-clean-arch" && pwd)"
PRESET_FILE="$PRESET_DIR/preset.yml"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <task_type> <tier>" >&2
  exit 1
fi

TASK_TYPE="$1"
TIER="$2"

if [[ ! -f "$PRESET_FILE" ]]; then
  echo "ERROR: preset.yml not found at $PRESET_FILE" >&2
  exit 1
fi

case "$TIER" in
  critical|secondary|tertiary) ;;
  *) echo "ERROR: tier must be critical, secondary, or tertiary" >&2; exit 1 ;;
esac

case "$TASK_TYPE" in
  all|backend-domain|backend-infra|backend-api|shared|integration|frontend-data|frontend-feature|e2e) ;;
  *) echo "ERROR: unknown task_type '$TASK_TYPE'" >&2; exit 1 ;;
esac

# For critical and secondary tiers, use routing tables directly.
# For tertiary, there is no routing table — return all tertiary checks.
if [[ "$TIER" == "tertiary" ]]; then
  # Return all tertiary checks (no per-module filtering for tertiary)
  awk '
    /^checks:/ { in_checks=1; next }
    in_checks && /^[a-zA-Z]/ { exit }
    in_checks && /^[[:space:]]{2}[A-Z0-9]+:/ { current=$1; gsub(/:/,"",current); next }
    in_checks && /tier:[[:space:]]*tertiary/ { printf "%s,", current }
    END { print "" }
  ' "$PRESET_FILE" | sed 's/,$//'
  exit 0
fi

# Use routing table (routing_critical or routing_secondary)
if [[ "$TIER" == "critical" ]]; then
  TABLE="routing_critical"
else
  TABLE="routing_secondary"
fi

# Extract the routing table section, find the task_type line, output checks
awk -v ttype="$TASK_TYPE" -v table="$TABLE" '
  $0 ~ ("^" table ":") { in_table=1; next }
  in_table && /^[a-zA-Z]/ { exit }
  in_table && $0 ~ "[[:space:]]*" ttype ":" {
    # Extract content between [ and ]
    s=$0
    sub(/.*\[/, "", s)
    sub(/\].*/, "", s)
    gsub(/[[:space:]]/, "", s)
    print s
  }
' "$PRESET_FILE"
