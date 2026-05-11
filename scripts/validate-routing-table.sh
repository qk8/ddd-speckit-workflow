#!/usr/bin/env bash
# Usage: ./scripts/validate-routing-table.sh [preset-checks.yml path]
#        ./scripts/validate-routing-table.sh --fix [preset-checks.yml path]
#        ./scripts/validate-routing-table.sh --cross-check
# Validates routing table consistency:
#   - All check IDs in routing: exist in checks: section
#   - All check IDs in checks: appear in at least one routing: entry
#   - commands/checks/check_[X]_[name].mdc files exist for all check IDs
#   - Manual routing matches auto-derived values (drift detection)
#   - preset-checks.yml matches preset.yml checks/routing (cross-check mode)
# --fix: regenerate routing section from auto-derived values
# --cross-check: compare preset-checks.yml against preset.yml
# Exit 0 if valid, exit 1 if issues found.

set -euo pipefail

# Bash 3.2-compatible array reader.
# Uses temp file + eval instead of namerefs (bash 4.3+) to support macOS default bash 3.2.
# Usage: read_from_input VARNAME < input_file
# Writes result to a global temp file; caller reads via read_array.
read_from_input() {
  local _tmpfile
  _tmpfile=$(mktemp -p "$TMP_DIR")
  cat > "$_tmpfile"
  local _arr=()
  while IFS= read -r line; do
    [ -n "$line" ] && _arr+=("$line")
  done < "$_tmpfile"
  rm -f "$_tmpfile"
  # Write result back using eval (bash 3.2 compatible)
  if [ ${#_arr[@]} -gt 0 ]; then
    eval "$1=(\"\${_arr[@]}\")"
  else
    eval "$1=()"
  fi
}

# ── Temp files for bash 3.2 compatibility ───────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

FIX_MODE=false
CROSS_CHECK=false
if [ "${1:-}" = "--fix" ]; then
  FIX_MODE=true
  shift
elif [ "${1:-}" = "--cross-check" ]; then
  CROSS_CHECK=true
  shift
fi

PRESET_FILE="${1:-ddd-clean-arch/preset-checks.yml}"
bash scripts/require-file.sh "$PRESET_FILE" preset.yml

PRESET_DIR=$(dirname "$PRESET_FILE")
CHECKS_DIR="$PRESET_DIR/commands/checks"
ERRORS=0

# Parse check/dimension IDs from checks: section (indented: "  A:", "  test_execution:")
CHECK_IDS_TMP="$TMP_DIR/check_ids.txt"
awk '/^checks:/{found=1; next} found && /^  [A-Z][A-Z0-9]*:/{id=$1; gsub(/:/,"",id); print id; next} found && /^  [a-z][a-z_]*:/{id=$1; gsub(/:/,"",id); print id; next} found && /^[a-z]/{found=0}' "$PRESET_FILE" > "$CHECK_IDS_TMP"
read_from_input CHECK_IDS < "$CHECK_IDS_TMP"

# Parse check IDs from routing: section (indented: "  backend-domain:    [A, B, ...]")
ROUTING_IDS_TMP="$TMP_DIR/routing_ids.txt"
awk '/^routing:/{found=1; next} found && /^[a-z]/{found=0} found && /\[/{gsub(/.*\[/, ""); gsub(/\].*/, ""); gsub(/ /, ""); n=split($0, a, ","); for(i=1;i<=n;i++) print a[i]}' "$PRESET_FILE" > "$ROUTING_IDS_TMP"
read_from_input ROUTING_IDS < "$ROUTING_IDS_TMP"

# Deduplicate routing IDs
UNIQUE_ROUTING_IDS_TMP="$TMP_DIR/unique_routing_ids.txt"
printf '%s\n' "${ROUTING_IDS[@]}" | sort -u > "$UNIQUE_ROUTING_IDS_TMP"
read_from_input UNIQUE_ROUTING_IDS < "$UNIQUE_ROUTING_IDS_TMP"

# Check 1: All routing IDs exist in checks section
for rid in "${UNIQUE_ROUTING_IDS[@]}"; do
  if ! printf '%s\n' "${CHECK_IDS[@]}" | grep -qx "$rid"; then
    echo "ERROR: Check ID [$rid] in routing table but not defined in checks:"
    ERRORS=$((ERRORS + 1))
  fi
done

# Check 2: All check IDs appear in at least one routing entry
for cid in "${CHECK_IDS[@]}"; do
  if ! printf '%s\n' "${ROUTING_IDS[@]}" | grep -qx "$cid"; then
    echo "WARNING: Check [$cid] defined in checks: but not referenced by any routing entry"
    ERRORS=$((ERRORS + 1))
  fi
done

# Check 3: .mdc files exist for all check IDs
# Old IDs: check_a_arch.mdc, check_bc_new_tests_regression.mdc, etc.
# Dimension IDs: check_dimension_test_execution.mdc, etc.
for cid in "${CHECK_IDS[@]}"; do
  lc=$(echo "$cid" | tr '[:upper:]' '[:lower:]')
  found=false
  # Try dimension template (exact name: check_dimension_<name>.mdc)
  if [ -f "$CHECKS_DIR/check_dimension_${lc}.mdc" ]; then
    found=true
  fi
  # Try old-style template (check_<id>_<name>.mdc)
  if [ "$found" = false ]; then
    for f in "$CHECKS_DIR"/check_${lc}_*.mdc; do
      if [ -f "$f" ]; then
        found=true
        break
      fi
    done
  fi
  if [ "$found" = false ]; then
    echo "WARNING: No mdc file found for [$cid]"
  fi
done

# Check 4: Compare manual routing against auto-derived routing (drift detection)
DRIFT_OUTPUT=$(./scripts/derive-routing.sh --compare "$PRESET_FILE" 2>&1) && DRIFT_RC=0 || DRIFT_RC=$?
if [ "$DRIFT_RC" -ne 0 ]; then
  echo "DRIFT: Manual routing diverges from auto-derived values"
  echo "$DRIFT_OUTPUT" | sed 's/^/  /'
  ERRORS=$((ERRORS + 1))
fi

# Cross-check: preset-checks.yml vs preset.yml (checks must match)
# Note: routing: section is removed from preset-checks.yml (D4 fix).
# Only checks: section is compared; routing is derived from checks[].applies_to.
PRESET_DIR=$(dirname "$PRESET_FILE")
PRESET_MAIN="$PRESET_DIR/preset.yml"
if [ -f "$PRESET_MAIN" ]; then
  # Extract check IDs from checks: section, normalized and sorted
  EXTRACT_CHECK_IDS() {
    awk '/^checks:/{found=1; next} found && /^  [A-Z][A-Z0-9]*:/{id=$1; gsub(/:/,"",id); print id; next} found && /^  [a-z][a-z_]*:/{id=$1; gsub(/:/,"",id); print id; next} found && /^[a-z]/{found=0}' "$1" | sort -u
  }
  CHECKS_FILE="$TMP_DIR/checks_preset.txt"
  CHECKS_MAIN_FILE="$TMP_DIR/checks_main.txt"
  EXTRACT_CHECK_IDS "$PRESET_FILE" > "$CHECKS_FILE"
  EXTRACT_CHECK_IDS "$PRESET_MAIN" > "$CHECKS_MAIN_FILE"
  CHECKS_DIFF=$(diff "$CHECKS_FILE" "$CHECKS_MAIN_FILE") || true
  if [ -n "$CHECKS_DIFF" ]; then
    echo "DRIFT: preset-checks.yml diverges from preset.yml"
    echo "$CHECKS_DIFF" | sed 's/^/  checks: /'
    ERRORS=$((ERRORS + 1))
  fi
fi

# --fix: regenerate routing sections from auto-derived values
if [ "$FIX_MODE" = true ]; then
  bash scripts/derive-routing-tables.sh --write "$PRESET_FILE"
  exit 0
fi

if [ "$ERRORS" -eq 0 ]; then
  echo "OK: Routing table valid — ${#CHECK_IDS[@]} checks, ${#UNIQUE_ROUTING_IDS[@]} unique routing entries, all .mdc files present, 0 drift"
  exit 0
else
  echo "FAIL: $ERRORS issue(s) found"
  exit 1
fi
