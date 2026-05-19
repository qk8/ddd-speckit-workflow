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

MISSING_KEYS=0

# Function to extract config key from a single line of workflow-config.sh usage
extract_key() {
  local line="$1"
  # Strip everything up to and including 'workflow-config.sh'
  local after
  after=$(echo "$line" | sed 's/.*workflow-config\.sh[[:space:]]*//')
  # Remove leading quote if present
  after="${after#\"}"
  # Extract the first word (the key argument)
  local key
  key=$(echo "$after" | awk '{print $1}')
  # Remove trailing quote if key is quoted
  key="${key%\"}"
  echo "$key"
}

# Collect all unique static keys referenced across scripts
TMPKEYS=$(mktemp)
EXCLUDED_FILES=( "$SCRIPTS_DIR/workflow-config.sh" "$SCRIPTS_DIR/validate-workflow-config.sh" )
EXCLUDE_ARGS=()
for f in "${EXCLUDED_FILES[@]}"; do
  EXCLUDE_ARGS+=(--exclude="$f")
done

grep -rh --binary-files=without-match 'workflow-config\.sh' "${EXCLUDE_ARGS[@]}" "$SCRIPTS_DIR/" --include='*.sh' | grep -v '^[[:space:]]*#' | while IFS= read -r line; do
  key=$(extract_key "$line")
  # Skip dynamic keys containing variables
  case "$key" in *'$'*) continue ;; esac
  # Skip empty, usage text, or non-key tokens
  [ -z "$key" ] && continue
  case "$key" in \<*) continue ;; esac  # skip usage hints like <key>
  # Only accept keys that look like config paths (must contain a dot)
  case "$key" in *.* ) echo "$key" ;; esac
done | sort -u > "$TMPKEYS"

TOTAL_REFERENCED=$(wc -l < "$TMPKEYS")

while IFS= read -r key; do
  [ -z "$key" ] && continue
  # Check if key exists in config using jq split (avoids quote escaping issues)
  if ! jq --arg key "$key" -e 'getpath($key | split("."))' "$CONFIG" >/dev/null 2>&1; then
    fail "Missing config key: $key"
    MISSING_KEYS=$((MISSING_KEYS + 1))
  fi
done < "$TMPKEYS"
rm -f "$TMPKEYS"

if [ "$MISSING_KEYS" -eq 0 ]; then
  pass "All script-referenced config keys exist in workflow-config.json"
fi
pass "Checked $TOTAL_REFERENCED unique config key references across scripts"

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
  # Extract the config keys that revision-limits.sh references and verify they match
  # revision-limits.sh uses these mappings:
  #   MAX_REVISIONS        → revision_thresholds.tasks
  #   MAX_DRIFT_REVISIONS  → stagnation.drift_revision_limit
  #   MAX_SPEC_REVISIONS   → revision_thresholds.spec
  #   GLOBAL_CORRECTION_CAP → other.batch_correction_cap

  check_limit() {
    local label="$1" config_key="$2" script_default="$3"
    local config_val
    config_val=$(jq -r "getpath([\"$(echo "$config_key" | sed 's/\./","/g')\"])" "$CONFIG" 2>/dev/null || echo "")

    if [ -z "$config_val" ]; then
      fail "revision-limits.sh: $label references missing config key '$config_key'"
      return
    fi

    if [ "$config_val" = "$script_default" ]; then
      pass "revision-limits.$label: config=$config_val script-default=$script_default (match)"
    else
      fail "revision-limits.$label: config=$config_val script-default=$script_default (DRIFT)"
      if [ "$STRICT_MODE" = true ]; then
        ERRORS=$((ERRORS + 1))
      fi
    fi
  }

  STRICT_MODE=false
  FIX_MODE=false
  for arg in "$@"; do
    case "$arg" in --strict) STRICT_MODE=true ;; --fix) FIX_MODE=true ;; esac
  done

  check_limit "MAX_REVISIONS" "revision_thresholds.tasks" "3"
  check_limit "MAX_DRIFT_REVISIONS" "stagnation.drift_revision_limit" "2"
  check_limit "MAX_SPEC_REVISIONS" "revision_thresholds.spec" "3"
  check_limit "GLOBAL_CORRECTION_CAP" "other.batch_correction_cap" "10"

  # --fix mode: update revision-limits.sh defaults to match config
  if [ "$FIX_MODE" = true ] && [ -f "$SCRIPTS_DIR/revision-limits.sh" ]; then
    echo ""
    echo "  --fix: updating revision-limits.sh defaults to match config..."
    FIX_TMP=$(mktemp "${SCRIPTS_DIR}/revision-limits.sh.XXXXXX")
    cp "$SCRIPTS_DIR/revision-limits.sh" "$FIX_TMP"

    # Update each default value in the fallback (else branch)
    config_val=$(jq -r '.revision_thresholds.tasks' "$CONFIG")
    sed -i "s/: \"\${MAX_REVISIONS:=3}/: \"\${MAX_REVISIONS:=${config_val}}/" "$FIX_TMP"

    config_val=$(jq -r '.stagnation.drift_revision_limit' "$CONFIG")
    sed -i "s/: \"\${MAX_DRIFT_REVISIONS:=2}/: \"\${MAX_DRIFT_REVISIONS:=${config_val}}/" "$FIX_TMP"

    config_val=$(jq -r '.revision_thresholds.spec' "$CONFIG")
    sed -i "s/: \"\${MAX_SPEC_REVISIONS:=3}/: \"\${MAX_SPEC_REVISIONS:=${config_val}}/" "$FIX_TMP"

    config_val=$(jq -r '.other.batch_correction_cap' "$CONFIG")
    sed -i "s/: \"\${GLOBAL_CORRECTION_CAP:=10}/: \"\${GLOBAL_CORRECTION_CAP:=${config_val}}/" "$FIX_TMP"

    mv "$FIX_TMP" "$SCRIPTS_DIR/revision-limits.sh"
    echo "  --fix: revision-limits.sh updated"
  fi
else
  fail "revision-limits.sh not found"
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
