#!/usr/bin/env bash
# Usage: ./scripts/derive-routing.sh [preset.yml path]
# Auto-derives routing table from checks[].applies_to in preset.yml.
# Outputs YAML routing section.
# Useful for verifying the manual routing table is consistent with applies_to.
#
# This script does NOT modify preset.yml — it only prints the derived routing.

set -euo pipefail

COMPARE_MODE=false
if [ "${1:-}" = "--compare" ]; then
  COMPARE_MODE=true
  shift
fi

PRESET_FILE="${1:-ddd-clean-arch/preset.yml}"
bash scripts/require-file.sh "$PRESET_FILE" preset.yml

# The 8 task types in canonical order
TYPES=("backend-domain" "backend-infra" "backend-api" "shared" "integration" "frontend-data" "frontend-feature" "e2e")

# derive_checks_for_type <task_type> <preset_file>
# Prints check IDs that apply to the given task type.
derive_checks_for_type() {
  awk -v type="$1" '
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
  ' "$2"
}

# format_routing <preset_file> [output_file]
# Prints or writes the derived routing table.
# If output_file is given, writes to it; otherwise prints to stdout.
format_routing() {
  local outf="${2:-}"
  for t in "${TYPES[@]}"; do
    local result=""
    while IFS= read -r check_id; do
      if [ -z "$result" ]; then
        result="[$check_id"
      else
        result="$result, $check_id"
      fi
    done < <(derive_checks_for_type "$t" "$1")

    if [ -z "$result" ]; then
      result="[]"
    else
      result="$result]"
    fi
    if [ -n "$outf" ]; then
      printf "  %-17s %s\n" "$t:" "$result" >> "$outf"
    else
      printf "  %-17s %s\n" "$t:" "$result"
    fi
  done
}

# --compare mode: derive routing and compare against manual routing in preset.yml
if [ "$COMPARE_MODE" = true ]; then
  DERIVED_FILE=$(mktemp)
  trap "rm -f '$DERIVED_FILE'" EXIT

  : > "$DERIVED_FILE"
  format_routing "$PRESET_FILE" "$DERIVED_FILE"

  # Extract manual routing entries from preset.yml (only lines matching routing entries)
  MANUAL_FILE=$(mktemp)
  trap "rm -f '$DERIVED_FILE' '$MANUAL_FILE'" EXIT

  awk '/^routing:/{found=1; next} found && /^[a-z_]+:/{found=0} found && /^[[:space:]]+[a-z0-9-]+:.*\[/{print}' "$PRESET_FILE" > "$MANUAL_FILE"

  # Compare
  DIFF=$(diff -u "$MANUAL_FILE" "$DERIVED_FILE" 2>&1) || true
  if [ -z "$DIFF" ]; then
    echo "OK: Manual routing matches auto-derived values (0 drift)"
    exit 0
  else
    echo "DRIFT DETECTED: Manual routing diverges from auto-derived values."
    echo ""
    echo "$DIFF"
    echo ""
    echo "Run: scripts/derive-routing.sh > preset.yml.tmp && mv preset.yml.tmp preset.yml"
    exit 1
  fi
fi

echo "routing:"
format_routing "$PRESET_FILE"
