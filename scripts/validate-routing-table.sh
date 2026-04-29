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

# Parse check IDs from checks: section (indented: "  A:" or "  BC:")
CHECK_IDS_TMP="$TMP_DIR/check_ids.txt"
awk '/^checks:/{found=1; next} found && /^[[:space:]]*[A-Z][A-Z]?:/{gsub(/:/,"",$1); gsub(/[[:space:]]/,"",$1); print $1; next} found && /^[a-z]/{found=0}' "$PRESET_FILE" > "$CHECK_IDS_TMP"
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

# Check 3: .mdc files exist for all check IDs (files use lowercase: check_a_arch.mdc)
for cid in "${CHECK_IDS[@]}"; do
  lc=$(echo "$cid" | tr '[:upper:]' '[:lower:]')
  found=false
  for f in "$CHECKS_DIR"/check_${lc}_*.mdc; do
    if [ -f "$f" ]; then
      found=true
      break
    fi
  done
  if [ "$found" = false ]; then
    echo "ERROR: No check_${lc}_*.mdc file found in $CHECKS_DIR"
    ERRORS=$((ERRORS + 1))
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
    awk '/^checks:/{found=1; next} found && /^[[:space:]]*[A-Z][A-Z]?:/{gsub(/:/,"",$1); gsub(/[[:space:]]/,"",$1); print $1; next} found && /^[a-z]/{found=0}' "$1" | sort -u
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

# --fix: regenerate routing section from auto-derived values
if [ "$FIX_MODE" = true ]; then
  # Find the line number of "routing:"
  ROUTING_LINE=$(grep -n '^routing:' "$PRESET_FILE" | head -1 | cut -d: -f1)
  # Find the last routing entry line (last line with '[' array after routing:)
  LAST_ENTRY_LINE=$(tail -n +"$ROUTING_LINE" "$PRESET_FILE" | grep -n '\[' | tail -1 | cut -d: -f1)
  if [ -z "$LAST_ENTRY_LINE" ]; then
    LAST_ENTRY_LINE=0
  fi
  LAST_ENTRY_ABS=$((ROUTING_LINE + LAST_ENTRY_LINE - 1))
  # Everything from LAST_ENTRY_ABS+1 to next top-level key is preserved (blank lines, comments)
  {
    head -n "$((ROUTING_LINE - 1))" "$PRESET_FILE"
    ./scripts/derive-routing.sh "$PRESET_FILE"
    tail -n +"$((LAST_ENTRY_ABS + 1))" "$PRESET_FILE"
  } > "$PRESET_FILE.tmp"
  mv "$PRESET_FILE.tmp" "$PRESET_FILE"
  echo "FIXED: routing section regenerated"
  exit 0
fi

if [ "$ERRORS" -eq 0 ]; then
  echo "OK: Routing table valid — ${#CHECK_IDS[@]} checks, ${#UNIQUE_ROUTING_IDS[@]} unique routing entries, all .mdc files present, 0 drift"
  exit 0
else
  echo "FAIL: $ERRORS issue(s) found"
  exit 1
fi
