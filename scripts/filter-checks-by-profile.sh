#!/usr/bin/env bash
# filter-checks-by-profile.sh — Filter checks based on project profile
#
# Usage: bash scripts/filter-checks-by-profile.sh <profile> <task_type>
#
# I1: Check profiles (minimal/standard/full).
# Returns space-separated check IDs that apply to the given profile and task type.
#
# Profiles:
#   minimal  — Core 6: A, BC, D, I, L, Z (arch tests, regression, linter, secrets, anti-hallucination, drift)
#   standard — Core 8: minimal + K (API contract), M (failure mode coverage)
#   full     — All 21 checks (A through AS)
#   all      — Same as full (alias)

set -euo pipefail

PROFILE="${1:?Usage: filter-checks-by-profile.sh <minimal|standard|full> <task_type>}"
TASK_TYPE="${2:?Usage: filter-checks-by-profile.sh <profile> <task_type>}"

# ── Define check sets per profile ───────────────────────────────
PROFILE_MINIMAL="A BC D I L Z"
PROFILE_STANDARD="A BC D I L Z K M"
PROFILE_FULL="A BC D E F G H I J K L M N O P Q R S T U Z AS"

case "$PROFILE" in
  minimal)  CHECK_SET="$PROFILE_MINIMAL" ;;
  standard) CHECK_SET="$PROFILE_STANDARD" ;;
  full|all) CHECK_SET="$PROFILE_FULL" ;;
  *)
    echo "ERROR: Unknown profile '$PROFILE'. Valid: minimal, standard, full, all" >&2
    exit 1
    ;;
esac

# ── Read preset.yml routing table ───────────────────────────────
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PRESET_FILE="$(cd "$SCRIPTS_DIR/../ddd-clean-arch" && pwd)/preset.yml"

# If preset.yml exists, filter CHECK_SET against the routing table for this task type
if [ -f "$PRESET_FILE" ]; then
  ROUTING=$(awk -v ttype="$TASK_TYPE" '
    /^routing_critical:/ { in_table=1; next }
    in_table && /^[a-zA-Z]/ { exit }
    in_table && $0 ~ "[[:space:]]*" ttype ":" {
      s=$0
      sub(/.*\[/, "", s)
      sub(/\].*/, "", s)
      gsub(/[[:space:]]/, "", s)
      print s
    }
  ' "$PRESET_FILE" 2>/dev/null || true)

  if [ -n "$ROUTING" ]; then
    # Convert comma-separated to space-separated
    ROUTING=$(echo "$ROUTING" | tr ',' ' ')

    # Filter CHECK_SET to only include checks in the routing table
    FILTERED=""
    for check in $CHECK_SET; do
      for route_check in $ROUTING; do
        if [ "$check" = "$route_check" ]; then
          if [ -n "$FILTERED" ]; then
            FILTERED="$FILTERED $check"
          else
            FILTERED="$check"
          fi
          break
        fi
      done
    done
    echo "$FILTERED"
  else
    # No routing table entry for this task type — return all checks in profile
    echo "$CHECK_SET"
  fi
else
  # No preset.yml — return all checks in profile
  echo "$CHECK_SET"
fi
