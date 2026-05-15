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
# Input validation: GATE_NAME is required — prevents silent auto-approve on missing arg
if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
  echo "ERROR: check-gate-preconditions.sh requires <feature_dir> <gate_name>" >&2
  echo "GATE_ERROR=missing_gate_name"
  echo "GATE_FORCE_HUMAN=true"
  exit 1
fi
GATE_NAME="$2"
RESULTS_DIR="$FEATURE_DIR/.artifacts/check-results"

# ── Gate evaluation log (C4: auto-approve transparency) ──────────
GATE_LOG_DIR="$FEATURE_DIR/.artifacts"
mkdir -p "$GATE_LOG_DIR"
GATE_LOG="$GATE_LOG_DIR/gate-eval-${GATE_NAME}.log"
: > "$GATE_LOG"  # truncate

log_gate() { echo "$1" >> "$GATE_LOG"; }
log_gate "=== Gate evaluation: $GATE_NAME at $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown) ==="

# ── Read auto_approve.enabled from preset.yml ──────────────────
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PRESET_FILE="$(cd "$SCRIPTS_DIR/../ddd-clean-arch" && pwd)/preset.yml"

AUTO_APPROVE="false"
GATE_ERROR=""
if [ -f "$PRESET_FILE" ]; then
  _AA=$(awk '/^auto_approve:/{found=1; next} found && /^[a-z]/{exit} found && /enabled:/{print $2; exit}' "$PRESET_FILE" 2>/dev/null || true)
  if [ -z "$_AA" ]; then
    log_gate "WARN: Could not parse auto_approve.enabled from preset.yml"
  fi
  [ "$_AA" = "true" ] && AUTO_APPROVE="true"
else
  GATE_ERROR="preset_file_missing"
  log_gate "ERROR: preset.yml not found at $PRESET_FILE"
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
  log_gate "gate_blocked=true failing_checks=$FAILING"
else
  echo "GATE_BLOCKED=false"
  echo "FAILING_CHECKS="
  log_gate "gate_blocked=false"
fi

echo "AUTO_APPROVE=$AUTO_APPROVE"

# ── Fail-safe: force human review when evaluation failed ────────
# If any step of the gate evaluation failed (missing preset, parse error),
# default to requiring human review rather than auto-approving.
if [ -n "$GATE_ERROR" ]; then
  GATE_FORCE_HUMAN="true"
  log_gate "FALLBACK: GATE_FORCE_HUMAN=true due to $GATE_ERROR"
fi

# ── Acceptance gate requires TDD evidence ──────────────────────
# Acceptance criteria are semantic — a script cannot fully verify
# behavioral correctness without running the code. The TDD gate
# (review-tdd) validates red/green evidence which is the closest
# deterministic proxy for acceptance criteria satisfaction.
# If the acceptance gate is auto-approved without TDD evidence,
# the agent can pass all checks while failing the spec.
ACCEPTANCE_REQUIRES_TDD="false"
if [ "$GATE_NAME" = "acceptance" ] && [ -f "$PRESET_FILE" ]; then
  _AA_TDD=$(awk '/^auto_approve:/{found=1; next} found && /tdd_evidence_required:/{print $2; exit}' "$PRESET_FILE" 2>/dev/null || true)
  if [ -z "$_AA_TDD" ]; then
    log_gate "WARN: Could not parse tdd_evidence_required from preset.yml"
  fi
  [ "$_AA_TDD" = "true" ] && ACCEPTANCE_REQUIRES_TDD="true"
fi
echo "ACCEPTANCE_REQUIRES_TDD=$ACCEPTANCE_REQUIRES_TDD"
log_gate "acceptance_requires_tdd=$ACCEPTANCE_REQUIRES_TDD"

# ── Check if this gate is non-auto-approvable ──────────────────
# Some quality gates (TDD integrity, spec compliance) should never
# be auto-approved even when deterministic checks pass.
GATE_FORCE_HUMAN="false"
if [ -f "$PRESET_FILE" ]; then
  _NAA=$(awk '/^non_auto_approvable:/{found=1; next} found && /^[a-z]/{exit} found && /'"$GATE_NAME"'/{print "true"; exit}' "$PRESET_FILE" 2>/dev/null || true)
  if [ -z "$_NAA" ]; then
    log_gate "WARN: Could not parse non_auto_approvable for gate '$GATE_NAME'"
  fi
  [ "$_NAA" = "true" ] && GATE_FORCE_HUMAN="true"
fi
echo "GATE_FORCE_HUMAN=$GATE_FORCE_HUMAN"
log_gate "force_human=$GATE_FORCE_HUMAN"

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

log_gate "=== End gate evaluation ==="
