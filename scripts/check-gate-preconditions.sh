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

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

# ── Parse flags ────────────────────────────────────────────────────
JSON_MODE=false
CRITICAL_SKIP_BLOCKS="true"
GATE_NAME=""
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --json)              JSON_MODE=true ;;
    --help)              check_help "check-gate-preconditions.sh" "<feature_dir> <gate_name> [--json] [--critical-skip-blocks] [--help]" ;;
    --critical-skip-blocks) CRITICAL_SKIP_BLOCKS="true" ;;
    --no-critical-skip-blocks) CRITICAL_SKIP_BLOCKS="false" ;;
    *)                   POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]}"

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(check_find_feature_dir "" || true)
fi

# Input validation: GATE_NAME is required — prevents silent auto-approve on missing arg
if [ $# -lt 1 ] || [ -z "${2:-}" ]; then
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
GATE_BLOCKED="false"
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

# ── Detect critical-tier skipped checks ──────────────────────────
# A skipped critical check means a required quality gate was not executed.
# This is treated as equivalent to FAIL for gate blocking when --critical-skip-blocks.
CRITICAL_SKIPS=""
CRITICAL_SKIP_COUNT=0

if [ "$CRITICAL_SKIP_BLOCKS" = "true" ] && [ -d "$RESULTS_DIR" ]; then
  for result_file in "$RESULTS_DIR"/*.result; do
    [ -f "$result_file" ] || continue
    check_id=$(basename "$result_file" .result)
    first_line=$(head -1 "$result_file" 2>/dev/null || echo "UNKNOWN")
    if [ "$first_line" = "SKIP" ]; then
      # Check if this is a critical-tier check
      # Critical checks: those in preset-routing.yml under routing_critical for any task type
      # For simplicity, treat all non-deterministic checks (G,T,U,Z, etc.) and security checks as critical
      # when no tier info is available. Known critical check IDs:
      is_critical=false
      case "$check_id" in
        adversarial|crosscutting|failure_modes|resilience|performance_budget|secret_scan|owasp|session_security|regression|new_tests|lint|complexity|naming|drift|constraints|api_surface|test_quality|negative_tests|arch_tests|contract|migration|quantitative)
          is_critical=true
          ;;
      esac
      if [ "$is_critical" = true ]; then
        CRITICAL_SKIP_COUNT=$((CRITICAL_SKIP_COUNT + 1))
        if [ -n "$CRITICAL_SKIPS" ]; then
          CRITICAL_SKIPS="$CRITICAL_SKIPS,$check_id"
        else
          CRITICAL_SKIPS="$check_id"
        fi
      fi
    fi
  done
fi

if [ -n "$CRITICAL_SKIPS" ]; then
  echo "GATE_BLOCKED=true"
  if [ -n "$FAILING" ]; then
    echo "FAILING_CHECKS=$FAILING,$CRITICAL_SKIPS"
  else
    echo "FAILING_CHECKS=$CRITICAL_SKIPS"
  fi
  log_gate "gate_blocked=true failing_checks=${FAILING:+$FAILING,}$CRITICAL_SKIPS"
  log_gate "CRITICAL_SKIPS=$CRITICAL_SKIPS (skipped critical checks treated as FAIL)"
else
  if [ -n "$FAILING" ]; then
    echo "GATE_BLOCKED=true"
    echo "FAILING_CHECKS=$FAILING"
    log_gate "gate_blocked=true failing_checks=$FAILING"
  else
    echo "GATE_BLOCKED=false"
    echo "FAILING_CHECKS="
    log_gate "gate_blocked=false"
  fi
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
  if [ -n "$CRITICAL_SKIPS" ]; then
    echo "  critical_skips=$CRITICAL_SKIP_COUNT"
    echo "  critical_skip_list=$CRITICAL_SKIPS"
  fi
  echo "  gate=$GATE_NAME"
  echo "  status=APPROVED"
fi

log_gate "=== End gate evaluation ==="

# ── Write .result file ─────────────────────────────────────────────
if [ -n "$FEATURE_DIR" ]; then
  if [ "$GATE_BLOCKED" = "true" ]; then
    check_write_result "$FEATURE_DIR" "gate_preconditions" "FAIL" "$FAILING_CHECKS"
  else
    check_write_result "$FEATURE_DIR" "gate_preconditions" "PASS"
  fi
fi
exit 0
