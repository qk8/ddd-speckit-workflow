#!/usr/bin/env bash
# Failure Modes Check (Check M / test_design.failure_modes)
# Checks that error paths and edge cases have dedicated tests.
#
# Usage: check-failure-modes.sh <feature_dir>
#
# Writes PASS/FAIL to .artifacts/check-results/test_design_failure_modes.result

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-failure-modes.sh <feature_dir>}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

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
  echo "SKIP" > "${RESULTS_DIR}/test_design_failure_modes.result"
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
  echo "FAILURE MODES: SKIP (no test files found)"
  echo "SKIP" > "${RESULTS_DIR}/test_design_failure_modes.result"
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
  echo "PASS" > "${RESULTS_DIR}/test_design_failure_modes.result"
  exit 0
fi

echo "FAILURE MODES: FAIL — only ${ERROR_PATTERNS} error pattern type(s) found (need at least 2)"
echo "FAIL" > "${RESULTS_DIR}/test_design_failure_modes.result"
exit 0
