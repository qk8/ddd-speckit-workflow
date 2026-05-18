#!/usr/bin/env bash
# check-runner.sh — Dimension-based check execution engine
#
# Usage:
#   scripts/check-runner.sh <feature_dir> <task_type>              # run all tiers
#   scripts/check-runner.sh <feature_dir> <task_type> --tier critical|secondary
#   scripts/check-runner.sh <feature_dir> --check <check_id>       # single check
#   scripts/check-runner.sh <feature_dir> <task_type> --list       # show applicable
#   scripts/check-runner.sh <feature_dir> <task_type> --dry-run    # preview only
#
# Reads routing tables from preset-routing.yml and preset-checks-dimensions.yml.
# Each check runs in a subshell with independent error handling.
# Crashes write CRASH to result file (not FAIL).
# Always exits 0 (advisory; callers read .result files).

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

PRESET_DIR="$(cd "$SCRIPTS_DIR/../ddd-clean-arch" && pwd)"

# ── Parse flags ────────────────────────────────────────────────────
MODE="run"
FEATURE_DIR=""
TASK_TYPE=""
TIER=""
CHECK_ID=""

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list)      MODE="list"; shift ;;
    --dry-run)   MODE="dry-run"; shift ;;
    --check)     MODE="single"; shift; CHECK_ID="${1:-}"; shift ;;
    --tier)      shift; TIER="${1:-critical}"; shift ;;
    --help)      check_help "check-runner.sh" "<feature_dir> <task_type> [--tier critical|secondary] [--list|--dry-run|--check <id>]" ;;
    *)           POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(check_find_feature_dir "" || true)
fi
TASK_TYPE="${2:-}"

if [ -z "$FEATURE_DIR" ]; then
  echo "ERROR: Feature directory required" >&2
  echo "Usage: check-runner.sh <feature_dir> <task_type> [--tier critical|secondary]" >&2
  exit 0
fi

RESULTS_DIR="$FEATURE_DIR/.artifacts/check-results"
mkdir -p "$RESULTS_DIR"
LOCK_DIR="$RESULTS_DIR/.locks"
mkdir -p "$LOCK_DIR"

# ── Parse routing table from preset-routing.yml ────────────────────
# Extract dimensions for a given tier and task type.
# Output: space-separated dimension names like "code_quality security spec_compliance test_execution"
parse_routing() {
  local tier="$1"
  local tt="$2"
  local preset_file="$PRESET_DIR/preset-routing.yml"

  if [ ! -f "$preset_file" ]; then
    echo ""
    return
  fi

  awk -v tier="$tier" -v tt="$tt" '
    $0 ~ ("^routing_" tier ":") { in_table=1; next }
    in_table && $0 ~ ("^  " tt ":") {
      s=$0
      gsub(/.*\[/, "", s)
      gsub(/\].*/, "", s)
      gsub(/ /, "", s)
      print s
      exit
    }
    in_table && /^[^ ]/ { exit }
  ' "$preset_file" 2>/dev/null
}

# ── Map dimension name to check script ─────────────────────────────
# Dimension -> script mapping (source of truth for the runner).
# If preset-checks-dimensions.yml has the mapping, use it; otherwise use defaults.
dimension_to_script() {
  local dim="$1"
  local sub="$2"
  local preset_file="$PRESET_DIR/preset-checks-dimensions.yml"

  if [ -f "$preset_file" ]; then
    # Try to parse from preset-checks-dimensions.yml
    local script
    script=$(awk -v dim="$dim" -v sub="$sub" '
      $0 ~ ("^  " dim ":") { found=1; next }
      found && /sub_checks:/ { in_sub=1; next }
      in_sub && ("^    " sub ":") { in_sc=1; next }
      in_sc && /script:/ { gsub(/.*script:[ ]*"?/, ""); gsub(/".*/, ""); print; exit }
      in_sc && /^[^ ]/ { exit }
      in_sub && /^[^ ]/ { in_sub=0 }
      found && /^[^ ]/ { exit }
    ' "$preset_file" 2>/dev/null || true)
    if [ -n "$script" ]; then
      echo "$script"
      return
    fi
  fi

  # ── Default dimension->script mapping (fallback) ───────────────
  case "$dim" in
    test_execution)
      if [ "$sub" = "regression" ]; then echo "run-regression.sh"
      elif [ "$sub" = "new_tests" ]; then echo "run-new-tests.sh"
      else echo "run-regression.sh"
      fi ;;
    code_quality)
      if [ "$sub" = "lint" ]; then echo "run-lint.sh"
      elif [ "$sub" = "complexity" ]; then echo "verify-code-quality.sh"
      elif [ "$sub" = "naming" ]; then echo "check-naming.sh"
      else echo "verify-code-quality.sh"
      fi ;;
    spec_compliance)
      if [ "$sub" = "drift" ]; then echo "quick-drift-check.sh"
      elif [ "$sub" = "constraints" ]; then echo "run-antihallucination.sh"
      elif [ "$sub" = "api_surface" ]; then echo "api-surface-check.sh"
      else echo "quick-drift-check.sh"
      fi ;;
    security)
      if [ "$sub" = "secret_scan" ]; then echo "secret-scan.sh"
      elif [ "$sub" = "owasp" ]; then echo "run-owasp-basic.sh"
      elif [ "$sub" = "session_security" ]; then echo "run-session-security.sh"
      else echo "secret-scan.sh"
      fi ;;
    test_design)
      if [ "$sub" = "test_quality" ]; then echo "verify-test-quality.sh"
      elif [ "$sub" = "failure_modes" ]; then echo "check-failure-modes.sh"
      elif [ "$sub" = "negative_tests" ]; then echo "verify-negative-tests.sh"
      else echo "verify-test-quality.sh"
      fi ;;
    integration)
      if [ "$sub" = "arch_tests" ]; then echo "run-arch-tests.sh"
      elif [ "$sub" = "contract" ]; then echo "validate-api-contract.sh"
      elif [ "$sub" = "migration" ]; then echo "run-migration-test.sh"
      elif [ "$sub" = "crosscutting" ]; then echo "check-crosscutting.sh"
      else echo "check-crosscutting.sh"
      fi ;;
    resilience)
      if [ "$sub" = "resilience_testing" ]; then echo "check-resilience.sh"
      elif [ "$sub" = "adversarial" ]; then echo "check-adversarial.sh"
      else echo "check-resilience.sh"
      fi ;;
    performance)
      if [ "$sub" = "performance_budget" ]; then echo "check-performance-budget.sh"
      elif [ "$sub" = "quantitative" ]; then echo "run-quantitative.sh"
      else echo "check-performance-budget.sh"
      fi ;;
    # Standalone checks (no sub-checks)
    AC) echo "check-adversarial.sh" ;;
    E) echo "check-drift.sh" ;;
    G) echo "check-drift.sh" ;;
    *) echo "" ;;
  esac
}

# ── Expand dimension into sub-check IDs ────────────────────────────
expand_dimension() {
  local dim="$1"
  local preset_file="$PRESET_DIR/preset-checks-dimensions.yml"

  if [ -f "$preset_file" ]; then
    local subs
    subs=$(awk -v dim="$dim" '
      $0 ~ ("^  " dim ":") { found=1; next }
      found && /sub_checks:/ { in_sub=1; next }
      in_sub && /^    [a-z]/ {
        sub(/:.*/, "", $0)
        gsub(/[[:space:]]/, "", $0)
        if ($0 != "") print $0
        next
      }
      in_sub && /^[^ ]/ { exit }
      found && /^[^ ]/ { exit }
    ' "$preset_file" 2>/dev/null || true)
    if [ -n "$subs" ]; then
      echo "$subs"
      return
    fi
  fi

  # ── Default sub-checks per dimension ───────────────────────────
  case "$dim" in
    test_execution) echo "regression
new_tests" ;;
    code_quality) echo "lint
complexity
naming" ;;
    spec_compliance) echo "drift
constraints
api_surface" ;;
    security) echo "secret_scan
owasp
session_security" ;;
    test_design) echo "test_quality
failure_modes
negative_tests" ;;
    integration) echo "arch_tests
contract
migration
crosscutting" ;;
    resilience) echo "resilience_testing
adversarial" ;;
    performance) echo "performance_budget
quantitative" ;;
    AC|E|G) ;; # standalone, no sub-checks
  esac
}

# ── Run a single check ────────────────────────────────────────────
run_check() {
  local check_id="$1"
  local script="$2"
  local result_file="$RESULTS_DIR/${check_id}.result"
  local lock_file="$LOCK_DIR/$(echo "$check_id" | tr '/' '_').lock"

  # If standalone check (no sub-checks), use the check_id as the script name
  if [ -z "$script" ]; then
    check_write_result "$FEATURE_DIR" "$check_id" "SKIP"
    echo "CHECK $check_id: SKIP (no script mapping)"
    return
  fi

  local script_path="$SCRIPTS_DIR/$script"

  if [ ! -f "$script_path" ]; then
    check_write_result "$FEATURE_DIR" "$check_id" "SKIP"
    echo "CHECK $check_id: SKIP ($script not found)"
    return
  fi

  # Run the check script in a subshell
  local output=""
  local exit_code=0
  output=$(bash "$script_path" "$FEATURE_DIR" 2>&1) || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    check_write_result "$FEATURE_DIR" "$check_id" "PASS"
    echo "CHECK $check_id: PASS"
  else
    check_write_result "$FEATURE_DIR" "$check_id" "FAIL"
    echo "CHECK $check_id: FAIL (exit $exit_code)"
  fi
}

# ── Main logic ─────────────────────────────────────────────────────

if [ "$MODE" = "list" ] || [ "$MODE" = "dry-run" ]; then
  echo "━━━ Check Runner ━━━"
  echo "Feature dir: $FEATURE_DIR"
  echo "Task type: $TASK_TYPE"
  echo "Mode: $MODE"
  echo ""

  # List or run critical tier
  if [ -z "$TIER" ] || [ "$TIER" = "critical" ]; then
    echo "--- Critical tier ---"
    CRIT_DIMS=$(parse_routing "critical" "$TASK_TYPE")
    IFS=',' read -ra CRIT_DIMS_ARRAY <<< "$CRIT_DIMS"
    for dim in "${CRIT_DIMS_ARRAY[@]}"; do
      [ -z "$dim" ] && continue
      subs=$(expand_dimension "$dim")
      if [ -n "$subs" ]; then
        for sub in $subs; do
          script=$(dimension_to_script "$dim" "$sub")
          echo "  [critical] $dim/$sub -> $script"
        done
      else
        script=$(dimension_to_script "$dim" "$dim")
        echo "  [critical] $dim -> $script"
      fi
    done
  fi

  # List or run secondary tier
  if [ -z "$TIER" ] || [ "$TIER" = "secondary" ]; then
    echo "--- Secondary tier ---"
    SEC_DIMS=$(parse_routing "secondary" "$TASK_TYPE")
    IFS=',' read -ra SEC_DIMS_ARRAY <<< "$SEC_DIMS"
    for dim in "${SEC_DIMS_ARRAY[@]}"; do
      [ -z "$dim" ] && continue
      subs=$(expand_dimension "$dim")
      if [ -n "$subs" ]; then
        for sub in $subs; do
          script=$(dimension_to_script "$dim" "$sub")
          echo "  [secondary] $dim/$sub -> $script"
        done
      else
        script=$(dimension_to_script "$dim" "$dim")
        echo "  [secondary] $dim -> $script"
      fi
    done
  fi

  if [ "$MODE" = "list" ]; then
    exit 0
  fi
fi

# ── Single check mode ──────────────────────────────────────────────
if [ "$MODE" = "single" ]; then
  if [ -z "$CHECK_ID" ]; then
    echo "ERROR: --check requires a check ID" >&2
    exit 0
  fi

  # Find the script for this check
  script=$(dimension_to_script "$CHECK_ID" "$CHECK_ID")
  run_check "$CHECK_ID" "$script"
  exit 0
fi

# ── Run mode: collect all checks to run ────────────────────────────
ALL_CHECKS=()
ALL_SCRIPTS=()

# Determine which tiers to run
TIERS=""
if [ -z "$TIER" ] || [ "$TIER" = "critical" ]; then
  TIERS="critical"
fi
if [ -z "$TIER" ] || [ "$TIER" = "secondary" ]; then
  TIERS="$TIERS secondary"
fi

for tier in $TIERS; do
  DIMS=$(parse_routing "$tier" "$TASK_TYPE")
  IFS=',' read -ra DIMS_ARRAY <<< "$DIMS"
  for dim in "${DIMS_ARRAY[@]}"; do
    [ -z "$dim" ] && continue
    subs=$(expand_dimension "$dim")
    if [ -n "$subs" ]; then
      for sub in $subs; do
        script=$(dimension_to_script "$dim" "$sub")
        ALL_CHECKS+=("${dim}/${sub}")
        ALL_SCRIPTS+=("$script")
      done
    else
      script=$(dimension_to_script "$dim" "$dim")
      ALL_CHECKS+=("$dim")
      ALL_SCRIPTS+=("$script")
    fi
  done
done

echo "━━━ Check Runner ━━━"
echo "Feature dir: $FEATURE_DIR"
echo "Task type: $TASK_TYPE"
echo "Tiers: $TIERS"
echo "Checks: ${#ALL_CHECKS[@]}"
echo ""

# ── Launch all checks in parallel ──────────────────────────────────
PIDS=()
for i in "${!ALL_CHECKS[@]}"; do
  run_check "${ALL_CHECKS[$i]}" "${ALL_SCRIPTS[$i]}" &
  PIDS+=($!)
done

# Wait for all checks to complete
CRASHED=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid" 2>/dev/null; then
    CRASHED=$((CRASHED + 1))
  fi
done
[ "$CRASHED" -gt 0 ] && echo "CHECK_RUNNER: $CRASHED check process(es) crashed unexpectedly" >&2

# ── Aggregate results ──────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for check_id in "${ALL_CHECKS[@]}"; do
  result_file="$RESULTS_DIR/${check_id}.result"
  if [ ! -f "$result_file" ]; then
    echo "CHECK $check_id: CRASH (no result file)" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  result=$(head -1 "$result_file" 2>/dev/null || echo "SKIP")
  [ -z "$result" ] && result="SKIP"
  case "$result" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    *) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
done

echo ""
echo "━━━ Results ━━━"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"
echo "SKIP: $SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "CHECK FAILURES DETECTED"
  echo "Review results in: $RESULTS_DIR/"
  for check_id in "${ALL_CHECKS[@]}"; do
    result_file="$RESULTS_DIR/${check_id}.result"
    if [ -f "$result_file" ] && [ "$(head -1 "$result_file")" = "FAIL" ]; then
      echo "  $check_id:"
      cat "$result_file" | tail -n +2 | head -5 | sed 's/^/    /'
    fi
  done
fi

exit 0
