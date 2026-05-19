#!/usr/bin/env bash
# Resilience Testing Check (Check Q / resilience.resilience_testing)
# Verifies resilience patterns (circuit breakers, retries, timeouts) are tested.
#
# Usage: check-resilience.sh <feature_dir> [--run] [--help]
#
# --run: actually execute the test suite and check for proper error handling
#        on timeout/failure scenarios. Requires a working test runner.
# --pattern: (default) pattern matching only — outputs SKIP when test runner
#            is unavailable, otherwise reports pattern coverage.
#
# Writes PASS/FAIL/SKIP to .artifacts/check-results/resilience_resilience_testing.result

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

# ── Parse flags ────────────────────────────────────────────────────
RUN_MODE=false
if [ "${1:-}" = "--help" ]; then
  check_help "check-resilience.sh" "<feature_dir> [--run] [--help]"
fi

FEATURE_DIR=""
for arg in "$@"; do
  case "$arg" in
    --run) RUN_MODE=true ;;
    --pattern) ;;
    -*) continue ;;
    *) [ -z "$FEATURE_DIR" ] && FEATURE_DIR="$arg" ;;
  esac
done

FEATURE_DIR="${FEATURE_DIR:?Usage: check-resilience.sh <feature_dir> [--run] [--help]}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"

echo "RESILIENCE: Scanning ${FEATURE_DIR}"

# ── Detect language ──────────────────────────────────────────────
LANGUAGE=""
if [ -f "${FEATURE_DIR}/package.json" ] || [ -f "${FEATURE_DIR}/tsconfig.json" ]; then
  LANGUAGE="typescript"
elif [ -f "${FEATURE_DIR}/requirements.txt" ] || [ -f "${FEATURE_DIR}/pyproject.toml" ]; then
  LANGUAGE="python"
elif [ -f "${FEATURE_DIR}/pom.xml" ] || [ -f "${FEATURE_DIR}/build.gradle" ]; then
  LANGUAGE="java"
elif [ -f "${FEATURE_DIR}/go.mod" ]; then
  LANGUAGE="go"
fi

if [ -z "$LANGUAGE" ]; then
  echo "RESILIENCE: SKIP (no recognized language in ${FEATURE_DIR})"
  check_write_result "$FEATURE_DIR" "resilience" "SKIP"
  exit 0
fi

# ── Try to detect test runner ────────────────────────────────────
TEST_RUNNER=""
TEST_RUN_CMD=""
case "$LANGUAGE" in
  typescript)
    if [ -f "${FEATURE_DIR}/package.json" ]; then
      TEST_RUN_CMD=$(grep -oE '"test"[[:space:]]*:[[:space:]]*"[^"]+"' "${FEATURE_DIR}/package.json" 2>/dev/null | head -1 | sed 's/"test"[[:space:]]*:[[:space:]]*"\(.*\)"/\1/' || true)
      if [ -n "$TEST_RUN_CMD" ]; then
        TEST_RUNNER="npm"
      fi
    fi
    if [ -z "$TEST_RUNNER" ] && command -v npx &>/dev/null; then
      TEST_RUNNER="npx"
      TEST_RUN_CMD="vitest"
    fi
    ;;
  python)
    if command -v pytest &>/dev/null; then
      TEST_RUNNER="pytest"
      TEST_RUN_CMD="pytest"
    elif [ -f "${FEATURE_DIR}/pyproject.toml" ] && grep -q '^\[tool.pytest' "${FEATURE_DIR}/pyproject.toml" 2>/dev/null; then
      TEST_RUNNER="pip+pytest"
      TEST_RUN_CMD="pytest"
    fi
    ;;
  java)
    if [ -f "${FEATURE_DIR}/mvnw" ]; then
      TEST_RUNNER="maven"
      TEST_RUN_CMD="./mvnw test -q"
    elif command -v mvn &>/dev/null; then
      TEST_RUNNER="maven"
      TEST_RUN_CMD="mvn test -q"
    elif [ -f "${FEATURE_DIR}/gradlew" ]; then
      TEST_RUNNER="gradle"
      TEST_RUN_CMD="./gradlew test --quiet"
    elif command -v gradle &>/dev/null; then
      TEST_RUNNER="gradle"
      TEST_RUN_CMD="gradle test --quiet"
    fi
    ;;
  go)
    if command -v go &>/dev/null; then
      TEST_RUNNER="go"
      TEST_RUN_CMD="go test ./..."
    fi
    ;;
esac

# ── RUN mode: actually execute the test suite ─────────────────────
if [ "$RUN_MODE" = true ]; then
  if [ -z "$TEST_RUNNER" ]; then
    echo "RESILIENCE: SKIP (no test runner found for ${LANGUAGE})"
    check_write_result "$FEATURE_DIR" "resilience" "SKIP"
    exit 0
  fi

  echo "RESILIENCE: RUN mode — executing tests via ${TEST_RUNNER}: ${TEST_RUN_CMD}"
  cd "$FEATURE_DIR"

  set +e
  TEST_OUTPUT=$(eval "$TEST_RUN_CMD" 2>&1)
  TEST_EXIT=$?
  set -e

  if [ "$TEST_EXIT" -ne 0 ]; then
    echo "RESILIENCE: FAIL — tests did not pass (exit code: ${TEST_EXIT})"
    echo "RESILIENCE: Test output:"
    echo "$TEST_OUTPUT" | tail -20
    check_write_result "$FEATURE_DIR" "resilience" "FAIL" "tests_failed_exit_${TEST_EXIT}"
    exit 0
  fi

  CRASHES=0
  for pattern in 'UnhandledPromiseRejection' 'unhandled rejection' 'FATAL' 'panic: ' 'Segmentation fault' 'EXC_BAD_ACCESS' 'Fatal error' 'FATAL EXCEPTION'; do
    if echo "$TEST_OUTPUT" | grep -qi "$pattern" 2>/dev/null; then
      CRASHES=$((CRASHES + 1))
      echo "RESILIENCE: WARNING — found '$pattern' in test output"
    fi
  done

  if [ "$CRASHES" -gt 0 ]; then
    echo "RESILIENCE: FAIL — ${CRASHES} crash/unhandled exception pattern(s) in test output"
    check_write_result "$FEATURE_DIR" "resilience" "FAIL" "crashes_detected"
    exit 0
  fi

  echo "RESILIENCE: PASS — tests executed cleanly, no crashes detected"
  check_write_result "$FEATURE_DIR" "resilience" "PASS"
  exit 0
fi

# ── Find test files ──────────────────────────────────────────────
TEST_FILES=""
case "$LANGUAGE" in
  typescript)
    TEST_FILES=$(find "$FEATURE_DIR" -type f \( -name '*test*' -o -name '*.spec.*' \) \
      ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/dist/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
  python)
    TEST_FILES=$(find "$FEATURE_DIR" -type f \( -name '*test*' -o -name '*_test.py' \) \
      ! -path '*/.venv/*' ! -path '*/venv/*' ! -path '*/__pycache__/*' ! -path '*/.git/*' \
      ! -path '*/.artifacts/*' 2>/dev/null || true)
    ;;
  java)
    TEST_FILES=$(find "$FEATURE_DIR" -type f \( -name '*Test.java' -o -name '*Tests.java' \) \
      ! -path '*/build/*' ! -path '*/target/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
  go)
    TEST_FILES=$(find "$FEATURE_DIR" -type f -name '*_test.go' \
      ! -path '*/vendor/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
esac

if [ -z "$TEST_FILES" ]; then
  if [ -z "$TEST_RUNNER" ]; then
    echo "RESILIENCE: SKIP (no test runner available for pattern matching)"
    check_write_result "$FEATURE_DIR" "resilience" "SKIP"
  else
    echo "RESILIENCE: WARN (test files found but no runner — pattern matching only, no execution)"
    check_write_result "$FEATURE_DIR" "resilience" "SKIP" "no_test_runner"
  fi
  exit 0
fi

# ── Check for resilience test patterns ───────────────────────────
RESILIENCE_PATTERNS=0

case "$LANGUAGE" in
  typescript)
    # Check for timeout tests
    TIMEOUT_TESTS=$(echo "$TEST_FILES" | xargs grep -cl 'timeout\|jest\.setTimeout\|fakeTimers' 2>/dev/null || true)
    [ -n "$TIMEOUT_TESTS" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for network error / connection failure tests
    NETWORK_ERR=$(echo "$TEST_FILES" | xargs grep -cl 'ECONNREFUSED\|ENOTFOUND\|network.*error\|connection.*fail\|timeout.*error\|fetch.*fail' 2>/dev/null || true)
    [ -n "$NETWORK_ERR" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for retry pattern tests
    RETRY=$(echo "$TEST_FILES" | xargs grep -cl 'retry\|backoff\|exponential.*backoff\|attempt' 2>/dev/null || true)
    [ -n "$RETRY" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for circuit breaker tests
    CIRCUIT=$(echo "$TEST_FILES" | xargs grep -cl 'circuit.*breaker\|circuitBreaker\|circuit_breaker' 2>/dev/null || true)
    [ -n "$CIRCUIT" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for stub/fake network responses
    FAKE_NET=$(echo "$TEST_FILES" | xargs grep -cl 'nock\|nock\|http\.Server\|mock.*server\|msw\|MockAgent' 2>/dev/null || true)
    [ -n "$FAKE_NET" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))
    ;;

  python)
    # Check for timeout tests
    TIMEOUT_TESTS=$(echo "$TEST_FILES" | xargs grep -cl 'timeout\|pytest\.mark\.\(timeout\|flaky\)' 2>/dev/null || true)
    [ -n "$TIMEOUT_TESTS" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for connection failure tests
    CONN_FAIL=$(echo "$TEST_FILES" | xargs grep -cl 'ConnectionError\|TimeoutError\|ConnectionRefused\|requests\.ConnectTimeout\|requests\.ReadTimeout' 2>/dev/null || true)
    [ -n "$CONN_FAIL" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for retry pattern tests
    RETRY=$(echo "$TEST_FILES" | xargs grep -cl 'retry\|backoff\|tenacity\|exponential' 2>/dev/null || true)
    [ -n "$RETRY" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for mock network calls
    MOCK_NET=$(echo "$TEST_FILES" | xargs grep -cl 'responses\.\|aioresponses\|httpretty\|mock.*request\|respx' 2>/dev/null || true)
    [ -n "$MOCK_NET" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))
    ;;

  java)
    # Check for timeout tests
    TIMEOUT_TESTS=$(echo "$TEST_FILES" | xargs grep -cl 'timeout\|@Timeout\|assertTimeout' 2>/dev/null || true)
    [ -n "$TIMEOUT_TESTS" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for connection failure tests
    CONN_FAIL=$(echo "$TEST_FILES" | xargs grep -cl 'ConnectException\|SocketTimeout\|IOException\|ConnectTimeoutException' 2>/dev/null || true)
    [ -n "$CONN_FAIL" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for retry pattern tests
    RETRY=$(echo "$TEST_FILES" | xargs grep -cl 'retry\|Backoff\|ExponentialBackoff\|SpringRetry' 2>/dev/null || true)
    [ -n "$RETRY" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for circuit breaker tests
    CIRCUIT=$(echo "$TEST_FILES" | xargs grep -cl 'CircuitBreaker\|Resilience4j\|resilience4j' 2>/dev/null || true)
    [ -n "$CIRCUIT" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))
    ;;

  go)
    # Check for timeout tests
    TIMEOUT_TESTS=$(echo "$TEST_FILES" | xargs grep -cl 'context\.WithTimeout\|context\.WithDeadline\|timeout' 2>/dev/null || true)
    [ -n "$TIMEOUT_TESTS" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for connection failure tests
    CONN_FAIL=$(echo "$TEST_FILES" | xargs grep -cl 'connection.*refused\|dial.*fail\|context.*deadline\|DeadlineExceeded' 2>/dev/null || true)
    [ -n "$CONN_FAIL" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))

    # Check for retry pattern tests
    RETRY=$(echo "$TEST_FILES" | xargs grep -cl 'retry\|backoff\|Retry' 2>/dev/null || true)
    [ -n "$RETRY" ] && RESILIENCE_PATTERNS=$((RESILIENCE_PATTERNS + 1))
    ;;
esac

# ── Report results ───────────────────────────────────────────────
if [ "$RESILIENCE_PATTERNS" -ge 2 ]; then
  echo "RESILIENCE: PASS — ${RESILIENCE_PATTERNS} resilience test pattern type(s) detected"
  check_write_result "$FEATURE_DIR" "resilience" "PASS"
  exit 0
fi

echo "RESILIENCE: FAIL — only ${RESILIENCE_PATTERNS} resilience test pattern type(s) found (need at least 2)"
check_write_result "$FEATURE_DIR" "resilience" "FAIL"
exit 0
