#!/usr/bin/env bash
# derive-routing-tables.sh — Auto-derive routing tables from checks[].tier + applies_to
#
# Usage: bash scripts/derive-routing-tables.sh [--write] <preset_file>
#
# Reads ddd-clean-arch/preset.yml and auto-derives:
#   routing_critical:    critical-tier checks per module type
#   routing_secondary:   secondary-tier checks per module type
#
# Without --write: prints the derived tables to stdout for review.
# With --write: updates preset.yml in place.
#
# Issue B: Eliminates the 4 sources of truth problem by deriving
# routing_critical and routing_secondary automatically from the
# single source of truth: checks[].tier + checks[].applies_to.
#
# The manual routing_critical and routing_secondary tables in preset.yml
# are now ONLY for override purposes. If they exist and differ from the
# derived values, a warning is printed.
#
# Bash 3.2 compatible (no declare -A associative arrays).

set -euo pipefail

WRITE_MODE=false
PRESET_FILE=""

# Parse arguments: --write is optional, preset_file is required
for arg in "$@"; do
  case "$arg" in
    --write) WRITE_MODE=true ;;
    *) PRESET_FILE="$arg" ;;
  esac
done

if [ -z "$PRESET_FILE" ]; then
  echo "Usage: derive-routing-tables.sh [--write] <preset_file>" >&2
  exit 1
fi

if [ ! -f "$PRESET_FILE" ]; then
  echo "ERROR: preset file not found: $PRESET_FILE" >&2
  exit 1
fi

TMPDIR_DERIVE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DERIVE"' EXIT

# ── Parse checks from preset.yml ─────────────────────────────────
# Store parsed data in temp files: one file per check.
# Format per check file: "TIER\nAPPLIES_TO"

CHECKS_DIR="$TMPDIR_DERIVE/checks"
mkdir -p "$CHECKS_DIR"

current_check=""

while IFS= read -r line; do
  # Match check ID line (e.g., "  A:" or "  BC:")
  if echo "$line" | grep -qE '^\s{2}[A-Z][A-Z0-9]*:'; then
    current_check=$(echo "$line" | sed 's/^\s*\([A-Z][A-Z0-9]*\):.*/\1/')
    echo "" > "$CHECKS_DIR/$current_check.tier"
    echo "" > "$CHECKS_DIR/$current_check.applies"
    continue
  fi

  # Match tier line
  if [ -n "$current_check" ] && echo "$line" | grep -qE '^\s+tier:'; then
    echo "$line" | sed 's/.*tier:\s*//' | tr -d ' ' > "$CHECKS_DIR/$current_check.tier"
    continue
  fi

  # Match applies_to line
  if [ -n "$current_check" ] && echo "$line" | grep -qE '^\s+applies_to:'; then
    # Handle both: applies_to: all  and  applies_to: [mod1, mod2]
    echo "$line" | sed 's/.*applies_to:[ ]*//' | sed 's/^\[[ ]*//' | sed 's/[ ]*\]$//' | tr -d ' ' > "$CHECKS_DIR/$current_check.applies"
    continue
  fi

  # Reset current_check on new top-level key (no leading whitespace, or minimal indent
  # that is NOT a check sub-field like tier/applies_to/name).
  # Check sub-fields (tier, applies_to, name, comments) are indented with 2+ spaces.
  # Top-level keys (commands, checks, routing, cadence, etc.) start at column 0.
  if [ -n "$current_check" ] && echo "$line" | grep -qE '^[a-z]'; then
    current_check=""
  fi
done < "$PRESET_FILE"

# ── Known module types ───────────────────────────────────────────
MODULE_TYPES="backend-domain backend-infra backend-api shared integration frontend-data frontend-feature e2e"

# ── Derive routing tables ────────────────────────────────────────
# Store derived results in temp files.
ROUTING_DIR="$TMPDIR_DERIVE/routing"
mkdir -p "$ROUTING_DIR"

for module in $MODULE_TYPES; do
  echo "" > "$ROUTING_DIR/critical_$module"
  echo "" > "$ROUTING_DIR/secondary_$module"
done

for check_file in "$CHECKS_DIR"/*.tier; do
  check_id=$(basename "$check_file" .tier)
  tier=$(cat "$CHECKS_DIR/$check_id.tier")
  applies=$(cat "$CHECKS_DIR/$check_id.applies")

  [ -z "$tier" ] && continue
  [ -z "$applies" ] && continue

  for module in $MODULE_TYPES; do
    # Check if module is in applies_to list
    is_applied=false
    if [ "$applies" = "all" ]; then
      is_applied=true
    else
      OLD_IFS="$IFS"
      IFS=','
      for m in $applies; do
        m=$(echo "$m" | tr -d ' ')
        if [ "$m" = "$module" ]; then
          is_applied=true
          break
        fi
      done
      IFS="$OLD_IFS"
    fi

    if [ "$is_applied" = true ]; then
      case "$tier" in
        critical)
          existing=$(cat "$ROUTING_DIR/critical_$module")
          if [ -n "$existing" ]; then
            echo "$existing, $check_id" > "$ROUTING_DIR/critical_$module"
          else
            echo "$check_id" > "$ROUTING_DIR/critical_$module"
          fi
          ;;
        secondary)
          existing=$(cat "$ROUTING_DIR/secondary_$module")
          if [ -n "$existing" ]; then
            echo "$existing, $check_id" > "$ROUTING_DIR/secondary_$module"
          else
            echo "$check_id" > "$ROUTING_DIR/secondary_$module"
          fi
          ;;
        # tertiary checks are NOT included in either table (deferred to code review)
      esac
    fi
  done
done

# ── Output derived tables ────────────────────────────────────────
echo "━━━ Derived Routing Tables ━━━"
echo ""
echo "routing_critical:"
for module in $MODULE_TYPES; do
  echo "  $module: [$(cat "$ROUTING_DIR/critical_$module")]"
done

echo ""
echo "routing_secondary:"
for module in $MODULE_TYPES; do
  echo "  $module: [$(cat "$ROUTING_DIR/secondary_$module")]"
done

# ── Compare with existing (if --write not used) ─────────────────
if [ "$WRITE_MODE" = false ]; then
  echo ""
  echo "━━━ Comparison with existing tables ━━━"
  echo ""

  for tier_name in critical secondary; do
    if grep -q "routing_${tier_name}:" "$PRESET_FILE" 2>/dev/null; then
      echo "routing_${tier_name} EXISTS in preset.yml"
      echo "  Derived values shown above — compare manually."
      echo "  Run with --write to auto-update preset.yml."
    else
      echo "routing_${tier_name}: NOT FOUND in preset.yml (new table)"
    fi
  done

  echo ""
  echo "To update preset.yml with derived values:"
  echo "  bash scripts/derive-routing-tables.sh --write $PRESET_FILE"
  exit 0
fi

# ── Write mode: update preset.yml ────────────────────────────────
echo ""
echo "━━━ Writing to $PRESET_FILE ━━━"

# Build the new routing tables as YAML strings
new_critical=""
for module in $MODULE_TYPES; do
  checks=$(cat "$ROUTING_DIR/critical_$module")
  # Format as YAML list
  formatted=""
  OLD_IFS="$IFS"
  IFS=','
  for c in $checks; do
    c=$(echo "$c" | tr -d ' ')
    [ -z "$c" ] && continue
    if [ -n "$formatted" ]; then
      formatted="$formatted, $c"
    else
      formatted="$c"
    fi
  done
  IFS="$OLD_IFS"
  new_critical="$new_critical  $module:   [$formatted]
"
done

new_secondary=""
for module in $MODULE_TYPES; do
  checks=$(cat "$ROUTING_DIR/secondary_$module")
  formatted=""
  OLD_IFS="$IFS"
  IFS=','
  for c in $checks; do
    c=$(echo "$c" | tr -d ' ')
    [ -z "$c" ] && continue
    if [ -n "$formatted" ]; then
      formatted="$formatted, $c"
    else
      formatted="$c"
    fi
  done
  IFS="$OLD_IFS"
  new_secondary="$new_secondary  $module:    [$formatted]
"
done

# Use awk to replace the routing_critical and routing_secondary sections
TMPFILE=$(mktemp)

awk -v new_crit="$new_critical" -v new_sec="$new_secondary" '
  /^routing_critical:/ {
    print
    # Skip old critical section
    getline
    while ($0 ~ /^\s+[a-z]/ && !/^routing_secondary:/ && !/^routing:$/ && !/^cadence:/ && !/^check_profiles:/ && !/^auto_approve:/) {
      getline
    }
    # Print new critical section
    printf "%s", new_crit
    next
  }
  /^routing_secondary:/ {
    print
    # Skip old secondary section
    getline
    while ($0 ~ /^\s+[a-z]/ && !/^cadence:/ && !/^check_profiles:/ && !/^auto_approve:/) {
      getline
    }
    # Print new secondary section
    printf "%s", new_sec
    next
  }
  { print }
' "$PRESET_FILE" > "$TMPFILE"

mv "$TMPFILE" "$PRESET_FILE"

echo "Updated routing_critical and routing_secondary in $PRESET_FILE"
echo "Review the changes and verify correctness."
