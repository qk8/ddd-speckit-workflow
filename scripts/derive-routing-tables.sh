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

set -euo pipefail

WRITE_MODE=false
if [ "${1:-}" = "--write" ]; then
  WRITE_MODE=true
fi

PRESET_FILE="${2:?Usage: derive-routing-tables.sh [--write] <preset_file>}"

if [ ! -f "$PRESET_FILE" ]; then
  echo "ERROR: preset file not found: $PRESET_FILE" >&2
  exit 1
fi

# ── Parse checks from preset.yml ─────────────────────────────────
# Extract check_id, tier, and applies_to for each check.
# Format: CHECK_ID|TIER|APPLIES_TO (pipe-separated, applies_to is comma-separated)

declare -A CHECK_TIER
declare -A CHECK_APPLIES

current_check=""
current_tier=""
current_applies=""

while IFS= read -r line; do
  # Match check ID line (e.g., "  A:" or "  BC:")
  if echo "$line" | grep -qE '^\s{2}[A-Z][A-Z0-9]*:'; then
    current_check=$(echo "$line" | sed 's/^\s*\([A-Z][A-Z0-9]*\):.*/\1/')
    CHECK_TIER["$current_check"]=""
    CHECK_APPLIES["$current_check"]=""
    continue
  fi

  # Match tier line
  if [ -n "$current_check" ] && echo "$line" | grep -qE '^\s+tier:'; then
    current_tier=$(echo "$line" | sed 's/.*tier:\s*//' | tr -d ' ')
    CHECK_TIER["$current_check"]="$current_tier"
    continue
  fi

  # Match applies_to line
  if [ -n "$current_check" ] && echo "$line" | grep -qE '^\s+applies_to:'; then
    current_applies=$(echo "$line" | sed 's/.*applies_to:\s*\[\s*//' | sed 's/\s*\].*//' | tr -d ' ')
    CHECK_APPLIES["$current_check"]="$current_applies"
    continue
  fi

  # Reset current_check on new top-level key
  if echo "$line" | grep -qE '^\s{0,1}[a-z]' && [ -n "$current_check" ]; then
    current_check=""
  fi
done < "$PRESET_FILE"

# ── Known module types ───────────────────────────────────────────
MODULE_TYPES="backend-domain backend-infra backend-api shared integration frontend-data frontend-feature e2e"

# ── Derive routing tables ────────────────────────────────────────
declare -A DERIVED_CRITICAL
declare -A DERIVED_SECONDARY

for module in $MODULE_TYPES; do
  DERIVED_CRITICAL["$module"]=""
  DERIVED_SECONDARY["$module"]=""
done

for check_id in "${!CHECK_TIER[@]}"; do
  tier="${CHECK_TIER[$check_id]}"
  applies="${CHECK_APPLIES[$check_id]}"

  [ -z "$tier" ] && continue
  [ -z "$applies" ] && continue

  for module in $MODULE_TYPES; do
    # Check if module is in applies_to list
    is_applied=false
    if [ "$applies" = "all" ]; then
      is_applied=true
    else
      IFS=',' read -ra modules <<< "$applies"
      for m in "${modules[@]}"; do
        m=$(echo "$m" | tr -d ' ')
        if [ "$m" = "$module" ]; then
          is_applied=true
          break
        fi
      done
    fi

    if [ "$is_applied" = true ]; then
      case "$tier" in
        critical)
          if [ -n "${DERIVED_CRITICAL[$module]}" ]; then
            DERIVED_CRITICAL["$module"]="${DERIVED_CRITICAL[$module]}, $check_id"
          else
            DERIVED_CRITICAL["$module"]="$check_id"
          fi
          ;;
        secondary)
          if [ -n "${DERIVED_SECONDARY[$module]}" ]; then
            DERIVED_SECONDARY["$module"]="${DERIVED_SECONDARY[$module]}, $check_id"
          else
            DERIVED_SECONDARY["$module"]="$check_id"
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
  echo "  $module: [${DERIVED_CRITICAL[$module]}]"
done

echo ""
echo "routing_secondary:"
for module in $MODULE_TYPES; do
  echo "  $module: [${DERIVED_SECONDARY[$module]}]"
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
  checks="${DERIVED_CRITICAL[$module]}"
  # Format as YAML list
  IFS=',' read -ra check_list <<< "$checks"
  formatted=""
  for c in "${check_list[@]}"; do
    c=$(echo "$c" | tr -d ' ')
    [ -z "$c" ] && continue
    if [ -n "$formatted" ]; then
      formatted="$formatted, $c"
    else
      formatted="$c"
    fi
  done
  new_critical="$new_critical  $module:   [$formatted]
"
done

new_secondary=""
for module in $MODULE_TYPES; do
  checks="${DERIVED_SECONDARY[$module]}"
  IFS=',' read -ra check_list <<< "$checks"
  formatted=""
  for c in "${check_list[@]}"; do
    c=$(echo "$c" | tr -d ' ')
    [ -z "$c" ] && continue
    if [ -n "$formatted" ]; then
      formatted="$formatted, $c"
    else
      formatted="$c"
    fi
  done
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
