#!/usr/bin/env bash
# check-runner-v2.sh — Dimension-based check execution engine
#
# Usage: scripts/check-runner-v2.sh <feature_dir> <task_type> [--tier critical|secondary]
#
# Replaces check-runner.sh with consolidated dimension-based checks.
# Dimensions are expanded into sub-checks at runtime.
#
# 8 Dimensions:
#   test_execution    → BC  (regression, new_tests)
#   code_quality      → D, V (lint, complexity, naming)
#   spec_compliance   → L, Z, AS (drift, constraints, api_surface)
#   security          → I, O, U (secret_scan, owasp, session_security)
#   test_design       → P, M, NT (test_quality, failure_modes, negative_tests)
#   integration       → A, K, F, N (arch_tests, contract, migration, crosscutting)
#   resilience        → Q, T (resilience_testing, adversarial)
#   performance       → J, R (performance_budget, quantitative)
#
# Standalone: E, G, H, AC (no sub-checks)
#
# Phases:
#   1. Parse task type, derive applicable dimensions from routing table
#   2. Expand dimensions into sub-checks
#   3. Run all sub-checks in parallel
#   4. Collect results to .artifacts/check-results/<check-id>.result
#   5. Report PASS/FAIL per sub-check
#   6. Exit 0 if all pass, 1 if any critical fails

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-runner-v2.sh <feature_dir> <task_type> [--tier critical|secondary]}"
TASK_TYPE="${2:?Usage: check-runner-v2.sh <feature_dir> <task_type> [--tier critical|secondary]}"
TIER="${3:-critical}"

PRESET_FILE="$(cd "$(dirname "$0")/../ddd-clean-arch" && pwd)/preset.yml"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
RESULTS_DIR="$ARTIFACTS_DIR/check-results"
mkdir -p "$RESULTS_DIR"

# ── Lock file management for parallel safety ──────────────────────
LOCK_DIR="$RESULTS_DIR/.locks"
mkdir -p "$LOCK_DIR"
cleanup_locks() { rm -rf "$LOCK_DIR"; }
trap cleanup_locks EXIT INT TERM

# ── Parse routing table from preset.yml ─────────────────────────
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

APPLICABLE_CHECKS=$(parse_routing_table "$TIER")

if [ -z "$APPLICABLE_CHECKS" ]; then
  echo "CHECK_RUNNER_V2: no applicable checks for task_type='$TASK_TYPE' tier='$TIER'"
  exit 0
fi

IFS=',' read -ra CHECK_IDS <<< "$APPLICABLE_CHECKS"

# ── Legacy check ID → dimension alias mapping ────────────────────
# Old check IDs map to dimension IDs for backward compatibility.
resolve_alias() {
  case "$1" in
    A) echo "integration" ;;
    AC) echo "AC" ;;
    AS) echo "spec_compliance" ;;
    BC) echo "test_execution" ;;
    D) echo "code_quality" ;;
    E) echo "E" ;;
    F) echo "integration" ;;
    G) echo "G" ;;
    H) echo "H" ;;
    I) echo "security" ;;
    J) echo "performance" ;;
    K) echo "integration" ;;
    L) echo "spec_compliance" ;;
    M) echo "test_design" ;;
    N) echo "integration" ;;
    NT) echo "test_design" ;;
    O) echo "security" ;;
    P) echo "test_design" ;;
    Q) echo "resilience" ;;
    R) echo "performance" ;;
    S) echo "S" ;;
    T) echo "resilience" ;;
    U) echo "security" ;;
    V) echo "code_quality" ;;
    S) echo "test_design" ;;
    W) echo "_unknown_" ;;
    Z) echo "spec_compliance" ;;
    *) echo "$1" ;;
  esac
}

# ── Get check name ──────────────────────────────────────────────
get_check_name() {
  local check_id="$1"
  local resolved
  resolved=$(resolve_alias "$check_id")

  # Try dimension first, then legacy check
  local name
  name=$(awk -v id="$resolved" '
    $0 ~ ("^  " id ":") { found=1; next }
    found && /^    name:/ { gsub(/.*name:[ ]*"?/, ""); gsub(/"/, ""); print; exit }
    found && /^[^ ]/ { exit }
  ' "$PRESET_FILE" 2>/dev/null)

  if [ -n "$name" ]; then
    echo "$name"
  else
    echo "$resolved"
  fi
}

# ── Expand dimension into sub-check IDs ──────────────────────────
expand_dimension() {
  local check_id="$1"
  awk -v id="$check_id" '
    $0 ~ ("^  " id ":") { found=1; next }
    found && /sub_checks:/ { in_sub=1; next }
    in_sub && /^    [a-z]/ {
      sub(/:.*/, "", $0)
      gsub(/[[:space:]]/, "", $0)
      if ($0 != "") print $0
      next
    }
    in_sub && /^[^ ]/ { exit }
    found && /^[^ ]/ { exit }
  ' "$PRESET_FILE" 2>/dev/null || true
}

# ── Get sub-check script ────────────────────────────────────────
get_sub_check_script() {
  local check_id="$1" sub="$2"
  awk -v id="$check_id" -v sub="$sub" '
    $0 ~ ("^  " id ":") { found=1; next }
    found && /sub_checks:/ { in_sub=1; next }
    in_sub && ("^    " sub ":") { in_sc=1; next }
    in_sc && /script:/ { gsub(/.*script:[ ]*"/, ""); gsub(/".*/, ""); print; exit }
    in_sc && /^[^ ]/ { exit }
    in_sub && /^[^ ]/ { in_sub=0 }
    found && /^[^ ]/ { exit }
  ' "$PRESET_FILE" 2>/dev/null || true
}

# ── Get check tier ──────────────────────────────────────────────
get_check_tier() {
  local check_id="$1"
  awk -v id="$check_id" '
    $0 ~ ("^  " id ":") { found=1; next }
    found && /tier:/ { gsub(/.*tier:[ ]*"/, ""); gsub(/".*/, ""); print; exit }
    found && /^[^ ]/ { exit }
  ' "$PRESET_FILE" 2>/dev/null || echo "tertiary"
}

# ── Expand all checks into sub-checks ───────────────────────────
ALL_SUB_CHECKS=()
CHECK_NAMES=()

for check_id in "${CHECK_IDS[@]}"; do
  resolved=$(resolve_alias "$check_id")

  # Skip unknown aliases (e.g. W — unmapped check ID)
  if [ "$resolved" = "_unknown_" ]; then
    echo "WARN: Unknown check ID '$check_id', skipping" >&2
    continue
  fi

  name=$(get_check_name "$check_id")
  CHECK_NAMES+=("$name")

  # Check if it's a dimension (has sub_checks)
  subs=$(expand_dimension "$resolved")
  if [ -n "$subs" ]; then
    while IFS= read -r sub; do
      ALL_SUB_CHECKS+=("${resolved}/${sub}")
    done <<< "$subs"
  else
    ALL_SUB_CHECKS+=("$resolved")
  fi
done

# Sort sub-checks for deterministic parallel launch order (Fix 11)
if [ "${#ALL_SUB_CHECKS[@]}" -gt 0 ]; then
  IFS=$'\n' ALL_SUB_CHECKS=($(sort -u <<<"${ALL_SUB_CHECKS[*]}")); unset IFS
fi

echo "━━━ Check Runner V2 ━━━"
echo "Task type: $TASK_TYPE"
echo "Tier: $TIER"
echo "Dimensions: ${CHECK_IDS[*]}"
echo "Sub-checks: ${#ALL_SUB_CHECKS[@]}"
echo "Results dir: $RESULTS_DIR"
echo ""

# ── Atomic result write with flock (Fix 1: race condition) ───────
# Usage: write_result <result_file> <value>
# Writes result atomically using flock to prevent parallel race conditions.
write_result() {
  local result_file="$1" value="$2"
  local lock_file="$LOCK_DIR/$(echo "$result_file" | tr '/' '_').lock"
  (
    flock -w 30 200 || { echo "FLOCK_TIMEOUT: $result_file" >&2; return 1; }
    echo "$value" > "$result_file"
  ) 200>"$lock_file"
}

# ── Run a single sub-check ─────────────────────────────────────
run_sub_check() {
  local full_id="$1"
  local dimension="${full_id%%/*}"
  local sub="${full_id##*/}"
  local result_file="$RESULTS_DIR/${dimension}_${sub}.result"

  # If dimension == sub (not a real sub-check), use dimension as both
  if [ "$dimension" = "$sub" ]; then
    sub=""
  fi

  local script_name
  if [ -n "$sub" ]; then
    script_name=$(get_sub_check_script "$dimension" "$sub")
  else
    # For standalone checks (E, G, H, AC), try dimension name as script
    script_name=$(get_sub_check_script "$dimension" "$dimension")
  fi

  if [ -z "$script_name" ]; then
    write_result "$result_file" "SKIP"
    echo "CHECK $full_id: SKIP (no deterministic script)"
    return
  fi

  local script_path
  script_path="$(cd "$(dirname "$0")" && pwd)/$script_name"

  if [ ! -f "$script_path" ]; then
    # Check if this dimension is in the critical routing
    local is_critical=false
    local crit_checks
    crit_checks=$(parse_routing_table "critical")
    IFS=',' read -ra CRIT_IDS <<< "$crit_checks"
    for cid in "${CRIT_IDS[@]}"; do
      if [ "$(resolve_alias "$cid")" = "$dimension" ]; then
        is_critical=true
        break
      fi
    done

    if [ "$is_critical" = true ]; then
      write_result "$result_file" "FAIL"
      echo "CHECK $full_id: FAIL (critical-tier script $script_name not found)" >&2
    else
      write_result "$result_file" "SKIP"
      echo "CHECK $full_id: SKIP ($script_name not found)"
    fi
    return
  fi

  local output
  local exit_code=0
  output=$(bash "$script_path" "$FEATURE_DIR" 2>&1) || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    write_result "$result_file" "PASS"
    echo "CHECK $full_id: PASS"
  else
    write_result "$result_file" "FAIL"
    echo "CHECK $full_id: FAIL (exit $exit_code)" >&2
    echo "--- Output ---" >> "$result_file"
    echo "$output" >> "$result_file"
  fi
}

# ── Launch all sub-checks in parallel ───────────────────────────
PIDS=()

for sub_id in "${ALL_SUB_CHECKS[@]}"; do
  run_sub_check "$sub_id" &
  PIDS+=($!)
done

# Wait for all checks to complete
CRASHED=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    CRASHED=$((CRASHED + 1))
  fi
done
[ "$CRASHED" -gt 0 ] && echo "CHECK_RUNNER_V2: $CRASHED check process(es) crashed unexpectedly" >&2

# ── Aggregate results ──────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

for sub_id in "${ALL_SUB_CHECKS[@]}"; do
  dimension="${sub_id%%/*}"
  sub="${sub_id##*/}"
  result_file="$RESULTS_DIR/${dimension}_${sub}.result"

  if [ ! -f "$result_file" ]; then
    echo "CHECK $sub_id: CRASH (no result file)" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  # Read result atomically (flock ensures writes are complete after wait)
  result=$(head -1 "$result_file" 2>/dev/null || echo "SKIP")
  # Guard against empty result (shouldn't happen with flock, but be safe)
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
  if [ "$TIER" = "critical" ]; then
    echo "CRITICAL CHECK FAILURES DETECTED"
  else
    echo "SECONDARY CHECK FAILURES DETECTED"
  fi
  echo "Review results in: $RESULTS_DIR/"
  for sub_id in "${ALL_SUB_CHECKS[@]}"; do
    dimension="${sub_id%%/*}"
    sub="${sub_id##*/}"
    result_file="$RESULTS_DIR/${dimension}_${sub}.result"
    if [ -f "$result_file" ] && [ "$(head -1 "$result_file")" = "FAIL" ]; then
      echo "  $sub_id:"
      cat "$result_file" | tail -n +2 | head -5 | sed 's/^/    /'
    fi
  done
  exit 1
fi

echo ""
echo "All $TIER checks passed."
exit 0
