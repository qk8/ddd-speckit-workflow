#!/usr/bin/env bash
# derive-routing.sh — Auto-derive routing table from checks[].applies_to in preset.yml
#
# Usage: scripts/derive-routing.sh [preset.yml path] [--compare]
#
# Outputs YAML routing section with dimension IDs (v2 format).
# --compare mode: compares derived routing against manual routing in preset.yml.
#
# NEW (v2): Works with consolidated dimensions. Dimensions have sub_checks.
# The routing tables reference dimension IDs, not individual check IDs.

set -euo pipefail

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

COMPARE_MODE=false
PRESET_FILE=""

for arg in "$@"; do
  case "$arg" in
    --compare) COMPARE_MODE=true ;;
    *) PRESET_FILE="$arg" ;;
  esac
done

# Default preset file
if [ -z "$PRESET_FILE" ]; then
  PRESET_FILE="ddd-clean-arch/preset.yml"
fi

bash scripts/require-file.sh "$PRESET_FILE" preset.yml

# The 8 task types in canonical order
TYPES=("backend-domain" "backend-infra" "backend-api" "shared" "integration" "frontend-data" "frontend-feature" "e2e")

# derive_checks_for_type <task_type> <preset_file>
# Prints check/dimension IDs that apply to the given task type.
# NEW (v2): Handles both old check IDs and dimension IDs.
# Skips tertiary-tier checks (they are not in routing tables).
derive_checks_for_type() {
  awk -v type="$1" '
    # Match check/dimension ID lines (2-space indent, ID followed by colon)
    /^  [A-Z][A-Z0-9]*:/ { id = $1; gsub(/:/, "", id); tier = ""; next }
    /^  [a-z][a-z_]*:/ { id = $1; gsub(/:/, "", id); tier = ""; next }
    /tier:/ && id != "" {
      t = $0; gsub(/.*tier:[ ]*"?/, "", t); gsub(/".*/, "", t); tier = t; next
    }
    /applies_to:.*all/ {
      if (id != "" && tier != "tertiary") print id
      next
    }
    /applies_to:.*\[.*\]/ {
      line = $0
      gsub(/.*\[/, "", line)
      gsub(/\].*/, "", line)
      n = split(line, a, ",")
      for (i = 1; i <= n; i++) {
        gsub(/ /, "", a[i])
        if (a[i] == type && id != "" && tier != "tertiary") { print id; break }
      }
      next
    }
  ' "$2"
}

# format_routing <preset_file> [output_file]
format_routing() {
  local outf="${2:-}"
  for t in "${TYPES[@]}"; do
    local result=""
    local _derive_tmp="$TMP_DIR/derive_tmp.txt"
    derive_checks_for_type "$t" "$1" > "$_derive_tmp"
    while IFS= read -r check_id; do
      if [ -z "$result" ]; then
        result="[$check_id"
      else
        result="$result, $check_id"
      fi
    done < "$_derive_tmp"

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

# --compare mode
if [ "$COMPARE_MODE" = true ]; then
  DERIVED_FILE="$TMP_DIR/derived.txt"
  : > "$DERIVED_FILE"
  format_routing "$PRESET_FILE" "$DERIVED_FILE"

  MANUAL_FILE="$TMP_DIR/manual.txt"
  awk '/^routing:/{found=1; next} found && /^[a-z_]+:/{found=0} found && /^[[:space:]]+[a-z0-9-]+:.*\[/{print}' "$PRESET_FILE" > "$MANUAL_FILE"

  DIFF=$(diff -u "$MANUAL_FILE" "$DERIVED_FILE" 2>&1) || true
  if [ -z "$DIFF" ]; then
    echo "OK: Manual routing matches auto-derived values (0 drift)"
    exit 0
  else
    echo "DRIFT DETECTED: Manual routing diverges from auto-derived values."
    echo ""
    echo "$DIFF"
    echo ""
    echo "Run: scripts/derive-routing.sh --write $PRESET_FILE"
    exit 1
  fi
fi

echo "routing:"
format_routing "$PRESET_FILE"
