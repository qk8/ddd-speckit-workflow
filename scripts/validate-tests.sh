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
( eval "$TEST_COMMAND" ) >"$OUTPUT_FILE" 2>&1 || TEST_EXIT_CODE=$?

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

# Generic fallback: count "✓" and "✗" or "FAIL"/"PASS" markers
if [ "$TEST_TOTAL" -eq 0 ]; then
  PASSED=$(grep -c "✓\|PASS\|✔\|ok\b" "$OUTPUT_FILE" 2>/dev/null || echo "0")
  FAILED=$(grep -c "✗\|FAIL\|✘\|error\|AssertionError" "$OUTPUT_FILE" 2>/dev/null || echo "0")
  if [ "$FAILED" -gt 0 ]; then
    TEST_PASSED=$((PASSED - FAILED))
    [ "$TEST_PASSED" -lt 0 ] && TEST_PASSED=0
    TEST_FAILED="$FAILED"
    TEST_TOTAL=$((TEST_PASSED + TEST_FAILED))
  elif [ "$PASSED" -gt 0 ]; then
    TEST_PASSED="$PASSED"
    TEST_TOTAL="$PASSED"
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
