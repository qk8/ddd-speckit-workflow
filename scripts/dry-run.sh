#!/usr/bin/env bash
# dry-run.sh — Validate workflow config without executing LLM calls
#
# Usage: bash scripts/dry-run.sh [feature_dir]
#
# N1: Dry run mode for workflow validation.
# Validates preset.yml, checks, routing tables, and command references
# without invoking any Claude/LLM calls.
#
# Exit codes:
#   0 = config valid
#   1 = config errors found
#   2 = config warnings (valid but recommended fixes)

set -euo pipefail

FEATURE_DIR="${1:-.}"
PRESET_FILE="$(cd "$(dirname "$0")/../ddd-clean-arch" && pwd)/preset.yml"
ERRORS=0
WARNINGS=0

report() {
  local level="$1" msg="$2"
  case "$level" in
    ERROR) echo "DRY-RUN [ERROR]: $msg"; ERRORS=$((ERRORS + 1)) ;;
    WARN)  echo "DRY-RUN [WARN]:  $msg"; WARNINGS=$((WARNINGS + 1)) ;;
    OK)    echo "DRY-RUN [OK]:    $msg" ;;
  esac
}

# ── 1. Validate preset.yml structure ────────────────────────────
echo "━━━ Validating preset.yml ━━━"

if [ ! -f "$PRESET_FILE" ]; then
  report ERROR "preset.yml not found at $PRESET_FILE"
  exit 1
fi
report OK "preset.yml found"

# Validate required sections
for section in templates commands checks routing; do
  if grep -q "^${section}:" "$PRESET_FILE" 2>/dev/null; then
    report OK "Section '$section' present"
  else
    report WARN "Section '$section' missing from preset.yml"
  fi
done

# ── 2. Validate check references ────────────────────────────────
echo ""
echo "━━━ Validating check definitions ━━━"

# Extract check IDs from preset.yml
CHECK_IDS=$(awk '/^checks:/{found=1; next} found && /^[a-z]/{exit} found && /^[[:space:]]+[A-Z]+:/{gsub(/:/,"",$1); print $1}' "$PRESET_FILE" 2>/dev/null || true)

for check_id in $CHECK_IDS; do
  # Check that each check has required fields
  if ! awk -v cid="$check_id" '
    /^checks:/ { found=1; next }
    found && /^[a-z]/ { exit }
    found && "    " cid ":" { has_cid=1; next }
    found && has_cid && /name:/ { has_name=1 }
    found && has_cid && /tier:/ { has_tier=1 }
    found && has_cid && /applies_to:/ { has_applies=1 }
    found && /^[a-z]/ { exit }
    END { if (has_name && has_tier && has_applies) print "OK" }
  ' "$PRESET_FILE" 2>/dev/null | grep -q "OK"; then
    report ERROR "Check $check_id missing required fields (name, tier, applies_to)"
  else
    report OK "Check $check_id fully defined"
  fi

  # Check that sub-check file exists
  CHECK_FILE="$(cd "$(dirname "$PRESET_FILE")" && pwd)/commands/checks/check_${check_id}_*.mdc"
  CHECK_FILES=$(ls $CHECK_FILE 2>/dev/null || true)
  if [ -z "$CHECK_FILES" ]; then
    # Check if it's a deterministic check (no sub-file needed)
    TIER=$(awk -v cid="$check_id" '
      /^checks:/ { found=1; next }
      found && /^[a-z]/ { exit }
      found && "    " cid ":" { has_cid=1; next }
      found && has_cid && /tier:/ { print; exit }
    ' "$PRESET_FILE" 2>/dev/null || true)
    if echo "$TIER" | grep -qE 'critical|secondary'; then
      report WARN "Check $check_id (tier: $TIER) has no sub-check file"
    fi
  fi
done

# ── 3. Validate routing table consistency ───────────────────────
echo ""
echo "━━━ Validating routing tables ━━━"

# Extract task types from routing table
TASK_TYPES=$(awk '/^routing_critical:/{found=1; next} found && /^[a-z]/{exit} found && /:/ {gsub(/:/,"",$1); print $1}' "$PRESET_FILE" 2>/dev/null || true)

for task_type in $TASK_TYPES; do
  # Check that critical routing has entries
  CRIT_COUNT=$(awk -v tt="$task_type" '
    /^routing_critical:/ { found=1; next }
    found && /^[a-z]/ { exit }
    found && $0 ~ "[[:space:]]*" tt ":" {
      s=$0; sub(/.*\[/, "", s); sub(/\].*/, "", s); gsub(/[[:space:]]/, "", s)
      n=split(s, a, ","); print n
    }
  ' "$PRESET_FILE" 2>/dev/null || echo "0")

  if [ "$CRIT_COUNT" -eq 0 ]; then
    report WARN "Task type '$task_type' has no critical checks in routing table"
  else
    report OK "Task type '$task_type' has $CRIT_COUNT critical checks"
  fi
done

# ── 4. Validate command references ──────────────────────────────
echo ""
echo "━━━ Validating command references ━━━"

# Extract command overrides from preset.yml
CMD_OVERRIDE=$(awk '/^commands:/{found=1; next} found && /^[a-z]/{exit} found && /speckit\./ {gsub(/[" -]/,"",$1); print $1}' "$PRESET_FILE" 2>/dev/null || true)

for cmd in $CMD_OVERRIDE; do
  CMD_FILE="$(cd "$(dirname "$PRESET_FILE")" && pwd)/commands/${cmd}.md"
  if [ -f "$CMD_FILE" ]; then
    report OK "Command $cmd.md found"
  else
    report ERROR "Command $cmd.md referenced in preset.yml but not found at $CMD_FILE"
  fi
done

# ── 5. Validate preset-checks.yml (if present) ──────────────────
echo ""
echo "━━━ Validating preset-checks.yml ━━━"

PRESET_CHECKS_FILE="$(cd "$(dirname "$PRESET_FILE")" && pwd)/preset-checks.yml"
if [ -f "$PRESET_CHECKS_FILE" ]; then
  report OK "preset-checks.yml found"

  # Validate that applies_to entries match known task types
  KNOWN_TYPES="backend-domain backend-infra backend-api shared integration frontend-data frontend-feature e2e all"
  APPLIES_TO=$(awk '/^checks:/{found=1; next} found && /^[a-z]/{exit} found && /applies_to:/ {
    s=$0; sub(/.*\[/, "", s); sub(/\].*/, "", s); gsub(/[[:space:]]/, "", s); print s
  }' "$PRESET_CHECKS_FILE" 2>/dev/null || true)

  for entry in $(echo "$APPLIES_TO" | tr ',' '\n'); do
    found_type=false
    for kt in $KNOWN_TYPES; do
      if [ "$entry" = "$kt" ]; then
        found_type=true
        break
      fi
    done
    if [ "$found_type" = false ]; then
      report WARN "applies_to entry '$entry' does not match known task types"
    fi
  done
else
  report WARN "preset-checks.yml not found (routing table may be incomplete)"
fi

# ── 6. Validate tasks.md template ───────────────────────────────
echo ""
echo "━━━ Validating template references ━━━"

TEMPLATE_DIR="$(cd "$(dirname "$PRESET_FILE")" && pwd)/templates"
for template in plan tasks constitution; do
  TEMPLATE_SRC=$(awk -v t="$template" '
    /^templates:/ { found=1; next }
    found && /^[a-z]/{exit}
    found && "  " t ":" { getline; print }
  ' "$PRESET_FILE" 2>/dev/null || true)
  if [ -n "$TEMPLATE_SRC" ] && [ -f "$TEMPLATE_DIR/$TEMPLATE_SRC" ]; then
    report OK "Template $template -> $TEMPLATE_SRC found"
  else
    report WARN "Template $template source '$TEMPLATE_SRC' not found"
  fi
done

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "DRY-RUN: $ERRORS error(s), $WARNINGS warning(s)"

if [ "$ERRORS" -gt 0 ]; then
  echo "Fix the errors above before running the workflow."
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  echo "Configuration is valid but has warnings. Review recommended."
  exit 0
fi

echo "Configuration is fully valid. No issues found."
exit 0
