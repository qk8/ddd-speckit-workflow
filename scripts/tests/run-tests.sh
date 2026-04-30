#!/usr/bin/env bash
# Run all script tests in scripts/tests/
# Usage: bash scripts/tests/run-tests.sh
#
# Each test file is sourced and must define assert_* functions
# before being sourced.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL=0
PASSED=0
FAILED=0

# Clean up any previous run artifacts
rm -f /tmp/test-run-passed /tmp/test-run-failed 2>/dev/null || true

for test_file in "$TESTS_DIR"/test_*.sh; do
  [ -f "$test_file" ] || continue
  TOTAL=$((TOTAL + 1))
  echo "Running $(basename "$test_file")..."

  # Source the test in a subshell with helper functions
  (
    set -euo pipefail

    assert_eq() {
      local expected="$1" actual="$2" msg="$3"
      if [ "$expected" = "$actual" ]; then
        echo "  PASS: $msg"
        echo "PASS" >> /tmp/test-run-passed
      else
        echo "  FAIL: $msg (expected='$expected', actual='$actual')" >&2
        echo "FAIL" >> /tmp/test-run-failed
      fi
    }

    assert_contains() {
      local haystack="$1" needle="$2" msg="$3"
      if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $msg"
        echo "PASS" >> /tmp/test-run-passed
      else
        echo "  FAIL: $msg (output missing '$needle')" >&2
        echo "FAIL" >> /tmp/test-run-failed
      fi
    }

    assert_not_contains() {
      local haystack="$1" needle="$2" msg="$3"
      if ! echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $msg"
        echo "PASS" >> /tmp/test-run-passed
      else
        echo "  FAIL: $msg (output unexpectedly contains '$needle')" >&2
        echo "FAIL" >> /tmp/test-run-failed
      fi
    }

    # Source the actual test
    . "$test_file"
  )

  if grep -q "FAIL" /tmp/test-run-failed 2>/dev/null; then
    FAILED=$((FAILED + 1))
  else
    PASSED=$((PASSED + 1))
  fi
  echo ""
done

echo "========================================"
echo "  Script Tests: $TOTAL total, $PASSED passed, $FAILED failed"
echo "========================================"

rm -f /tmp/test-run-passed /tmp/test-run-failed 2>/dev/null || true

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
