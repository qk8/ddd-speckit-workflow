#!/usr/bin/env bash
# Test quality trend analysis.
# Tracks test quality metrics across tasks and flags degradation.
#
# Usage: test-trend-analyzer.sh <feature_dir>
# Outputs: TREND_HEALTHY=true|false, DEGRADATION_COUNT=N, DEGRADATION_DETAILS=...

set -euo pipefail

FEATURE_DIR="${1:?Usage: test-trend-analyzer.sh <feature_dir>}"

if [ ! -d "$FEATURE_DIR" ]; then
  echo "TREND_HEALTHY=true"
  echo "DEGRADATION_COUNT=0"
  exit 0
fi

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

RESULTS_FILE="${ARTIFACTS_DIR}/test-trend.result"

# ── Find all test files ────────────────────────────────────────
TEST_FILES=$(find "$FEATURE_DIR" -type f \( -name '*.test.*' -o -name '*.spec.*' -o -name '*Test.*' -o -name '*Spec.*' \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' 2>/dev/null || true)

if [ -z "$TEST_FILES" ]; then
  echo "TREND_HEALTHY=true"
  echo "DEGRADATION_COUNT=0"
  echo "  No test files found."
  exit 0
fi

DEGRADATIONS=""
DEGRADATION_COUNT=0

# ── Analyze each test file ─────────────────────────────────────
echo "$TEST_FILES" | while read -r test_file; do
  [ -f "$test_file" ] || continue

  basename_file=$(basename "$test_file")
  file_size=$(wc -l < "$test_file" | xargs)

  # Check 1: File size — flag files > 200 lines (likely doing too much)
  if [ "$file_size" -gt 200 ]; then
    echo "  LARGE_FILE: ${basename_file} (${file_size} lines) — consider splitting"
  fi

  # Check 2: Assertion count per test
  # Count describe/it/test blocks
  test_count=$(grep -cE '(describe|it\(|test\(|describe\(|specify\()' "$test_file" 2>/dev/null || echo 0)

  # Count assertion calls
  assert_count=$(grep -cE '(expect\(|assert(Not)?|assertEqual|assertTrue|assertFalse|assertThrows|assertInstanceOf|toBe|toEqual|toStrictEqual|rejects\.rejects|resolves\.resolves)' "$test_file" 2>/dev/null || echo 0)

  # Check 3: Trivial assertions (expect(true).toBe(true), expect(1).toBe(1))
  trivial=$(grep -cE "expect\(true\)\.toBe\(true\)|expect\(false\)\.toBe\(false\)|expect\(1\)\.toBe\(1\)|expect\(0\)\.toBe\(0\)|expect\(\[\]\)\.toBeEmpty" "$test_file" 2>/dev/null || echo 0)

  if [ "$trivial" -gt 0 ]; then
    echo "  TRIVIAL_ASSERTIONS: ${basename_file} has ${trivial} trivial assertion(s) — these test nothing"
  fi

  # Check 4: Assertion variety — flag files using only one type
  assert_types=0
  grep -qE 'expect\(|assert' "$test_file" 2>/dev/null && assert_types=$((assert_types + 1))
  grep -qE 'assertEqual|assertEquals' "$test_file" 2>/dev/null && assert_types=$((assert_types + 1))
  grep -qE 'assertThrows|rejects|throws' "$test_file" 2>/dev/null && assert_types=$((assert_types + 1))
  grep -qE 'toBe|toEqual|toStrictEqual' "$test_file" 2>/dev/null && assert_types=$((assert_types + 1))

  if [ "$test_count" -gt 5 ] && [ "$assert_types" -le 1 ]; then
    echo "  LOW_VARIETY: ${basename_file} has ${test_count} tests but only ${assert_types} assertion type(s) — likely shallow tests"
  fi

  # Check 5: Mock usage ratio
  mock_count=$(grep -cE '(mock\(|Mockito\.|spy\(|@Mock|@InjectMocks|vi\.fn\(|jest\.fn\(|createSpy)' "$test_file" 2>/dev/null || echo 0)
  if [ "$test_count" -gt 0 ] && [ "$mock_count" -eq 0 ]; then
    # No mocks — could be fine (unit tests of pure functions) or could mean
    # the tests aren't testing integration points
    :
  fi

  # Check 6: Empty test bodies (describe/it with no assertions)
  # This is a heuristic: look for describe/it blocks that don't contain expect/assert
  if grep -qE 'describe\(|it\(|test\(' "$test_file" 2>/dev/null; then
    if [ "$assert_count" -eq 0 ] && [ "$test_count" -gt 0 ]; then
      echo "  EMPTY_TESTS: ${basename_file} has ${test_count} test blocks with 0 assertions"
    fi
  fi

done > "${ARTIFACTS_DIR}/test-trend-report.md"

# ── Count degradations ─────────────────────────────────────────
DEGRADATION_COUNT=$(grep -cE 'TRIVIAL_ASSERTIONS|EMPTY_TESTS|LOW_VARIETY' "${ARTIFACTS_DIR}/test-trend-report.md" 2>/dev/null || echo 0)

if [ "$DEGRADATION_COUNT" -eq 0 ]; then
  echo "TREND_HEALTHY=true"
  echo "DEGRADATION_COUNT=0"
  echo "  Test quality is healthy across all files."
else
  echo "TREND_HEALTHY=false"
  echo "DEGRADATION_COUNT=${DEGRADATION_COUNT}"
  echo "  Issues found:"
  grep -E 'TRIVIAL_ASSERTIONS|EMPTY_TESTS|LOW_VARIETY' "${ARTIFACTS_DIR}/test-trend-report.md" | head -20
fi

exit 0
