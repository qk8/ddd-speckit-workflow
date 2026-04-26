#!/usr/bin/env bash
# Usage: ./scripts/validate-routing-table.sh [preset.yml path]
# Validates routing table consistency:
#   - All check IDs in routing: exist in checks: section
#   - All check IDs in checks: appear in at least one routing: entry
#   - commands/checks/check_[X]_[name].mdc files exist for all check IDs
# Exit 0 if valid, exit 1 if issues found.

set -euo pipefail

PRESET_FILE="${1:-ddd-clean-arch/preset.yml}"
if [ ! -f "$PRESET_FILE" ]; then
  echo "ERROR: preset.yml not found at $PRESET_FILE"
  exit 1
fi

PRESET_DIR=$(dirname "$PRESET_FILE")
CHECKS_DIR="$PRESET_DIR/commands/checks"
ERRORS=0

# Parse check IDs from checks: section (indented with 2 spaces: "  A:")
mapfile -t CHECK_IDS < <(awk '/^checks:/{found=1; next} found && /^[[:space:]]*[A-Z]:/{gsub(/:/,"",$1); gsub(/[[:space:]]/,"",$1); print $1; next} found && /^[a-z]/{found=0}' "$PRESET_FILE")

# Parse check IDs from routing: section (indented: "  backend-domain:    [A, B, ...]")
mapfile -t ROUTING_IDS < <(awk '/^routing:/{found=1; next} found && /^[a-z]/{found=0} found && /\[/{gsub(/.*\[/, ""); gsub(/\].*/, ""); gsub(/ /, ""); n=split($0, a, ","); for(i=1;i<=n;i++) print a[i]}' "$PRESET_FILE")

# Deduplicate routing IDs
mapfile -t UNIQUE_ROUTING_IDS < <(printf '%s\n' "${ROUTING_IDS[@]}" | sort -u)

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

if [ "$ERRORS" -eq 0 ]; then
  echo "OK: Routing table valid — ${#CHECK_IDS[@]} checks, ${#UNIQUE_ROUTING_IDS[@]} unique routing entries, all .mdc files present"
  exit 0
else
  echo "FAIL: $ERRORS issue(s) found"
  exit 1
fi
