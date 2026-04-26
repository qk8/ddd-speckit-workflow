#!/usr/bin/env bash
# Usage: ./scripts/derive-routing.sh [preset.yml path]
# Auto-derives routing table from checks[].applies_to in preset.yml.
# Outputs YAML routing section.
# Useful for verifying the manual routing table is consistent with applies_to.
#
# This script does NOT modify preset.yml — it only prints the derived routing.

set -euo pipefail

PRESET_FILE="${1:-ddd-clean-arch/preset.yml}"
if [ ! -f "$PRESET_FILE" ]; then
  echo "ERROR: preset.yml not found at $PRESET_FILE"
  exit 1
fi

# The 7 task types in canonical order
TYPES=("backend-domain" "backend-infra" "backend-api" "shared" "frontend-data" "frontend-feature" "e2e")

echo "routing:"
for t in "${TYPES[@]}"; do
  # For each type, find all checks that apply to it
  result=""
  while IFS= read -r check_id; do
    if [ -z "$result" ]; then
      result="[$check_id"
    else
      result="$result, $check_id"
    fi
  done < <(awk -v type="$t" '
    /^  [A-Z]:/ { id = $1; gsub(/:/, "", id) }
    /applies_to:.*all/ { if (id != "") print id }
    /applies_to:.*\[.*\]/ {
      line = $0
      gsub(/.*\[/, "", line)
      gsub(/\].*/, "", line)
      n = split(line, a, ",")
      for (i = 1; i <= n; i++) {
        gsub(/ /, "", a[i])
        if (a[i] == type && id != "") { print id; break }
      }
    }
  ' "$PRESET_FILE")

  if [ -z "$result" ]; then
    result="[]"
  else
    result="$result]"
  fi

  # Pad to 17 chars for alignment
  printf "  %-17s %s\n" "$t:" "$result"
done
