#!/usr/bin/env bash
# Check deterministic check results and set gate blocking state.
# Usage: check-gate-preconditions.sh <feature_dir> <gate_name>
#
# Outputs:
#   GATE_BLOCKED=true|false
#   FAILING_CHECKS=<comma-separated check IDs>
#   AUTO_APPROVE=true|false
#
# If GATE_BLOCKED=true, the review gate should NOT offer approve.
# If AUTO_APPROVE=true and GATE_BLOCKED=false, the gate auto-approves.

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-gate-preconditions.sh <feature_dir> <gate_name>}"
GATE_NAME="${2:-}"
RESULTS_DIR="$FEATURE_DIR/.artifacts/check-results"

# ── Read auto_approve.enabled from preset.yml ──────────────────
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PRESET_FILE="$(cd "$SCRIPTS_DIR/../ddd-clean-arch" && pwd)/preset.yml"

AUTO_APPROVE="false"
if [ -f "$PRESET_FILE" ]; then
  _AA=$(awk '/^auto_approve:/{found=1; next} found && /^[a-z]/{exit} found && /enabled:/{print $2; exit}' "$PRESET_FILE" 2>/dev/null || true)
  [ "$_AA" = "true" ] && AUTO_APPROVE="true"
fi

FAILING=""
if [ -d "$RESULTS_DIR" ]; then
  for result_file in "$RESULTS_DIR"/*.result; do
    [ -f "$result_file" ] || continue
    check_id=$(basename "$result_file" .result)
    # Check if ANY line says FAIL (handles multi-line .result files)
    if grep -q '^FAIL$' "$result_file" 2>/dev/null; then
      if [ -n "$FAILING" ]; then
        FAILING="$FAILING,$check_id"
      else
        FAILING="$check_id"
      fi
    fi
  done
fi

if [ -n "$FAILING" ]; then
  echo "GATE_BLOCKED=true"
  echo "FAILING_CHECKS=$FAILING"
else
  echo "GATE_BLOCKED=false"
  echo "FAILING_CHECKS="
fi

echo "AUTO_APPROVE=$AUTO_APPROVE"

# ── Check if this gate is non-auto-approvable ──────────────────
# Some quality gates (TDD integrity, spec compliance) should never
# be auto-approved even when deterministic checks pass.
GATE_FORCE_HUMAN="false"
if [ -f "$PRESET_FILE" ]; then
  _NAA=$(awk '/^non_auto_approvable:/{found=1; next} found && /^[a-z]/{exit} found && /'"$GATE_NAME"'/{print "true"; exit}' "$PRESET_FILE" 2>/dev/null || true)
  [ "$_NAA" = "true" ] && GATE_FORCE_HUMAN="true"
fi
echo "GATE_FORCE_HUMAN=$GATE_FORCE_HUMAN"

# ── Auto-approve transparency (C4) ─────────────────────────────
# Even when auto-approving, output a summary of which checks passed
# and their results. This prevents the "invisible approval" problem
# where the human reviewer can't tell if the gate was truly clean.
if [ "$AUTO_APPROVE" = "true" ] && [ "$GATE_BLOCKED" = "false" ] && [ "$GATE_FORCE_HUMAN" = "false" ]; then
  echo ""
  echo "AUTO_APPROVE_SUMMARY:"
  _TOTAL=0
  _PASS=0
  _FAIL=0
  _SKIP=0
  if [ -d "$RESULTS_DIR" ]; then
    for result_file in "$RESULTS_DIR"/*.result; do
      [ -f "$result_file" ] || continue
      _check_id=$(basename "$result_file" .result)
      _result_line=$(head -1 "$result_file" 2>/dev/null || echo "UNKNOWN")
      _TOTAL=$((_TOTAL + 1))
      case "$_result_line" in
        PASS) _PASS=$((_PASS + 1)) ;;
        FAIL) _FAIL=$((_FAIL + 1)) ;;
        *) _SKIP=$((_SKIP + 1)) ;;
      esac
    done
  fi
  echo "  checks_total=$_TOTAL"
  echo "  checks_pass=$_PASS"
  echo "  checks_fail=$_FAIL"
  echo "  checks_skip=$_SKIP"
  echo "  gate=$GATE_NAME"
  echo "  status=APPROVED"
fi
