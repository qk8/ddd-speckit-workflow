#!/usr/bin/env bash
# check-runner.sh — Deterministic check execution engine
#
# Usage: scripts/check-runner.sh <feature_dir> <task_type> [--batch]
#
# Replaces Claude's check execution with structured, parallel check runner.
#
# Phases:
#   1. Parse task type, derive applicable checks from preset.yml routing table
#   2. Run all deterministic checks in parallel (background processes)
#   3. Collect results to .artifacts/check-results/<check-id>.result
#   4. Report PASS/FAIL per check
#   5. Exit 0 if all pass, 1 if any critical fails
#
# Deterministic checks:
#   A:  scripts/run-arch-tests.sh
#   BC: scripts/run-regression.sh
#   D:  scripts/run-lint.sh
#   E:  scripts/run-dep-scan.sh
#   F:  scripts/run-migration-test.sh
#   I:  scripts/secret-scan.sh  (already exists)
#   K:  scripts/validate-api-contract.sh  (already exists)
#   L:  scripts/run-antihallucination.sh
#   R:  scripts/run-quantitative.sh
#   Z:  scripts/quick-drift-check.sh  (already exists)
#   AS: scripts/api-surface-check.sh   (cross-task API consistency)
#   AC: scripts/verify-acceptance-coverage.sh  (acceptance criteria test coverage)
#   V:  scripts/verify-code-quality.sh        (code complexity gates)
#   W:  scripts/verify-concurrency.sh         (concurrency & transaction safety)
#
# Non-deterministic (stay as Claude prompts): G, H, J, M, N, O, P, Q, S, T, U, Z(full)

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-runner.sh <feature_dir> <task_type> [--batch] [--changed-only]}"
TASK_TYPE="${2:?Usage: check-runner.sh <feature_dir> <task_type> [--batch] [--changed-only]}"
BATCH_MODE=false
if [ "${3:-}" = "--batch" ]; then
  BATCH_MODE=true
fi

CHANGED_ONLY=false
if [ "${3:-}" = "--changed-only" ] || [ "${4:-}" = "--changed-only" ]; then
  CHANGED_ONLY=true
fi
if [ "${4:-}" = "--changed-only" ] && [ "${3:-}" != "--batch" ]; then
  CHANGED_ONLY=true
fi
# Handle --batch --changed-only or --changed-only --batch order
if [ "${3:-}" = "--changed-only" ]; then
  CHANGED_ONLY=true
fi
if [ "${4:-}" = "--batch" ]; then
  BATCH_MODE=true
fi

PRESET_FILE="$(cd "$(dirname "$0")/../ddd-clean-arch" && pwd)/preset.yml"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
RESULTS_DIR="$ARTIFACTS_DIR/check-results"
mkdir -p "$RESULTS_DIR"

# ── Parse routing table from preset.yml ─────────────────────────
# Extract the routing_critical or routing_secondary table for the given task_type
parse_routing_table() {
  local tier="${1:-critical}"
  local table_name="routing_${tier}"

  awk -v table="$table_name" -v ttype="$TASK_TYPE" '
    $0 ~ ("^" table ":") { in_table=1; next }
    in_table && /^[a-zA-Z]/ { exit }
    in_table && $0 ~ "[[:space:]]*" ttype ":" {
      s=$0
      sub(/.*\[/, "", s)
      sub(/\].*/, "", s)
      gsub(/[[:space:]]/, "", s)
      print s
    }
  ' "$PRESET_FILE"
}

# Get applicable checks (critical tier = every task)
APPLICABLE_CHECKS=$(parse_routing_table "critical")

if [ -z "$APPLICABLE_CHECKS" ]; then
  echo "CHECK_RUNNER: no applicable checks for task_type='$TASK_TYPE'"
  exit 0
fi

# Split comma-separated check IDs into array
IFS=',' read -ra CHECK_IDS <<< "$APPLICABLE_CHECKS"

echo "━━━ Check Runner ━━━"
echo "Task type: $TASK_TYPE"
echo "Applicable checks: ${CHECK_IDS[*]}"
echo "Results dir: $RESULTS_DIR"
echo ""

# ── Check script mapping (bash 3.2 compatible — no associative arrays) ──
get_check_script() {
  case "$1" in
    A)              echo "run-arch-tests.sh" ;;
    BC)             echo "run-regression.sh" ;;
    D)              echo "run-lint.sh" ;;
    E)              echo "run-dep-scan.sh" ;;
    F)              echo "run-migration-test.sh" ;;
    I)              echo "secret-scan.sh" ;;
    K)              echo "validate-api-contract.sh" ;;
    L)              echo "run-antihallucination.sh" ;;
    R)              echo "run-quantitative.sh" ;;
    Z)              echo "quick-drift-check.sh" ;;
    AS)             echo "api-surface-check.sh" ;;
    AC)             echo "verify-acceptance-coverage.sh" ;;
    V)              echo "verify-code-quality.sh" ;;
    W)              echo "verify-concurrency.sh" ;;
    *)              echo "" ;;
  esac
}

# ── Run checks in parallel ─────────────────────────────────────
PIDS=()

run_check() {
  local check_id="$1"
  local script_name
  script_name=$(get_check_script "$check_id")
  local result_file="$RESULTS_DIR/${check_id}.result"

  if [ -z "$script_name" ]; then
    echo "CHECK $check_id: SKIP (no deterministic script)" > "$result_file"
    return
  fi

  local script_path
  script_path="$(cd "$(dirname "$0")" && pwd)/$script_name"

  if [ ! -f "$script_path" ]; then
    # Determine if this is a critical-tier check by checking if it's in
    # the applicable (critical) checks list. Critical checks that are missing
    # their scripts FAIL — they cannot be silently skipped.
    local is_critical=false
    for cid in "${CHECK_IDS[@]}"; do
      if [ "$cid" = "$check_id" ]; then
        is_critical=true
        break
      fi
    done
    if [ "$is_critical" = true ]; then
      echo "FAIL" > "$result_file"
      echo "CHECK $check_id: FAIL (critical-tier script $script_name not found)" >&2
    else
      echo "SKIP" > "$result_file"
      echo "CHECK $check_id: SKIP ($script_name not found)"
    fi
    return
  fi

  # Execute the check script, capture output and exit code
  local output
  local exit_code=0
  if [ "$check_id" = "BC" ] && [ "$CHANGED_ONLY" = true ]; then
    output=$(bash "$script_path" --changed-only "$FEATURE_DIR" 2>&1) || exit_code=$?
  else
    output=$(bash "$script_path" "$FEATURE_DIR" 2>&1) || exit_code=$?
  fi

  if [ "$exit_code" -eq 0 ]; then
    echo "PASS" > "$result_file"
    echo "CHECK $check_id: PASS"
  else
    echo "FAIL" > "$result_file"
    echo "CHECK $check_id: FAIL (exit $exit_code)" >&2
    # Append output to result file for debugging
    echo "--- Output ---" >> "$result_file"
    echo "$output" >> "$result_file"
  fi
}

# Launch all checks in parallel
for check_id in "${CHECK_IDS[@]}"; do
  run_check "$check_id" &
  PIDS+=($!)
done

# Wait for all checks to complete and collect results
CRASHED=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    CRASHED=$((CRASHED + 1))
  fi
done
[ "$CRASHED" -gt 0 ] && echo "CHECK RUNNER: $CRASHED check process(es) crashed unexpectedly" >&2

# ── Aggregate results ──────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for check_id in "${CHECK_IDS[@]}"; do
  result_file="$RESULTS_DIR/${check_id}.result"
  if [ ! -f "$result_file" ]; then
    echo "CHECK $check_id: CRASH (no result file)" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  result=$(head -1 "$result_file")
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
  echo "CRITICAL CHECK FAILURES DETECTED"
  echo "Review results in: $RESULTS_DIR/"
  for check_id in "${CHECK_IDS[@]}"; do
    result_file="$RESULTS_DIR/${check_id}.result"
    if [ -f "$result_file" ] && [ "$(head -1 "$result_file")" = "FAIL" ]; then
      echo "  $check_id:"
      cat "$result_file" | tail -n +2 | head -5 | sed 's/^/    /'
    fi
  done
  exit 1
fi

echo ""
echo "All deterministic checks passed."
exit 0
