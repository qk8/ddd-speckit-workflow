#!/usr/bin/env bash
# Usage: ./scripts/validate-tests.sh <test_command> [expected_result]
#
# Runs a test command, captures full output to a temp file, checks exit code,
# and outputs a machine-parseable summary. This eliminates the LLM hallucination
# vector where the LLM reports test results faithfully without actually reading
# the raw output.
#
# The script is the single source of truth for test results. The LLM must NEVER
# report test pass/fail status directly — it must always read the output of this
# script instead.
#
# Arguments:
#   test_command    — The full test command to execute (e.g., "npm test -- --coverage")
#   expected_result — "fail" or "pass" (default: "pass")
#                     If "fail", the test is expected to exit non-zero.
#                     If "pass", the test is expected to exit zero.
#
# Output (key=value, machine-parseable):
#   TEST_EXIT_CODE=N
#   TEST_RESULT=pass|fail|error
#   TEST_TOTAL=N
#   TEST_PASSED=N
#   TEST_FAILED=N
#   TEST_SKIPPED=N
#   TEST_OUTPUT_FILE=/path/to/output
#   TEST_SUMMARY=one-line summary
#
# The output file contains the full raw output for human review.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "ERROR: test_command is required" >&2
  echo "Usage: $0 <test_command> [expected_result]" >&2
  exit 2
fi

TEST_COMMAND="$1"
EXPECTED="${2:-pass}"

# Create temp files for output
OUTPUT_FILE=$(mktemp /tmp/test-output-XXXXXX.txt)
trap 'rm -f "$OUTPUT_FILE"' EXIT

# Run the test command, capture all output
# Use a subshell (parens) so that 'exit N' in the command doesn't kill us.
# Use || true to prevent set -e from killing the script when tests fail
# (the expected case for red-phase testing where we expect failure)
TEST_EXIT_CODE=0
# Use bash -c instead of eval to avoid executing in current shell context.
( bash -c "$TEST_COMMAND" ) >"$OUTPUT_FILE" 2>&1 || TEST_EXIT_CODE=$?

# Parse test results from output
# Try common test runner patterns
TEST_PASSED=0
TEST_FAILED=0
TEST_SKIPPED=0
TEST_TOTAL=0

# Jest: "Test Suites: X passed, Y failed" or "Tests: X/Y"
if grep -q "Test Suites:" "$OUTPUT_FILE" 2>/dev/null; then
  PASSED=$(grep "Test Suites:" "$OUTPUT_FILE" | grep -o "[0-9]* passed" | grep -o "[0-9]*" || echo "0")
  FAILED=$(grep "Test Suites:" "$OUTPUT_FILE" | grep -o "[0-9]* failed" | grep -o "[0-9]*" || echo "0")
  SKIPPED=$(grep "Test Suites:" "$OUTPUT_FILE" | grep -o "[0-9]* skipped" | grep -o "[0-9]*" || echo "0")
  [ -n "$PASSED" ] && TEST_PASSED="$PASSED"
  [ -n "$FAILED" ] && TEST_FAILED="$FAILED"
  [ -n "$SKIPPED" ] && TEST_SKIPPED="$SKIPPED"
  TEST_TOTAL=$((TEST_PASSED + TEST_FAILED + TEST_SKIPPED))
fi

# Jest/standard: "Tests: N passed, M failed"
if [ "$TEST_TOTAL" -eq 0 ] && grep -q "Tests:" "$OUTPUT_FILE" 2>/dev/null; then
  PASSED=$(grep "Tests:" "$OUTPUT_FILE" | grep -o "[0-9]* passed" | grep -o "[0-9]*" || echo "0")
  FAILED=$(grep "Tests:" "$OUTPUT_FILE" | grep -o "[0-9]* failed" | grep -o "[0-9]*" || echo "0")
  SKIPPED=$(grep "Tests:" "$OUTPUT_FILE" | grep -o "[0-9]* skipped" | grep -o "[0-9]*" || echo "0")
  [ -n "$PASSED" ] && TEST_PASSED="$PASSED"
  [ -n "$FAILED" ] && TEST_FAILED="$FAILED"
  [ -n "$SKIPPED" ] && TEST_SKIPPED="$SKIPPED"
  TEST_TOTAL=$((TEST_PASSED + TEST_FAILED + TEST_SKIPPED))
fi

# Mocha: "XX passing" or "YY failing"
if [ "$TEST_TOTAL" -eq 0 ] && grep -q "passing" "$OUTPUT_FILE" 2>/dev/null; then
  PASSED=$(grep "passing" "$OUTPUT_FILE" | grep -o "[0-9]* passing" | grep -o "[0-9]*" || echo "0")
  FAILED=$(grep "failing" "$OUTPUT_FILE" | grep -o "[0-9]* failing" | grep -o "[0-9]*" || echo "0")
  SKIPPED=$(grep "pending" "$OUTPUT_FILE" | grep -o "[0-9]* pending" | grep -o "[0-9]*" || echo "0")
  [ -n "$PASSED" ] && TEST_PASSED="$PASSED"
  [ -n "$FAILED" ] && TEST_FAILED="$FAILED"
  [ -n "$SKIPPED" ] && TEST_SKIPPED="$SKIPPED"
  TEST_TOTAL=$((TEST_PASSED + TEST_FAILED + TEST_SKIPPED))
fi

# pytest: "X passed, Y failed"
if [ "$TEST_TOTAL" -eq 0 ] && grep -q "passed" "$OUTPUT_FILE" 2>/dev/null; then
  PASSED=$(grep -o "[0-9]* passed" "$OUTPUT_FILE" | head -1 | grep -o "[0-9]*" || echo "0")
  FAILED=$(grep -o "[0-9]* failed" "$OUTPUT_FILE" | head -1 | grep -o "[0-9]*" || echo "0")
  SKIPPED=$(grep -o "[0-9]* skipped" "$OUTPUT_FILE" | head -1 | grep -o "[0-9]*" || echo "0")
  [ -n "$PASSED" ] && TEST_PASSED="$PASSED"
  [ -n "$FAILED" ] && TEST_FAILED="$FAILED"
  [ -n "$SKIPPED" ] && TEST_SKIPPED="$SKIPPED"
  TEST_TOTAL=$((TEST_PASSED + TEST_FAILED + TEST_SKIPPED))
fi

# Generic fallback: use exit code as primary signal, then try structured parsing
if [ "$TEST_TOTAL" -eq 0 ]; then
  # Attempt to extract counts from structured test output lines
  # Uses POSIX-compatible regex (no grep -P) for portability across macOS/Linux.
  # Matches patterns like "5 passed", "3 failed", "2 skipped" at end of lines.
  if grep -qE '[0-9]+\s+(passed|passing|failing|failed|skipped|pending)' "$OUTPUT_FILE" 2>/dev/null; then
    TEST_PASSED=$(grep -oE '[0-9]+\s+(passed|passing)\b' "$OUTPUT_FILE" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "0")
    TEST_FAILED=$(grep -oE '[0-9]+\s+(failed|failing)\b' "$OUTPUT_FILE" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "0")
    TEST_SKIPPED=$(grep -oE '[0-9]+\s+(skipped|pending)\b' "$OUTPUT_FILE" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "0")
    # Default to 0 if extraction failed
    TEST_PASSED=${TEST_PASSED:-0}
    TEST_FAILED=${TEST_FAILED:-0}
    TEST_SKIPPED=${TEST_SKIPPED:-0}
    TEST_TOTAL=$((TEST_PASSED + TEST_FAILED + TEST_SKIPPED))
  fi
fi

# If still no counts extracted, check for common test output patterns
# that don't match the structured patterns above (e.g., custom test runners)
if [ "$TEST_TOTAL" -eq 0 ]; then
  # Look for lines like "✓ test name" or "✗ test name" or "PASS test name"
  PASSED_MARKS=$(grep -cE '^\s*[✓✔+]\s' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  FAILED_MARKS=$(grep -cE '^\s*[✗×-]\s' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  if [ "$PASSED_MARKS" -gt 0 ] || [ "$FAILED_MARKS" -gt 0 ]; then
    TEST_PASSED=$PASSED_MARKS
    TEST_FAILED=$FAILED_MARKS
    TEST_TOTAL=$((TEST_PASSED + TEST_FAILED))
  fi
fi

# Final fallback: if no counts could be extracted, warn and use exit code only
if [ "$TEST_TOTAL" -eq 0 ]; then
  # Check if output is empty (command produced no output at all)
  if [ ! -s "$OUTPUT_FILE" ]; then
    TEST_SUMMARY="Test command produced no output (exit code $TEST_EXIT_CODE)"
  else
    TEST_SUMMARY="Test exit code $TEST_EXIT_CODE — could not parse test counts from output"
  fi
  # Use exit code as the sole signal — fall through to standard output
  if [ "$EXPECTED" = "fail" ]; then
    if [ "$TEST_EXIT_CODE" -ne 0 ]; then
      TEST_RESULT="expected_fail"
    else
      TEST_RESULT="unexpected_pass"
    fi
  else
    if [ "$TEST_EXIT_CODE" -eq 0 ]; then
      TEST_RESULT="pass"
    else
      TEST_RESULT="fail"
    fi
  fi
fi

# Determine result
if [ "$EXPECTED" = "fail" ]; then
  # We expected the test to fail
  if [ "$TEST_EXIT_CODE" -ne 0 ]; then
    TEST_RESULT="expected_fail"
    TEST_SUMMARY="Test failed as expected (exit code $TEST_EXIT_CODE)"
  else
    TEST_RESULT="unexpected_pass"
    TEST_SUMMARY="Test passed but was expected to fail — test may not be testing the right thing"
  fi
else
  # We expected the test to pass
  if [ "$TEST_EXIT_CODE" -eq 0 ]; then
    TEST_RESULT="pass"
    TEST_SUMMARY="All tests passed ($TEST_PASSED/$TEST_TOTAL)"
  else
    TEST_RESULT="fail"
    TEST_SUMMARY="$TEST_FAILED test(s) failed (exit code $TEST_EXIT_CODE)"
  fi
fi

# Output key=value pairs (machine-parseable)
echo "TEST_EXIT_CODE=$TEST_EXIT_CODE"
echo "TEST_RESULT=$TEST_RESULT"
echo "TEST_TOTAL=$TEST_TOTAL"
echo "TEST_PASSED=$TEST_PASSED"
echo "TEST_FAILED=$TEST_FAILED"
echo "TEST_SKIPPED=$TEST_SKIPPED"
echo "TEST_OUTPUT_FILE=$OUTPUT_FILE"
echo "TEST_SUMMARY=$TEST_SUMMARY"
