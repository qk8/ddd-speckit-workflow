#!/usr/bin/env bash
# health-dashboard.sh — Project health dashboard for the DDD Speckit Workflow
#
# Usage: scripts/health-dashboard.sh <feature_dir> [--detailed]
#
# Reads existing artifacts and produces a ~30-line terminal-friendly
# health report with a grade (A/B/C/D/F) and weighted scoring.
#
# Bash 3.2 compatible — no jq dependency.

set -euo pipefail

FEATURE_DIR="${1:-}"
DETAILED=false

if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --detailed) DETAILED=true ;;
  esac
  shift
done

if [ -z "$FEATURE_DIR" ]; then
  echo "HEALTH: No feature directory found"
  exit 0
fi

ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
TASKS_FILE="$FEATURE_DIR/tasks.md"

# ── Color support detection ─────────────────────────────────────
if [ -t 1 ] && [ -n "$COLORTERM" ] || [ "$TERM" != "dumb" ]; then
  USE_COLOR=true
else
  USE_COLOR=false
fi

# ── Task progress ───────────────────────────────────────────────
TASK_DONE=0
TASK_IN_PROGRESS=0
TASK_TODO=0
TASK_ABANDONED=0
TASK_BLOCKED=0
TASK_TOTAL=0

if [ -f "$TASKS_FILE" ]; then
  TASK_DONE=$(grep -c 'Status: DONE' "$TASKS_FILE" 2>/dev/null) || TASK_DONE=0
  TASK_IN_PROGRESS=$(grep -c 'Status: IN_PROGRESS' "$TASKS_FILE" 2>/dev/null) || TASK_IN_PROGRESS=0
  TASK_TODO=$(grep -c 'Status: TODO' "$TASKS_FILE" 2>/dev/null) || TASK_TODO=0
  TASK_ABANDONED=$(grep -c 'Status: ABANDONED' "$TASKS_FILE" 2>/dev/null) || TASK_ABANDONED=0
  TASK_BLOCKED=$(grep -c 'Status: BLOCKED' "$TASKS_FILE" 2>/dev/null) || TASK_BLOCKED=0
  TASK_TOTAL=$((TASK_DONE + TASK_IN_PROGRESS + TASK_TODO + TASK_ABANDONED + TASK_BLOCKED))
fi

if [ "$TASK_TOTAL" -gt 0 ]; then
  TASK_PCT=$((TASK_DONE * 100 / TASK_TOTAL))
else
  TASK_PCT=0
fi

# ── Check pass rates ────────────────────────────────────────────
CHECK_PASS=0
CHECK_FAIL=0
CHECK_SKIP=0
CHECK_WARNING=0
CHECK_DETAILS=""

if [ -d "$ARTIFACTS_DIR/check-results" ]; then
  for result_file in "$ARTIFACTS_DIR/check-results"/*.result; do
    [ -f "$result_file" ] || continue
    result=$(cat "$result_file" 2>/dev/null | tr -d '[:space:]' || echo "")
    check_id=$(basename "$result_file" .result)
    case "$result" in
      PASS) CHECK_PASS=$((CHECK_PASS + 1)) ;;
      FAIL) CHECK_FAIL=$((CHECK_FAIL + 1)); CHECK_DETAILS="${CHECK_DETAILS}${check_id}: FAIL" ;;
      WARNING) CHECK_WARNING=$((CHECK_WARNING + 1)) ;;
      SKIPPED|SKIP) CHECK_SKIP=$((CHECK_SKIP + 1)) ;;
      *) ;;
    esac
  done
fi

# ── Error memory ────────────────────────────────────────────────
ERROR_CORRECTIONS=0
ERROR_DRIFT=0
ERROR_FILE="$ARTIFACTS_DIR/error-memory.json"

if [ -f "$ERROR_FILE" ]; then
  ERROR_CORRECTIONS=$(grep -c '"task"' "$ERROR_FILE" 2>/dev/null) || ERROR_CORRECTIONS=0
  ERROR_DRIFT=$(grep -c '"pattern"' "$ERROR_FILE" 2>/dev/null) || ERROR_DRIFT=0
fi

# ── Test health ─────────────────────────────────────────────────
TEST_ALERTS=0
TEST_FILE="$ARTIFACTS_DIR/test-health.json"

if [ -f "$TEST_FILE" ]; then
  # Count alerts in test-health.json using grep
  TEST_ALERTS=$(grep -c '"type"' "$TEST_FILE" 2>/dev/null) || TEST_ALERTS=0
fi

# ── Complexity ──────────────────────────────────────────────────
COMPLEXITY_VIOLATIONS=0
QUALITY_FILE="$ARTIFACTS_DIR/code-quality-results.txt"

if [ -f "$QUALITY_FILE" ]; then
  COMPLEXITY_VIOLATIONS=$(grep -c '^VIOLATION:' "$QUALITY_FILE" 2>/dev/null) || COMPLEXITY_VIOLATIONS=0
fi

# ── Drift ───────────────────────────────────────────────────────
DRIFT_VIOLATIONS=0
DRIFT_FILE="$ARTIFACTS_DIR/post-implementation-drift.md"

if [ -f "$DRIFT_FILE" ]; then
  DRIFT_VIOLATIONS=$(grep -cE 'VIOLATION|DRIFT' "$DRIFT_FILE" 2>/dev/null) || DRIFT_VIOLATIONS=0
fi

# ── Health scoring (0-100) ──────────────────────────────────────
# task_progress: 25% — DONE/total * 25
if [ "$TASK_TOTAL" -gt 0 ]; then
  SCORE_TASK=$((TASK_DONE * 25 / TASK_TOTAL))
else
  SCORE_TASK=0
fi

# check_pass: 20% — pass/(pass+fail) * 20
CHECK_TOTAL=$((CHECK_PASS + CHECK_FAIL))
if [ "$CHECK_TOTAL" -gt 0 ]; then
  SCORE_CHECK=$((CHECK_PASS * 20 / CHECK_TOTAL))
else
  SCORE_CHECK=20
fi

# error_memory: 15% — 15 - (2 * corrections) - (3 * drift), min 0
SCORE_ERROR=$((15 - (2 * ERROR_CORRECTIONS) - (3 * ERROR_DRIFT)))
[ "$SCORE_ERROR" -lt 0 ] && SCORE_ERROR=0

# test_health: 10% — 10 - (2 * alerts), min 0
SCORE_TEST=$((10 - (2 * TEST_ALERTS)))
[ "$SCORE_TEST" -lt 0 ] && SCORE_TEST=0

# complexity: 10% — 10 - (1 * violations), min 0
SCORE_COMPLEXITY=$((10 - COMPLEXITY_VIOLATIONS))
[ "$SCORE_COMPLEXITY" -lt 0 ] && SCORE_COMPLEXITY=0

# drift: 10% — 10 - (3 * violations), min 0
SCORE_DRIFT=$((10 - (3 * DRIFT_VIOLATIONS)))
[ "$SCORE_DRIFT" -lt 0 ] && SCORE_DRIFT=0

# risk: 10% — 10 - (5 * abandoned) - (3 * blocked), min 0
SCORE_RISK=$((10 - (5 * TASK_ABANDONED) - (3 * TASK_BLOCKED)))
[ "$SCORE_RISK" -lt 0 ] && SCORE_RISK=0

# Total score
TOTAL_SCORE=$((SCORE_TASK + SCORE_CHECK + SCORE_ERROR + SCORE_TEST + SCORE_COMPLEXITY + SCORE_DRIFT + SCORE_RISK))

# ── Grade calculation ───────────────────────────────────────────
if [ "$TOTAL_SCORE" -ge 85 ]; then
  GRADE="A"
elif [ "$TOTAL_SCORE" -ge 70 ]; then
  GRADE="B"
elif [ "$TOTAL_SCORE" -ge 55 ]; then
  GRADE="C"
elif [ "$TOTAL_SCORE" -ge 40 ]; then
  GRADE="D"
else
  GRADE="F"
fi

# Override rules
# Any critical check (A, BC, D, I, L, Z, AS) FAIL → minimum D
for critical_check in A BC D I L Z AS; do
  if [ -f "$ARTIFACTS_DIR/check-results/${critical_check}.result" ]; then
    cr=$(cat "$ARTIFACTS_DIR/check-results/${critical_check}.result" 2>/dev/null | tr -d '[:space:]' || echo "")
    if [ "$cr" = "FAIL" ]; then
      if [ "$GRADE" = "A" ] || [ "$GRADE" = "B" ]; then
        GRADE="D"
        TOTAL_SCORE=40
      fi
    fi
  fi
done

# > 3 abandoned tasks → minimum F
if [ "$TASK_ABANDONED" -gt 3 ]; then
  GRADE="F"
  TOTAL_SCORE=0
fi

# ── Output ──────────────────────────────────────────────────────
if [ "$USE_COLOR" = true ]; then
  # Color by grade
  case "$GRADE" in
    A) GRADE_COLOR="\033[32m" ;; # green
    B) GRADE_COLOR="\033[32m" ;; # green
    C) GRADE_COLOR="\033[33m" ;; # yellow
    D) GRADE_COLOR="\033[33m" ;; # yellow
    F) GRADE_COLOR="\033[31m" ;; # red
  esac
  RESET="\033[0m"
else
  GRADE_COLOR=""
  RESET=""
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  PROJECT HEALTH: Grade ${GRADE_COLOR}${GRADE}${RESET} (${TOTAL_SCORE}/100)       ║"
echo "╠══════════════════════════════════════════════╣"
printf "║  TASKS:  %-3d/%-3d DONE (%2d%%)          ║\n" "$TASK_DONE" "$TASK_TOTAL" "$TASK_PCT"
echo "║           ${TASK_IN_PROGRESS} IN_PROGRESS | ${TASK_TODO} TODO        ║"
echo "║                                          ║"
printf "║  CHECKS: %-3d PASS | %-3d FAIL | %-3d SKIP  ║\n" "$CHECK_PASS" "$CHECK_FAIL" "$CHECK_SKIP"
if [ -n "$CHECK_DETAILS" ]; then
  echo "║           ${CHECK_DETAILS}    ║"
fi
echo "║                                          ║"
printf "║  ERRORS: %-3d corrections, %-3d drift         ║\n" "$ERROR_CORRECTIONS" "$ERROR_DRIFT"
if [ "$TEST_ALERTS" -eq 0 ]; then
  echo "║  TESTS:  Healthy                         ║"
else
  echo "║  TESTS:  ${TEST_ALERTS} alert(s) | Degraded            ║"
fi
printf "║  COMPLEXITY: %-3d violations               ║\n" "$COMPLEXITY_VIOLATIONS"
if [ "$DRIFT_VIOLATIONS" -eq 0 ]; then
  echo "║  DRIFT:  Clean                           ║"
else
  echo "║  DRIFT:  ${DRIFT_VIOLATIONS} violation(s)                   ║"
fi
echo "║                                          ║"
printf "║  RISKS:  %-3d abandoned, %-3d blocked, stagnation  ║\n" "$TASK_ABANDONED" "$TASK_BLOCKED"
echo "╚══════════════════════════════════════════════╝"

# ── Detailed mode ───────────────────────────────────────────────
if [ "$DETAILED" = true ]; then
  echo ""
  echo "── Detailed Breakdown ──"
  echo "  Score: task=$SCORE_TASK/25 check=$SCORE_CHECK/20 error=$SCORE_ERROR/15"
  echo "         test=$SCORE_TEST/10 complexity=$SCORE_COMPLEXITY/10 drift=$SCORE_DRIFT/10 risk=$SCORE_RISK/10"
  echo ""

  # Per-check breakdown
  if [ -d "$ARTIFACTS_DIR/check-results" ]; then
    echo "  Check results:"
    for result_file in "$ARTIFACTS_DIR/check-results"/*.result; do
      [ -f "$result_file" ] || continue
      result=$(cat "$result_file" 2>/dev/null | tr -d '[:space:]' || echo "")
      check_id=$(basename "$result_file" .result)
      printf "    [%s] %-4s %s\n" "$check_id" "$result" ""
    done
  fi

  # Error memory details
  if [ -f "$ERROR_FILE" ]; then
    echo ""
    echo "  Error memory entries:"
    awk '
      /"task"/ {
        gsub(/.*"task"[[:space:]]*:[[:space:]]*"/, "")
        gsub(/".*/, "")
        task = $0
      }
      /"type"/ {
        gsub(/.*"type"[[:space:]]*:[[:space:]]*"/, "")
        gsub(/".*/, "")
        type = $0
      }
      /"description"/ {
        gsub(/.*"description"[[:space:]]*:[[:space:]]*"/, "")
        gsub(/".*/, "")
        desc = $0
        print "    TASK-" task ": " type " — " desc
      }
    ' "$ERROR_FILE" 2>/dev/null | head -10
  fi
fi

echo ""
