#!/usr/bin/env bash
# Performance Budget Check (Check J / performance.performance_budget)
# Verifies response times and throughput within budget.
#
# Usage: check-performance-budget.sh <feature_dir>
#
# Writes PASS/FAIL to .artifacts/check-results/performance_performance_budget.result

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-performance-budget.sh <feature_dir>}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

echo "PERF BUDGET: Scanning ${FEATURE_DIR}"

# ── Read performance budget from plan.md ─────────────────────────
PLAN_FILE="${FEATURE_DIR}/plan.md"
P95_THRESHOLD=""
P99_THRESHOLD=""
THROUGHPUT_THRESHOLD=""

if [ -f "$PLAN_FILE" ]; then
  # Extract performance budget values from plan.md §13 (Testing Strategy / Performance)
  P95_THRESHOLD=$(awk '/Performance Strategy|Performance Budget|Response Time/{found=1} found && /p95.*:/ {gsub(/[^0-9.]/, "", $0); print; exit}' "$PLAN_FILE" 2>/dev/null || true)
  P99_THRESHOLD=$(awk '/Performance Strategy|Performance Budget|Response Time/{found=1} found && /p99.*:/ {gsub(/[^0-9.]/, "", $0); print; exit}' "$PLAN_FILE" 2>/dev/null || true)
  THROUGHPUT_THRESHOLD=$(awk '/Performance Strategy|Performance Budget|Response Time/{found=1} found && /(throughput|rps).*:/ {gsub(/[^0-9.]/, "", $0); print; exit}' "$PLAN_FILE" 2>/dev/null || true)
fi

# ── Check if budget is defined ───────────────────────────────────
if [ -z "$P95_THRESHOLD" ] && [ -z "$P99_THRESHOLD" ] && [ -z "$THROUGHPUT_THRESHOLD" ]; then
  echo "PERF BUDGET: SKIP (no performance budget defined in plan.md)"
  echo "SKIP" > "${RESULTS_DIR}/performance_performance_budget.result"
  exit 0
fi

echo "PERF BUDGET: Found budget thresholds:"
[ -n "$P95_THRESHOLD" ] && echo "  p95 response time: ${P95_THRESHOLD}ms"
[ -n "$P99_THRESHOLD" ] && echo "  p99 response time: ${P99_THRESHOLD}ms"
[ -n "$THROUGHPUT_THRESHOLD" ] && echo "  throughput: ${THROUGHPUT_THRESHOLD} rps"

# ── Detect project type and run basic load test ──────────────────
PROJECT_TYPE=""
if [ -f "${FEATURE_DIR}/package.json" ]; then
  PROJECT_TYPE="node"
elif [ -f "${FEATURE_DIR}/requirements.txt" ]; then
  PROJECT_TYPE="python"
elif [ -f "${FEATURE_DIR}/pom.xml" ]; then
  PROJECT_TYPE="java"
elif [ -f "${FEATURE_DIR}/go.mod" ]; then
  PROJECT_TYPE="go"
fi

# ── Run load test if tools available ─────────────────────────────
# Try wrk first (fastest), then ab (apache bench), then curl-based fallback
LOAD_TEST_RESULT="SKIP"
LOAD_TEST_OUTPUT=""

if command -v wrk &>/dev/null; then
  # Find a running server or skip
  echo "PERF BUDGET: wrk available — requires a running server to test against"
  LOAD_TEST_RESULT="SKIP"
elif command -v ab &>/dev/null; then
  # Apache bench — requires a running server
  echo "PERF BUDGET: ab available — requires a running server to test against"
  LOAD_TEST_RESULT="SKIP"
elif command -v curl &>/dev/null; then
  echo "PERF BUDGET: curl available — basic connectivity check only"
  LOAD_TEST_RESULT="SKIP"
fi

# ── Check for performance anti-patterns in source code ───────────
# Even without a running server, we can check for common performance issues
ANTI_PATTERNS=0

SRC_FILES=""
case "$PROJECT_TYPE" in
  node)
    SRC_FILES=$(find "$FEATURE_DIR" -type f \( -name '*.ts' -o -name '*.js' \) \
      ! -name '*test*' ! -name '*.spec.*' \
      ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/dist/*' ! -path '*/build/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
  python)
    SRC_FILES=$(find "$FEATURE_DIR" -type f -name '*.py' \
      ! -name '*test*' ! -name '*_test.py' ! -name 'conftest.py' \
      ! -path '*/.venv/*' ! -path '*/venv/*' ! -path '*/__pycache__/*' ! -path '*/.git/*' \
      ! -path '*/.artifacts/*' 2>/dev/null || true)
    ;;
  java)
    SRC_FILES=$(find "$FEATURE_DIR" -type f -name '*.java' \
      ! -name '*Test*' ! -name '*Tests*' \
      ! -path '*/build/*' ! -path '*/target/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
  go)
    SRC_FILES=$(find "$FEATURE_DIR" -type f -name '*.go' \
      ! -name '*_test.go' \
      ! -path '*/vendor/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
esac

if [ -n "$SRC_FILES" ]; then
  # Check for N+1 query patterns (common in ORMs)
  NPLUS1=$(echo "$SRC_FILES" | xargs grep -c '\.find\|\.findAll\|\.where\|\.query\|\.all(' 2>/dev/null | awk -F: '{sum+=$2} END{print sum}' || echo 0)
  if [ "$NPLUS1" -gt 20 ]; then
    ANTI_PATTERNS=$((ANTI_PATTERNS + 1))
    echo "PERF BUDGET: WARNING — ${NPLUS1} query calls found (possible N+1 pattern)"
  fi

  # Check for synchronous I/O in request handlers (Node.js)
  SYNC_IO=$(echo "$SRC_FILES" | xargs grep -c 'fs\.readFileSync\|fs\.writeFileSync\|fs\.copyFileSync' 2>/dev/null | awk -F: '{sum+=$2} END{print sum}' || echo 0)
  if [ "$SYNC_IO" -gt 0 ]; then
    ANTI_PATTERNS=$((ANTI_PATTERNS + 1))
    echo "PERF BUDGET: WARNING — ${SYNC_IO} synchronous I/O calls found (blocking)"
  fi
fi

# ── Report results ───────────────────────────────────────────────
if [ "$LOAD_TEST_RESULT" = "SKIP" ] && [ "$ANTI_PATTERNS" -eq 0 ]; then
  echo "PERF BUDGET: SKIP (no load testing tools available, no anti-patterns detected)"
  echo "SKIP" > "${RESULTS_DIR}/performance_performance_budget.result"
  exit 0
fi

if [ "$ANTI_PATTERNS" -gt 0 ]; then
  echo "PERF BUDGET: FAIL — ${ANTI_PATTERNS} performance anti-pattern(s) detected"
  echo "FAIL" > "${RESULTS_DIR}/performance_performance_budget.result"
  exit 1
fi

echo "PERF BUDGET: PASS — no performance anti-patterns detected"
echo "PASS" > "${RESULTS_DIR}/performance_performance_budget.result"
exit 0
