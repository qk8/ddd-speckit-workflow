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

# ── Source dimension lookup library (single source of truth) ────────
source "$SCRIPTS_DIR/check-dimensions.sh"

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
          script=$(check_script "${dim}/${sub}")
          echo "  [critical] $dim/$sub -> $script"
        done
      else
        script=$(check_script "$dim")
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
          script=$(check_script "${dim}/${sub}")
          echo "  [secondary] $dim/$sub -> $script"
        done
      else
        script=$(check_script "$dim")
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
  script=$(check_script "$CHECK_ID")
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
        script=$(check_script "${dim}/${sub}")
        ALL_CHECKS+=("${dim}/${sub}")
        ALL_SCRIPTS+=("$script")
      done
    else
      script=$(check_script "$dim")
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
