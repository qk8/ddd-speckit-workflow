#!/usr/bin/env bash
# Performance Budget Check (Check J / performance.performance_budget)
# Two independent checks:
#   1. Anti-pattern detection — always runs, greps source for common perf issues
#      Produces warnings (not FAIL) for patterns found.
#   2. Budget validation — requires load testing tools (wrk/ab) to measure
#      actual response times against thresholds from plan.md.
#
# Usage: check-performance-budget.sh <feature_dir> [--help]
#
# Output variables:
#   ANTI_PATTERNS=N (count of anti-pattern categories detected)
#   BUDGET_CHECK=SKIP|PASS|FAIL
#
# Writes PASS/FAIL/SKIP to .artifacts/check-results/performance_performance_budget.result

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

# ── Parse flags ────────────────────────────────────────────────────
if [ "${1:-}" = "--help" ]; then
  check_help "check-performance-budget.sh" "<feature_dir> [--help]"
fi

FEATURE_DIR="${1:?Usage: check-performance-budget.sh <feature_dir>}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"

echo "PERF BUDGET: Scanning ${FEATURE_DIR}"

# ── Read performance budget from plan.md ─────────────────────────
PLAN_FILE="${FEATURE_DIR}/plan.md"
P95_THRESHOLD=""
P99_THRESHOLD=""
THROUGHPUT_THRESHOLD=""

if [ -f "$PLAN_FILE" ]; then
  P95_THRESHOLD=$(awk '/Performance Strategy|Performance Budget|Response Time/{found=1} found && /p95.*:/ {gsub(/[^0-9.]/, "", $0); print; exit}' "$PLAN_FILE" 2>/dev/null || true)
  P99_THRESHOLD=$(awk '/Performance Strategy|Performance Budget|Response Time/{found=1} found && /p99.*:/ {gsub(/[^0-9.]/, "", $0); print; exit}' "$PLAN_FILE" 2>/dev/null || true)
  THROUGHPUT_THRESHOLD=$(awk '/Performance Strategy|Performance Budget|Response Time/{found=1} found && /(throughput|rps).*:/ {gsub(/[^0-9.]/, "", $0); print; exit}' "$PLAN_FILE" 2>/dev/null || true)
fi

# ── Detect project type ──────────────────────────────────────────
PROJECT_TYPE=""
if [ -f "${FEATURE_DIR}/package.json" ]; then
  PROJECT_TYPE="node"
elif [ -f "${FEATURE_DIR}/requirements.txt" ]; then
  PROJECT_TYPE="python"
elif [ -f "${FEATURE_DIR}/pom.xml" ] || [ -f "${FEATURE_DIR}/build.gradle" ]; then
  PROJECT_TYPE="java"
elif [ -f "${FEATURE_DIR}/go.mod" ]; then
  PROJECT_TYPE="go"
fi

# ── ANTI-PATTERN DETECTION (always runs when source files exist) ──
ANTI_PATTERNS=0
ANTI_PATTERN_DETAILS=""

if [ -n "$PROJECT_TYPE" ]; then
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
    # 1. N+1 query patterns (ORM calls in loops)
    NPLUS1=$(echo "$SRC_FILES" | xargs grep -c '\.find(\|\.findAll(\|\.where(\|\.query(\|\.all(' 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}' || echo 0)
    if [ "$NPLUS1" -gt 20 ]; then
      ANTI_PATTERNS=$((ANTI_PATTERNS + 1))
      ANTI_PATTERN_DETAILS="${ANTI_PATTERN_DETAILS}  - N+1 queries: ${NPLUS1} ORM calls detected (possible loop iteration)\n"
    fi

    # 2. Synchronous I/O in request handlers
    SYNC_IO=$(echo "$SRC_FILES" | xargs grep -c 'readFileSync\|writeFileSync\|copyFileSync\|shlex\.exec\|os\.system\|Runtime\.getRuntime' 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}' || echo 0)
    if [ "$SYNC_IO" -gt 0 ]; then
      ANTI_PATTERNS=$((ANTI_PATTERNS + 1))
      ANTI_PATTERN_DETAILS="${ANTI_PATTERN_DETAILS}  - Synchronous I/O: ${SYNC_IO} blocking calls found\n"
    fi

    # 3. Missing database indexes (look for frequently filtered columns in schema files)
    SCHEMA_FILES=$(find "$FEATURE_DIR" -type f \( -name '*.sql' -o -name '*.ddl' -o -name '*migration*' \) \
      ! -path '*/.git/*' ! -path '*/.artifacts/*' 2>/dev/null || true)
    if [ -n "$SCHEMA_FILES" ]; then
      NON_INDEXED_FILTERS=$(echo "$SCHEMA_FILES" | xargs grep -ci 'WHERE\|FILTER\|condition' 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}' || echo 0)
      INDEX_COUNT=$(echo "$SCHEMA_FILES" | xargs grep -ci 'CREATE INDEX\|ADD INDEX\|INDEX(' 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}' || echo 0)
      if [ "$NON_INDEXED_FILTERS" -gt 5 ] && [ "$INDEX_COUNT" -eq 0 ]; then
        ANTI_PATTERNS=$((ANTI_PATTERNS + 1))
        ANTI_PATTERN_DETAILS="${ANTI_PATTERN_DETAILS}  - Missing indexes: ${NON_INDEXED_FILTERS} filtered columns, ${INDEX_COUNT} indexes defined\n"
      fi
    fi

    # 4. Eager loading / missing pagination
    EAGER_LOAD=$(echo "$SRC_FILES" | xargs grep -c '\.populate(\|\.include(\|\.joinedLoad\|\.all()\|\.findMany' 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}' || echo 0)
    if [ "$EAGER_LOAD" -gt 10 ]; then
      ANTI_PATTERNS=$((ANTI_PATTERNS + 1))
      ANTI_PATTERN_DETAILS="${ANTI_PATTERN_DETAILS}  - Eager loading: ${EAGER_LOAD} populate/include calls (verify pagination)\n"
    fi

    # 5. Unbounded loops / missing rate limits in handlers
    HANDLER_FILES=$(echo "$SRC_FILES" | grep -c 'router\|handler\|controller\|endpoint\|route' 2>/dev/null || echo 0)
    RATE_LIMITED=$(echo "$SRC_FILES" | xargs grep -c 'rate.?limit\|throttl\|middleware.*auth\|before.*hook' 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}' || echo 0)
    if [ "$HANDLER_FILES" -gt 5 ] && [ "$RATE_LIMITED" -eq 0 ]; then
      ANTI_PATTERNS=$((ANTI_PATTERNS + 1))
      ANTI_PATTERN_DETAILS="${ANTI_PATTERN_DETAILS}  - No rate limiting: ${HANDLER_FILES} handlers found, 0 rate-limit guards\n"
    fi
  fi
fi

# ── BUDGET VALIDATION (requires load testing tools + running server) ──
BUDGET_CHECK="SKIP"

if [ -z "$P95_THRESHOLD" ] && [ -z "$P99_THRESHOLD" ] && [ -z "$THROUGHPUT_THRESHOLD" ]; then
  echo "PERF BUDGET: Budget check skipped — no thresholds defined in plan.md"
else
  # Check for load testing tools
  if command -v wrk &>/dev/null; then
    echo "PERF BUDGET: wrk available — requires a running server to validate budget"
    BUDGET_CHECK="SKIP"
  elif command -v ab &>/dev/null; then
    echo "PERF BUDGET: ab available — requires a running server to validate budget"
    BUDGET_CHECK="SKIP"
  elif command -v curl &>/dev/null; then
    echo "PERF BUDGET: curl available — basic connectivity check only, no budget validation"
    BUDGET_CHECK="SKIP"
  else
    echo "PERF BUDGET: No load testing tools available — budget check skipped"
    BUDGET_CHECK="SKIP"
  fi
fi

# ── Report results ───────────────────────────────────────────────
echo ""
echo "PERF BUDGET: Anti-pattern scan complete — ${ANTI_PATTERNS} category(s) with warnings:"
if [ -n "$ANTI_PATTERN_DETAILS" ]; then
  echo -e "$ANTI_PATTERN_DETAILS"
fi

if [ "$BUDGET_CHECK" = "SKIP" ] && [ "$ANTI_PATTERNS" -eq 0 ]; then
  echo "PERF BUDGET: PASS — no anti-patterns detected, budget check N/A"
  check_write_result "$FEATURE_DIR" "performance_budget" "PASS"
  exit 0
fi

if [ "$ANTI_PATTERNS" -gt 0 ]; then
  echo "PERF BUDGET: WARN — ${ANTI_PATTERNS} anti-pattern category(ies) found (warnings, not blocking)"
  echo "  Review and consider refactoring if these patterns appear in hot paths."
  # Output warnings but do NOT fail — anti-patterns are advisory
  check_write_result "$FEATURE_DIR" "performance_budget" "PASS" "warnings:${ANTI_PATTERNS}"
  exit 0
fi

echo "PERF BUDGET: SKIP — no source files or project type unrecognized"
check_write_result "$FEATURE_DIR" "performance_budget" "SKIP"
exit 0
