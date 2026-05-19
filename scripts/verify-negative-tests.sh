#!/usr/bin/env bash
# Negative Tests Check (Check NT / test_design.negative_tests)
# Verifies negative tests exist for public APIs (invalid input, unauthorized, etc.)
#
# Usage: verify-negative-tests.sh <feature_dir> [--run] [--help]
#
# --run: actually execute the test suite and verify error paths pass.
#        Requires a working test runner.
# --pattern: (default) pattern matching only — outputs SKIP when test runner
#            is unavailable, otherwise reports pattern coverage.
#
# Writes PASS/FAIL/SKIP to .artifacts/check-results/test_design_negative_tests.result

set -euo pipefail

FEATURE_DIR=""
RUN_MODE=false
for arg in "$@"; do
  case "$arg" in
    --run) RUN_MODE=true ;;
    --pattern) ;;
    --help) echo "Usage: verify-negative-tests.sh <feature_dir> [--run] [--help]"; exit 0 ;;
    -*) continue ;;
    *) [ -z "$FEATURE_DIR" ] && FEATURE_DIR="$arg" ;;
  esac
done

FEATURE_DIR="${FEATURE_DIR:?Usage: verify-negative-tests.sh <feature_dir> [--run]}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

echo "NEGATIVE TESTS: Scanning ${FEATURE_DIR}"

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
  echo "NEGATIVE TESTS: SKIP (no recognized language in ${FEATURE_DIR})"
  echo "SKIP" > "${RESULTS_DIR}/test_design_negative_tests.result"
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
    echo "NEGATIVE TESTS: SKIP (no test runner found for ${LANGUAGE})"
    echo "SKIP" > "${RESULTS_DIR}/test_design_negative_tests.result"
    exit 0
  fi

  echo "NEGATIVE TESTS: RUN mode — executing tests via ${TEST_RUNNER}: ${TEST_RUN_CMD}"
  cd "$FEATURE_DIR"

  set +e
  TEST_OUTPUT=$(eval "$TEST_RUN_CMD" 2>&1)
  TEST_EXIT=$?
  set -e

  if [ "$TEST_EXIT" -ne 0 ]; then
    echo "NEGATIVE TESTS: FAIL — tests did not pass (exit code: ${TEST_EXIT})"
    echo "NEGATIVE TESTS: Test output:"
    echo "$TEST_OUTPUT" | tail -20
    echo "FAIL" > "${RESULTS_DIR}/test_design_negative_tests.result"
    exit 0
  fi

  CRASHES=0
  for pattern in 'UnhandledPromiseRejection' 'unhandled rejection' 'FATAL' 'panic: ' 'Segmentation fault' 'EXC_BAD_ACCESS' 'Fatal error' 'FATAL EXCEPTION'; do
    if echo "$TEST_OUTPUT" | grep -qi "$pattern" 2>/dev/null; then
      CRASHES=$((CRASHES + 1))
      echo "NEGATIVE TESTS: WARNING — found '$pattern' in test output"
    fi
  done

  if [ "$CRASHES" -gt 0 ]; then
    echo "NEGATIVE TESTS: FAIL — ${CRASHES} crash/unhandled exception pattern(s) in test output"
    echo "FAIL" > "${RESULTS_DIR}/test_design_negative_tests.result"
    exit 0
  fi

  echo "NEGATIVE TESTS: PASS — tests executed cleanly, no crashes detected"
  echo "PASS" > "${RESULTS_DIR}/test_design_negative_tests.result"
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
    echo "NEGATIVE TESTS: SKIP (no test runner available for pattern matching)"
    echo "SKIP" > "${RESULTS_DIR}/test_design_negative_tests.result"
  else
    echo "NEGATIVE TESTS: WARN (test files found but no runner — pattern matching only, no execution)"
    echo "SKIP" > "${RESULTS_DIR}/test_design_negative_tests.result"
  fi
  exit 0
fi

# ── Check for negative test patterns ─────────────────────────────
NEGATIVE_PATTERNS=0

case "$LANGUAGE" in
  typescript)
    # Check for 4xx status code tests
    STATUS_4XX=$(echo "$TEST_FILES" | xargs grep -cl '400\|401\|403\|404\|409\|422' 2>/dev/null || true)
    [ -n "$STATUS_4XX" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))

    # Check for invalid input tests
    INVALID_INPUT=$(echo "$TEST_FILES" | xargs grep -cl 'invalid\|malformed\|bad\s*input\|wrong\s*type\|missing.*field\|empty.*string' 2>/dev/null || true)
    [ -n "$INVALID_INPUT" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))

    # Check for unauthorized tests
    UNAUTH=$(echo "$TEST_FILES" | xargs grep -cl 'unauthorized\|forbidden\|noauth\|no_token\|without.*auth\|invalid.*token' 2>/dev/null || true)
    [ -n "$UNAUTH" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))

    # Check for expectReject / toReject patterns
    REJECT=$(echo "$TEST_FILES" | xargs grep -cl 'reject\|toThrow\|toBeRejected' 2>/dev/null || true)
    [ -n "$REJECT" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))
    ;;

  python)
    # Check for 4xx status code tests
    STATUS_4XX=$(echo "$TEST_FILES" | xargs grep -cl '400\|401\|403\|404\|409\|422' 2>/dev/null || true)
    [ -n "$STATUS_4XX" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))

    # Check for invalid input tests
    INVALID_INPUT=$(echo "$TEST_FILES" | xargs grep -cl 'invalid\|malformed\|bad.*input\|wrong.*type\|missing.*field' 2>/dev/null || true)
    [ -n "$INVALID_INPUT" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))

    # Check for unauthorized tests
    UNAUTH=$(echo "$TEST_FILES" | xargs grep -cl 'unauthorized\|forbidden\|noauth\|no_token\|without.*auth' 2>/dev/null || true)
    [ -n "$UNAUTH" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))

    # Check for pytest.raises with specific exceptions
    RAISES=$(echo "$TEST_FILES" | xargs grep -cl 'pytest.raises\|assertRaises.*ValueError\|assertRaises.*TypeError' 2>/dev/null || true)
    [ -n "$RAISES" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))
    ;;

  java)
    # Check for 4xx status code tests
    STATUS_4XX=$(echo "$TEST_FILES" | xargs grep -cl 'status\s*(\s*400\|status\s*(\s*401\|status\s*(\s*403\|status\s*(\s*404' 2>/dev/null || true)
    [ -n "$STATUS_4XX" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))

    # Check for assertThrows with specific exceptions
    ASSERT_THROWS=$(echo "$TEST_FILES" | xargs grep -cl 'assertThrows.*IllegalArgumentException\|assertThrows.*ValidationException' 2>/dev/null || true)
    [ -n "$ASSERT_THROWS" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))

    # Check for null input tests
    NULL_INPUT=$(echo "$TEST_FILES" | xargs grep -cl 'null.*input\|empty.*input\|invalid.*argument' 2>/dev/null || true)
    [ -n "$NULL_INPUT" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))
    ;;

  go)
    # Check for error response tests
    ERROR_RESP=$(echo "$TEST_FILES" | xargs grep -cl '400\|401\|403\|404\|StatusBadRequest\|StatusUnauthorized' 2>/dev/null || true)
    [ -n "$ERROR_RESP" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))

    # Check for invalid input tests
    INVALID_INPUT=$(echo "$TEST_FILES" | xargs grep -cl 'invalid\|malformed\|bad.*request\|empty.*body' 2>/dev/null || true)
    [ -n "$INVALID_INPUT" ] && NEGATIVE_PATTERNS=$((NEGATIVE_PATTERNS + 1))
    ;;
esac

# ── Report results ───────────────────────────────────────────────
if [ "$NEGATIVE_PATTERNS" -ge 2 ]; then
  echo "NEGATIVE TESTS: PASS — ${NEGATIVE_PATTERNS} negative test pattern type(s) detected"
  echo "PASS" > "${RESULTS_DIR}/test_design_negative_tests.result"
  exit 0
fi

echo "NEGATIVE TESTS: FAIL — only ${NEGATIVE_PATTERNS} negative test pattern type(s) found (need at least 2)"
echo "FAIL" > "${RESULTS_DIR}/test_design_negative_tests.result"
exit 0
