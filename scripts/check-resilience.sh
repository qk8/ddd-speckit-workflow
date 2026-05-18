#!/usr/bin/env bash
# Resilience Testing Check (Check Q / resilience.resilience_testing)
# Verifies resilience patterns (circuit breakers, retries, timeouts) are tested.
#
# Usage: check-resilience.sh <feature_dir>
#
# Writes PASS/FAIL to .artifacts/check-results/resilience_resilience_testing.result

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

# ── Parse flags ────────────────────────────────────────────────────
if [ "${1:-}" = "--help" ]; then
  check_help "check-resilience.sh" "<feature_dir> [--help]"
fi

FEATURE_DIR="${1:?Usage: check-resilience.sh <feature_dir>}"

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
  echo "RESILIENCE: SKIP (no test files found)"
  check_write_result "$FEATURE_DIR" "resilience" "SKIP"
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
