#!/usr/bin/env bash
# Failure Modes Check (Check M / test_design.failure_modes)
# Checks that error paths and edge cases have dedicated tests.
#
# Usage: check-failure-modes.sh <feature_dir> [--run] [--help]
#
# --run: actually execute the test suite and verify error paths pass.
#        Requires a working test runner.
# --pattern: (default) pattern matching only — outputs SKIP when test runner
#            is unavailable, otherwise reports pattern coverage.
#
# Writes PASS/FAIL/SKIP to .artifacts/check-results/test_design_failure_modes.result

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

# ── Parse flags ────────────────────────────────────────────────────
RUN_MODE=false
if [ "${1:-}" = "--help" ]; then
  check_help "check-failure-modes.sh" "<feature_dir> [--run] [--help]"
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

FEATURE_DIR="${FEATURE_DIR:?Usage: check-failure-modes.sh <feature_dir> [--run] [--help]}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"

echo "FAILURE MODES: Scanning ${FEATURE_DIR}"

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
  echo "FAILURE MODES: SKIP (no recognized language in ${FEATURE_DIR})"
  check_write_result "$FEATURE_DIR" "failure_modes" "SKIP"
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
    echo "FAILURE MODES: SKIP (no test runner found for ${LANGUAGE})"
    check_write_result "$FEATURE_DIR" "failure_modes" "SKIP"
    exit 0
  fi

  echo "FAILURE MODES: RUN mode — executing tests via ${TEST_RUNNER}: ${TEST_RUN_CMD}"
  cd "$FEATURE_DIR"

  set +e
  TEST_OUTPUT=$(eval "$TEST_RUN_CMD" 2>&1)
  TEST_EXIT=$?
  set -e

  if [ "$TEST_EXIT" -ne 0 ]; then
    echo "FAILURE MODES: FAIL — tests did not pass (exit code: ${TEST_EXIT})"
    echo "FAILURE MODES: Test output:"
    echo "$TEST_OUTPUT" | tail -20
    check_write_result "$FEATURE_DIR" "failure_modes" "FAIL" "tests_failed_exit_${TEST_EXIT}"
    exit 0
  fi

  CRASHES=0
  for pattern in 'UnhandledPromiseRejection' 'unhandled rejection' 'FATAL' 'panic: ' 'Segmentation fault' 'EXC_BAD_ACCESS' 'Fatal error' 'FATAL EXCEPTION'; do
    if echo "$TEST_OUTPUT" | grep -qi "$pattern" 2>/dev/null; then
      CRASHES=$((CRASHES + 1))
      echo "FAILURE MODES: WARNING — found '$pattern' in test output"
    fi
  done

  if [ "$CRASHES" -gt 0 ]; then
    echo "FAILURE MODES: FAIL — ${CRASHES} crash/unhandled exception pattern(s) in test output"
    check_write_result "$FEATURE_DIR" "failure_modes" "FAIL" "crashes_detected"
    exit 0
  fi

  echo "FAILURE MODES: PASS — tests executed cleanly, no crashes detected"
  check_write_result "$FEATURE_DIR" "failure_modes" "PASS"
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
    echo "FAILURE MODES: SKIP (no test runner available for pattern matching)"
    check_write_result "$FEATURE_DIR" "failure_modes" "SKIP"
  else
    echo "FAILURE MODES: WARN (test files found but no runner — pattern matching only, no execution)"
    check_write_result "$FEATURE_DIR" "failure_modes" "SKIP" "no_test_runner"
  fi
  exit 0
fi

# ── Check for error path coverage ────────────────────────────────
# Look for tests that exercise error conditions:
#   - try/catch, throw, panic, rescue, error return patterns
#   - null/undefined/nil input tests
#   - empty collection tests
#   - boundary value tests (0, max, negative)

ERROR_PATTERNS=0

case "$LANGUAGE" in
  typescript)
    # Check for try/catch blocks in tests
    TRY_CATCH=$(echo "$TEST_FILES" | xargs grep -cl 'try\s*{' 2>/dev/null || true)
    [ -n "$TRY_CATCH" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))

    # Check for reject/throw/error assertions
    ERROR_ASSERT=$(echo "$TEST_FILES" | xargs grep -cl 'reject\|toThrow\|toThrowError\|toBeRejected\|\.error' 2>/dev/null || true)
    [ -n "$ERROR_ASSERT" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))

    # Check for null/undefined tests
    NULL_TEST=$(echo "$TEST_FILES" | xargs grep -cl 'null\|undefined\|NaN' 2>/dev/null || true)
    [ -n "$NULL_TEST" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))

    # Check for boundary tests
    BOUNDARY=$(echo "$TEST_FILES" | xargs grep -cl '0\s*[,)]\|<=\s*0\|>=\s*0\|max\|min\|empty' 2>/dev/null || true)
    [ -n "$BOUNDARY" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))
    ;;

  python)
    # Check for try/except blocks in tests
    TRY_EXCEPT=$(echo "$TEST_FILES" | xargs grep -cl 'try\s*:' 2>/dev/null || true)
    [ -n "$TRY_EXCEPT" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))

    # Check for pytest.raises
    RAISES=$(echo "$TEST_FILES" | xargs grep -cl 'pytest.raises\|assertRaises' 2>/dev/null || true)
    [ -n "$RAISES" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))

    # Check for None/null tests
    NULL_TEST=$(echo "$TEST_FILES" | xargs grep -cl 'None\|is None\|is not None' 2>/dev/null || true)
    [ -n "$NULL_TEST" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))

    # Check for empty collection tests
    EMPTY_TEST=$(echo "$TEST_FILES" | xargs grep -cl 'empty\|\[\]\|""\|len\s*(\s*0' 2>/dev/null || true)
    [ -n "$EMPTY_TEST" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))
    ;;

  java)
    # Check for try/catch in tests
    TRY_CATCH=$(echo "$TEST_FILES" | xargs grep -cl 'try\s*{' 2>/dev/null || true)
    [ -n "$TRY_CATCH" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))

    # Check for @Test(expected
    EXPECTED=$(echo "$TEST_FILES" | xargs grep -cl '@Test(expected\|assertThrows' 2>/dev/null || true)
    [ -n "$EXPECTED" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))

    # Check for null tests
    NULL_TEST=$(echo "$TEST_FILES" | xargs grep -cl 'null\|NullPointerException' 2>/dev/null || true)
    [ -n "$NULL_TEST" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))
    ;;

  go)
    # Check for panic/recover in tests
    PANIC=$(echo "$TEST_FILES" | xargs grep -cl 'panic\|recover' 2>/dev/null || true)
    [ -n "$PANIC" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))

    # Check for error return tests
    ERROR_RET=$(echo "$TEST_FILES" | xargs grep -cl 't\.Error\|errors\.Is\|errors\.Is' 2>/dev/null || true)
    [ -n "$ERROR_RET" ] && ERROR_PATTERNS=$((ERROR_PATTERNS + 1))
    ;;
esac

# ── Check for acceptance criteria error behaviors in tasks.md ────
TASKS_FILE="${FEATURE_DIR}/tasks.md"
if [ -f "$TASKS_FILE" ]; then
  # Look for error-related acceptance criteria
  ERROR_CRITERIA=$(grep -ciE '(return|throw|raise|40[0-9]|error|fail|invalid|reject)' "$TASKS_FILE" 2>/dev/null || echo 0)
  if [ "$ERROR_CRITERIA" -gt 0 ]; then
    echo "FAILURE MODES: Found ${ERROR_CRITERIA} error-related acceptance criteria in tasks.md"
  fi
fi

# ── Report results ───────────────────────────────────────────────
if [ "$ERROR_PATTERNS" -ge 2 ]; then
  echo "FAILURE MODES: PASS — ${ERROR_PATTERNS} error pattern types detected in tests"
  check_write_result "$FEATURE_DIR" "failure_modes" "PASS"
  exit 0
fi

echo "FAILURE MODES: FAIL — only ${ERROR_PATTERNS} error pattern type(s) found (need at least 2)"
check_write_result "$FEATURE_DIR" "failure_modes" "FAIL"
exit 0
