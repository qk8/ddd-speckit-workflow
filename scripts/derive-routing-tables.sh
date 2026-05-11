#!/usr/bin/env bash
# derive-routing-tables.sh — Auto-derive routing tables from checks[].tier + applies_to
#
# Usage: bash scripts/derive-routing-tables.sh [--write] <preset_file>
#
# Reads ddd-clean-arch/preset.yml and auto-derives:
#   routing:            all applicable checks/dimensions per module type
#   routing_critical:   critical-tier checks/dimensions per module type
#   routing_secondary:  secondary-tier checks/dimensions per module type
#
# Without --write: prints the derived tables to stdout for review.
# With --write: updates preset.yml in place.
#
# NEW (v2): Works with consolidated dimensions. Dimensions have sub_checks.
# The routing tables reference dimension IDs, not individual check IDs.
# Tertiary dimensions are NOT included in routing tables (deferred to code review).
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

# ── Parse checks/dimensions from preset.yml ─────────────────────
# Store parsed data in temp files: one file per check/dimension.
# Format per check file: "TIER\nAPPLIES_TO"

CHECKS_DIR="$TMPDIR_DERIVE/checks"
mkdir -p "$CHECKS_DIR"

current_check=""

while IFS= read -r line; do
  # Match check/dimension ID line (2-space indent, valid ID, colon-terminated)
  # IDs: uppercase letters/digits (A, BC, AC, AS) or lowercase snake_case (test_execution)
  # Excludes sub-fields like sub_checks, runs_on (indented at 4+ spaces)
  if echo "$line" | grep -qE '^  ([A-Z][A-Z0-9]*|[a-z][a-z_]*):$'; then
    current_check=$(echo "$line" | sed 's/^  \([A-Z][A-Z0-9]*\|[a-z][a-z_]*\):.*/\1/')
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

  # Reset current_check on new top-level key
  if [ -n "$current_check" ] && echo "$line" | grep -qE '^[a-z]'; then
    current_check=""
  fi
done < "$PRESET_FILE"

# ── Known module types ───────────────────────────────────────────
MODULE_TYPES="backend-domain backend-infra backend-api shared integration frontend-data frontend-feature e2e"

# ── Derive routing tables ────────────────────────────────────────
ROUTING_DIR="$TMPDIR_DERIVE/routing"
mkdir -p "$ROUTING_DIR"

for module in $MODULE_TYPES; do
  echo "" > "$ROUTING_DIR/all_$module"
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
      # Add to "all" routing table (only critical + secondary, skip tertiary)
      case "$tier" in
        critical|secondary)
          existing=$(cat "$ROUTING_DIR/all_$module")
          if [ -n "$existing" ]; then
            echo "$existing, $check_id" > "$ROUTING_DIR/all_$module"
          else
            echo "$check_id" > "$ROUTING_DIR/all_$module"
          fi
          ;;
      esac

      # Add to tier-specific routing table (skip tertiary)
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
        # tertiary: NOT included in routing tables (deferred to code review)
      esac
    fi
  done
done

# ── Output derived tables ────────────────────────────────────────
echo "━━━ Derived Routing Tables (v2 — dimensions) ━━━"
echo ""
echo "routing:"
for module in $MODULE_TYPES; do
  echo "  $module: [$(cat "$ROUTING_DIR/all_$module")]"
done

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
  echo "Note: Manual overrides in preset.yml may intentionally differ"
  echo "from derived values (e.g., per-module-tier variations)."
  echo ""
  echo "To update preset.yml with derived values:"
  echo "  bash scripts/derive-routing-tables.sh --write $PRESET_FILE"
  exit 0
fi

# ── Write mode: update preset.yml ────────────────────────────────
echo ""
echo "━━━ Writing to $PRESET_FILE ━━━"

# Build the new routing tables as YAML strings
new_all=""
new_critical=""
new_secondary=""
for module in $MODULE_TYPES; do
  checks=$(cat "$ROUTING_DIR/all_$module")
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
  new_all="$new_all  $module:   [$formatted]
"

  checks=$(cat "$ROUTING_DIR/critical_$module")
  formatted=""
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

  checks=$(cat "$ROUTING_DIR/secondary_$module")
  formatted=""
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

# Use awk to replace routing, routing_critical, routing_secondary sections
TMPFILE=$(mktemp)

awk -v new_all="$new_all" -v new_crit="$new_critical" -v new_sec="$new_secondary" '
  /^routing:/ && !/^routing_/ {
    print
    # Skip old routing section (indented lines under routing:)
    getline
    while ($0 ~ /^\s+[a-z]/ && !/^routing_/ && !/^cadence:/ && !/^check_profiles:/ && !/^auto_approve:/) {
      getline
    }
    printf "%s", new_all
    next
  }
  /^routing_critical:/ {
    print
    getline
    while ($0 ~ /^\s+[a-z]/ && !/^routing_/ && !/^cadence:/ && !/^check_profiles:/ && !/^auto_approve:/) {
      getline
    }
    printf "%s", new_crit
    next
  }
  /^routing_secondary:/ {
    print
    getline
    while ($0 ~ /^\s+[a-z]/ && !/^cadence:/ && !/^check_profiles:/ && !/^auto_approve:/) {
      getline
    }
    printf "%s", new_sec
    next
  }
  { print }
' "$PRESET_FILE" > "$TMPFILE"

mv "$TMPFILE" "$PRESET_FILE"

echo "Updated routing, routing_critical, and routing_secondary in $PRESET_FILE"
echo "Review the changes and verify correctness."
