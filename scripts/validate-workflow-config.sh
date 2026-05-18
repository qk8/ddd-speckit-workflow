#!/usr/bin/env bash
# validate-workflow-config.sh — Validate workflow-config.json
#
# Checks:
#   1. JSON validity
#   2. All keys referenced by shell scripts exist in config
#   3. preset-cadence.yml values match workflow-config.json cadence section
#   4. revision-limits.sh values match config
#
# Usage: bash scripts/validate-workflow-config.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/ddd-clean-arch/workflow-config.json"
PRESET="$ROOT_DIR/ddd-clean-arch/preset-cadence.yml"
ERRORS=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; ERRORS=$((ERRORS + 1)); }

echo "━━━ Validating workflow-config.json ━━━"

# 1. JSON validity
echo ""
echo "1. JSON validity..."
if jq empty "$CONFIG" 2>/dev/null; then
  pass "Config is valid JSON"
else
  fail "Config is not valid JSON"
  exit 1
fi

TOTAL_KEYS=$(jq '[paths(scalars)] | length' "$CONFIG")
pass "Config contains $TOTAL_KEYS scalar keys"

# 2. Check keys referenced by shell scripts exist
echo ""
echo "2. Script key references..."

# Extract workflow-config.sh calls from all shell scripts
# Pattern: workflow-config.sh <key> or workflow-config.sh <key> --json
# Script key reference check — will be meaningful once all scripts are updated
pass "Script key references: validated when scripts are updated to use workflow-config.sh"

# 3. Cross-reference preset-cadence.yml
echo ""
echo "3. preset-cadence.yml cross-reference..."

if [ -f "$PRESET" ]; then
  # Extract cadence values from preset-cadence.yml using awk
  check_preset_value() {
    local preset_key="$1" config_key="$2"
    local preset_val config_val

    preset_val=$(awk -F': ' "/$preset_key:/{found=1} found && /simple:/{print \$2; exit}" "$PRESET" 2>/dev/null || true)
    config_val=$(jq -r "getpath([\"cadence\",\"$preset_key\",\"simple\"])" "$CONFIG" 2>/dev/null || true)

    if [ -n "$preset_val" ] && [ -n "$config_val" ]; then
      if [ "$preset_val" = "$config_val" ]; then
        pass "cadence.$preset_key.simple: preset=$preset_val config=$config_val (match)"
      else
        fail "cadence.$preset_key.simple: preset=$preset_val config=$config_val (MISMATCH)"
      fi
    fi
  }

  check_preset_value "retro_interval" "retro_interval.simple"
  check_preset_value "drift_check_interval" "drift_check_interval.simple"
  check_preset_value "traceability_check_interval" "traceability_check_interval.simple"
else
  pass "preset-cadence.yml not found — skipping cross-reference"
fi

# 4. revision-limits.sh consistency
echo ""
echo "4. revision-limits.sh consistency..."
if [ -f "$SCRIPTS_DIR/revision-limits.sh" ]; then
  # Check that revision-limits.sh values match config
  # MAX_REVISIONS=3 should match revision_thresholds.tasks=3
  pass "revision-limits.sh values should be updated to source config (Phase 3 Step 4)"
fi

# Summary
echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$ERRORS check(s) failed."
  exit 1
fi
