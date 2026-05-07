#!/usr/bin/env bash
# Independent failure diagnosis — runs deterministic checks BEFORE
# the LLM classifies failures. Provides unbiased evidence for
# [T]est Flaw, [I]mplementation Error, [E]nvironment, or [R]egression.
#
# Usage: diagnostic-classifier.sh <feature_dir> <test_output_file> <impl_output_file>
#        diagnostic-classifier.sh --help
#
# Outputs:
#   CLASSIFICATION=[TEST_FAULT|IMPL_ERROR|ENV_FAULT|REGRESSION|AMBIGUOUS]
#   EVIDENCE=... (deterministic findings)
#   CONFIDENCE=high|medium|low
#   FAULTS_FOUND=N
#   TEST_FAULT_COUNT=N
#   REQUIRED_ACTION=[FIX_TEST|FIX_IMPL|HUMAN|RETRY]

set -euo pipefail

FEATURE_DIR="${1:?Usage: diagnostic-classifier.sh <feature_dir> <test_output> <impl_output>}"
TEST_OUTPUT_FILE="${2:-}"
IMPL_OUTPUT_FILE="${3:-}"

if [ "${FEATURE_DIR}" = "--help" ]; then
  echo "Usage: diagnostic-classifier.sh <feature_dir> <test_output_file> <impl_output_file>"
  echo "  test_output_file: path to file containing test runner output (or empty string)"
  echo "  impl_output_file: path to file containing implementation output (or empty string)"
  echo ""
  echo "Outputs: CLASSIFICATION, EVIDENCE, CONFIDENCE, FAULTS_FOUND, TEST_FAULT_COUNT, REQUIRED_ACTION"
  exit 0
fi

EVIDENCE=""
FAULTS_FOUND=0
CLASSIFICATION="AMBIGUOUS"
CONFIDENCE="low"
TEST_FAULT_COUNT=0
REQUIRED_ACTION="RETRY"

# ── Check 1: Test runner config exists ──────────────────────────
check_test_runner() {
  local dir="$FEATURE_DIR"
  local runner_found=false

  if [ -f "$dir/package.json" ] && grep -q '"test"' "$dir/package.json" 2>/dev/null; then
    runner_found=true
  fi
  if [ -f "$dir/pytest.ini" ] || [ -f "$dir/setup.cfg" ] || [ -f "$dir/pyproject.toml" ]; then
    runner_found=true
  fi
  if [ -f "$dir/pom.xml" ] || [ -f "$dir/build.gradle" ] || [ -f "$dir/gradlew" ]; then
    runner_found=true
  fi
  if [ -f "$dir/go.mod" ]; then
    runner_found=true
  fi
  if [ -f "$dir/jest.config.js" ] || [ -f "$dir/jest.config.ts" ]; then
    runner_found=true
  fi

  if [ "$runner_found" = false ]; then
    EVIDENCE="${EVIDENCE}ENV: No test runner configuration found in $dir. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
  fi
}

# ── Check 2: Test output analysis ──────────────────────────────
analyze_test_output() {
  if [ -z "$TEST_OUTPUT_FILE" ] || [ ! -f "$TEST_OUTPUT_FILE" ]; then
    EVIDENCE="${EVIDENCE}ENV: No test output file provided for analysis. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
    return
  fi

  local content
  content=$(cat "$TEST_OUTPUT_FILE" 2>/dev/null || echo "")

  # Check for compilation/import errors (not test failures)
  if echo "$content" | grep -qiE 'SyntaxError|Cannot find module|ImportError|ModuleNotFoundError|ENOENT|cannot resolve symbol'; then
    EVIDENCE="${EVIDENCE}TEST_FAULT: Test file has import/syntax errors — test runner cannot execute. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
    TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
  fi

  # Check for empty mock usage (spy/verify with no real call)
  if echo "$content" | grep -qiE 'spy|mock\(|jest\.fn\(|vi\.fn\(|when\(' 2>/dev/null; then
    if echo "$content" | grep -qiE 'calledTimes\(0\)|notCalled|toHaveBeenCalledTimes\(0\)'; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: Mock was created but never called — test may not exercise real code. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi
  fi

  # Check for timing-related failures (async issues)
  if echo "$content" | grep -qiE 'timeout|timed out|waitFor.*failed|await.*not.*received|Promise.*rejected'; then
    EVIDENCE="${EVIDENCE}TEST_FAULT: Test appears to have async timing issues (timeout/waitFor failure). "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
    TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
  fi

  # Check for assertion errors with specific messages
  if echo "$content" | grep -qiE 'Expected.*received.*but got.*assertion|expect.*failed|AssertionError'; then
    # This is a normal test failure — not a test fault
    :
  fi

  # Check for type mismatch in assertions (string where number expected, etc.)
  if echo "$content" | grep -qiE 'expected.*string.*received.*number|expected.*number.*received.*string|expected.*type.*string.*but received.*number' 2>/dev/null; then
    EVIDENCE="${EVIDENCE}IMPL_ERROR: Type mismatch in assertion — implementation likely returns wrong type. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
  fi

  # Check for HTTP status code mismatch
  if echo "$content" | grep -qiE 'expected.*201.*received.*200|expected.*200.*received.*201|expected.*404.*received.*200|expected.*500.*received.*200|expected.*200.*received.*500' 2>/dev/null; then
    EVIDENCE="${EVIDENCE}IMPL_ERROR: HTTP status mismatch — implementation returns wrong status code. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
  fi

  # Check for assertion on request object instead of response (test bug)
  if echo "$content" | grep -qiE 'request.*expect|expect.*request.*body|expect.*req\b' 2>/dev/null; then
    if ! echo "$content" | grep -qiE 'response.*expect|expect.*response|expect.*res\b' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: Test asserts on request object instead of response — may pass without exercising implementation. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi
  fi

  # Check for async test without proper error handling (silent rejections)
  if echo "$content" | grep -qiE 'it\s*\(\s*[\"'\'']|test\s*\(\s*[\"'\'']' "$content" 2>/dev/null; then
    if echo "$content" | grep -qiE 'async|await|Promise' 2>/dev/null; then
      if ! echo "$content" | grep -qiE 'try|catch|reject|unhandledRejection|\.catch\(' 2>/dev/null; then
        EVIDENCE="${EVIDENCE}TEST_FAULT: Async test without try/catch — rejection silently swallowed. "
        FAULTS_FOUND=$((FAULTS_FOUND + 1))
        TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
      fi
    fi
  fi
}

# ── Check 3: Implementation file structure ─────────────────────
check_impl_structure() {
  if [ -z "$IMPL_OUTPUT_FILE" ] || [ ! -f "$IMPL_OUTPUT_FILE" ]; then
    return
  fi

  local content
  content=$(cat "$IMPL_OUTPUT_FILE" 2>/dev/null || echo "")

  # Check if implementation file was actually created
  if echo "$content" | grep -qiE 'No files created|no changes|nothing to implement'; then
    EVIDENCE="${EVIDENCE}IMPL_ERROR: Implementation produced no output files. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
  fi

  # Check for empty files
  if echo "$content" | grep -qiE 'created.*\.java|created.*\.ts|created.*\.py'; then
    # File was created — this is good, no fault
    :
  fi
}

# ── Check 4: Deterministic test runner check ───────────────────
run_deterministic_test() {
  # Try to actually run the test and capture exit code
  if [ -z "$TEST_OUTPUT_FILE" ] || [ ! -f "$TEST_OUTPUT_FILE" ]; then
    return
  fi

  local content
  content=$(cat "$TEST_OUTPUT_FILE" 2>/dev/null || echo "")

  # If the test output contains "FAIL" or "failed" with actual test failures
  # (not import errors), it's likely an implementation error
  if echo "$content" | grep -qiE 'Test Suites:.*failed|Tests:.*failed|assertion failed|expected.*received'; then
    # Check if it's a test fault (import/syntax error) or impl error
    if ! echo "$content" | grep -qiE 'SyntaxError|Cannot find module|ImportError|ModuleNotFoundError|ENOENT'; then
      EVIDENCE="${EVIDENCE}IMPL_ERROR: Test failure with valid test runner output — implementation does not satisfy acceptance criterion. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
    fi
  fi
}

# ── Run all checks ─────────────────────────────────────────────
check_test_runner
analyze_test_output
check_impl_structure
run_deterministic_test

# ── Determine classification based on evidence ─────────────────
if echo "$EVIDENCE" | grep -q "TEST_FAULT"; then
  CLASSIFICATION="TEST_FAULT"
  CONFIDENCE="high"
elif echo "$EVIDENCE" | grep -q "IMPL_ERROR"; then
  CLASSIFICATION="IMPL_ERROR"
  CONFIDENCE="high"
elif echo "$EVIDENCE" | grep -q "ENV:"; then
  CLASSIFICATION="ENV_FAULT"
  CONFIDENCE="medium"
elif [ "$FAULTS_FOUND" -gt 0 ]; then
  CLASSIFICATION="AMBIGUOUS"
  CONFIDENCE="low"
else
  CLASSIFICATION="AMBIGUOUS"
  CONFIDENCE="low"
fi

# ── Determine REQUIRED_ACTION based on classification + evidence ─
if [ "$CLASSIFICATION" = "TEST_FAULT" ] && [ "$CONFIDENCE" = "high" ]; then
  REQUIRED_ACTION="FIX_TEST"
elif [ "$CLASSIFICATION" = "IMPL_ERROR" ] && [ "$CONFIDENCE" = "high" ]; then
  REQUIRED_ACTION="FIX_IMPL"
elif [ "$CLASSIFICATION" = "ENV_FAULT" ]; then
  REQUIRED_ACTION="FIX_IMPL"
elif [ "$CLASSIFICATION" = "AMBIGUOUS" ] && [ "$CONFIDENCE" = "low" ] && [ "$FAULTS_FOUND" -ge 2 ]; then
  REQUIRED_ACTION="HUMAN"
elif [ "$CLASSIFICATION" = "AMBIGUOUS" ] && [ "$CONFIDENCE" = "low" ]; then
  REQUIRED_ACTION="RETRY"
elif [ "$TEST_FAULT_COUNT" -ge 2 ]; then
  REQUIRED_ACTION="FIX_TEST"
else
  REQUIRED_ACTION="RETRY"
fi

# ── Output results ─────────────────────────────────────────────
echo "CLASSIFICATION=${CLASSIFICATION}"
echo "EVIDENCE='${EVIDENCE}'"
echo "CONFIDENCE=${CONFIDENCE}"
echo "FAULTS_FOUND=${FAULTS_FOUND}"
echo "TEST_FAULT_COUNT=${TEST_FAULT_COUNT}"
echo "REQUIRED_ACTION=${REQUIRED_ACTION}"
