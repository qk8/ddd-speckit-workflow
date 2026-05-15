#!/usr/bin/env bash
# Independent failure diagnosis — runs deterministic checks BEFORE
# the LLM classifies failures. Provides unbiased evidence for
# [T]est Flaw, [I]mplementation Error, [E]nvironment, or [R]egression.
#
# Usage: diagnostic-classifier.sh <feature_dir> [test_type] <test_output_file> <impl_output_file> [acceptance_criteria_file]
#        diagnostic-classifier.sh --help
#
# Outputs:
#   CLASSIFICATION=[TEST_FAULT|IMPL_ERROR|ENV_FAULT|REGRESSION|SPEC_MISMATCH|AMBIGUOUS]
#   EVIDENCE=... (deterministic findings)
#   CONFIDENCE=high|medium|low
#   FAULTS_FOUND=N
#   TEST_FAULT_COUNT=N
#   IMPL_FAULT_COUNT=N
#   MIXED_FAULTS=true|false
#   REQUIRED_ACTION=[FIX_TEST|FIX_IMPL|FIX_ENV|HUMAN|RETRY]

set -euo pipefail

FEATURE_DIR="${1:?Usage: diagnostic-classifier.sh <feature_dir> [test_type] <test_output> <impl_output> [acceptance_criteria]}"
TEST_TYPE="${2:-}"  # Optional: "java", "ts", "js", or auto-detect
TEST_OUTPUT_FILE="${3:-}"
IMPL_OUTPUT_FILE="${4:-}"
ACCEPTANCE_CRITERIA_FILE="${5:-}"

if [ "${FEATURE_DIR}" = "--help" ]; then
  echo "Usage: diagnostic-classifier.sh <feature_dir> [test_type] <test_output_file> <impl_output_file> [acceptance_criteria_file]"
  echo "  test_type: optional language hint — 'java', 'ts', 'js', or empty for auto-detect"
  echo "  test_output_file: path to file containing test runner output (or empty string)"
  echo "  impl_output_file: path to file containing implementation output (or empty string)"
  echo "  acceptance_criteria_file: optional path to tasks.md or plan.md for spec-aware comparison"
  echo ""
  echo "Outputs: CLASSIFICATION, EVIDENCE, CONFIDENCE, FAULTS_FOUND, TEST_FAULT_COUNT, IMPL_FAULT_COUNT, MIXED_FAULTS, REQUIRED_ACTION"
  exit 0
fi

EVIDENCE=""
FAULTS_FOUND=0
CLASSIFICATION="AMBIGUOUS"
CONFIDENCE="low"
TEST_FAULT_COUNT=0
IMPL_FAULT_COUNT=0
MIXED_FAULTS="false"
REQUIRED_ACTION="RETRY"

# ── Auto-detect test type from feature directory ─────────────────
detect_test_type() {
  local dir="$FEATURE_DIR"
  if [ -f "$dir/pom.xml" ] || [ -f "$dir/build.gradle" ] || [ -f "$dir/gradlew" ]; then
    echo "java"
  elif [ -f "$dir/package.json" ] || [ -f "$dir/tsconfig.json" ] || [ -f "$dir/jest.config.js" ] || [ -f "$dir/jest.config.ts" ]; then
    echo "ts"
  else
    echo "auto"
  fi
}

if [ -z "$TEST_TYPE" ] || [ "$TEST_TYPE" = "auto" ]; then
  TEST_TYPE=$(detect_test_type)
fi

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

# ── Check 2: Test output analysis (language-specific) ───────────
analyze_test_output() {
  if [ -z "$TEST_OUTPUT_FILE" ] || [ ! -f "$TEST_OUTPUT_FILE" ]; then
    EVIDENCE="${EVIDENCE}ENV: No test output file provided for analysis. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
    return
  fi

  local content
  content=$(cat "$TEST_OUTPUT_FILE" 2>/dev/null || echo "")

  # ── Shared: compilation/import errors (not test failures) ──
  if echo "$content" | grep -qiE 'SyntaxError|Cannot find module|ImportError|ModuleNotFoundError|ENOENT|cannot resolve symbol'; then
    EVIDENCE="${EVIDENCE}TEST_FAULT: Test file has import/syntax errors — test runner cannot execute. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
    TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
  fi

  # ── Shared: empty mock usage ──
  if echo "$content" | grep -qiE 'spy|mock\(|jest\.fn\(|vi\.fn\(|when\(' 2>/dev/null; then
    if echo "$content" | grep -qiE 'calledTimes\(0\)|notCalled|toHaveBeenCalledTimes\(0\)'; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: Mock was created but never called — test may not exercise real code. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi
  fi

  # ── Shared: timing-related failures (async issues) ──
  if echo "$content" | grep -qiE 'timeout|timed out|waitFor.*failed|await.*not.*received|Promise.*rejected'; then
    EVIDENCE="${EVIDENCE}TEST_FAULT: Test appears to have async timing issues (timeout/waitFor failure). "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
    TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
  fi

  # ── Shared: assertion on request object instead of response (test bug) ──
  if echo "$content" | grep -qiE 'request.*expect|expect.*request.*body|expect.*req\b' 2>/dev/null; then
    if ! echo "$content" | grep -qiE 'response.*expect|expect.*response|expect.*res\b' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: Test asserts on request object instead of response — may pass without exercising implementation. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi
  fi

  # ── Shared: async test without proper error handling ──
  if echo "$content" | grep -qiE 'it\s*\(\s*[\"'\'']|test\s*\(\s*[\"'\'']' "$content" 2>/dev/null; then
    if echo "$content" | grep -qiE 'async|await|Promise' 2>/dev/null; then
      if ! echo "$content" | grep -qiE 'try|catch|reject|unhandledRejection|\.catch\(' 2>/dev/null; then
        EVIDENCE="${EVIDENCE}TEST_FAULT: Async test without try/catch — rejection silently swallowed. "
        FAULTS_FOUND=$((FAULTS_FOUND + 1))
        TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
      fi
    fi
  fi

  # ── Java-specific patterns (JUnit 5 + TestNG) ──
  if [ "$TEST_TYPE" = "java" ] || [ "$TEST_TYPE" = "auto" ]; then
    # JUnit 5 assertion failures
    if echo "$content" | grep -q 'org.opentest4j.AssertionFailedError' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: JUnit 5 AssertionFailedError detected — test assertion itself failed. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi
    if echo "$content" | grep -q 'java.lang.AssertionError' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: Java AssertionError detected — test assertion failed. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi

    # JUnit 5 output format: "Expected :X / Actual   :Y"
    if echo "$content" | grep -qE 'Expected\s+[:\s]' 2>/dev/null && echo "$content" | grep -qE 'Actual\s+[:\s]' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}IMPL_ERROR: JUnit 5 Expected/Actual mismatch — implementation returns wrong value. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      IMPL_FAULT_COUNT=$((IMPL_FAULT_COUNT + 1))
    fi

    # Mockito faults
    if echo "$content" | grep -qiE 'MockitoException|NotAMockException|Wanted.*but not invoked|Unnecessary stubbings' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: Mockito exception — test mocking setup is incorrect. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi

    # Spring/DB setup faults
    if echo "$content" | grep -qiE 'BeanCreationException|PersistenceException|DataSource.*not found|H2.*embedded' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}ENV_FAULT: Spring/DB context setup failure — test environment misconfigured. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
    fi

    # Timeout/Thread faults (env/setup)
    if echo "$content" | grep -qiE 'TimeoutException|InterruptedException|org.junit.jupiter.api.extension.ExecutionConditionException' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}ENV_FAULT: Test environment timeout or thread interruption. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
    fi
  fi

  # ── TypeScript-specific patterns ──
  if [ "$TEST_TYPE" = "ts" ] || [ "$TEST_TYPE" = "auto" ] || [ "$TEST_TYPE" = "js" ]; then
    # Jest matcher failure format: "Expected value to be equal / Received"
    # Also handles standard format: "Expected: X\nReceived: Y" on separate lines
    local has_jest_failure=false
    if echo "$content" | grep -qE 'Expected.*to be equal|Expected.*to equal|Expected.*toBe|Expected.*toEqual' 2>/dev/null; then
      has_jest_failure=true
    fi
    if echo "$content" | grep -qE '^Expected:' 2>/dev/null && echo "$content" | grep -qE '^Received:' 2>/dev/null; then
      has_jest_failure=true
    fi
    if [ "$has_jest_failure" = true ]; then
      # Distinguish: if the "received" value looks like a plausible wrong implementation output → IMPL_ERROR
      if echo "$content" | grep -qE 'Received.*undefined|Received.*null.*when.*expected|Received.*NaN' 2>/dev/null; then
        EVIDENCE="${EVIDENCE}IMPL_ERROR: Jest matcher failure with undefined/null/NaN — implementation returns invalid value. "
        FAULTS_FOUND=$((FAULTS_FOUND + 1))
        IMPL_FAULT_COUNT=$((IMPL_FAULT_COUNT + 1))
      else
        EVIDENCE="${EVIDENCE}IMPL_ERROR: Jest matcher failure — expected value does not match received. "
        FAULTS_FOUND=$((FAULTS_FOUND + 1))
        IMPL_FAULT_COUNT=$((IMPL_FAULT_COUNT + 1))
      fi
    fi

    # Runtime errors within test code
    if echo "$content" | grep -qiE '^TypeError:|^ReferenceError:|^RangeError:' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: Runtime error in test code — TypeError/ReferenceError/RangeError. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi

    # TS compilation faults
    if echo "$content" | grep -qiE 'TSError|tsconfig|Cannot find module.*\.ts|Property.*does not exist on type' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: TypeScript compilation error — test file has type errors. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi

    # ORM validation in tests
    if echo "$content" | grep -qiE 'PrismaClientValidationError|SequelizeValidationError|ZodError|YupValidationError' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}TEST_FAULT: ORM/schema validation error in test — test data doesn't match schema. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      TEST_FAULT_COUNT=$((TEST_FAULT_COUNT + 1))
    fi

    # AggregateError (Promise.allSettled failures)
    if echo "$content" | grep -qiE 'AggregateError' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}IMPL_ERROR: AggregateError — multiple async operations failed, likely implementation issue. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
      IMPL_FAULT_COUNT=$((IMPL_FAULT_COUNT + 1))
    fi

    # Distinguish jest.fn() not-mocked (IMPL_ERROR) vs expect() wrong-value (TEST_FAULT)
    # If jest.fn() is mentioned but the failure is about the mock's return value (not about it not being called)
    if echo "$content" | grep -qiE 'jest\.fn\(|vi\.fn\(|spyOn\(' 2>/dev/null; then
      if echo "$content" | grep -qiE 'calledTimes\(0\)|notCalled|toHaveBeenCalledTimes\(0\)'; then
        : # Already handled above as TEST_FAULT
      else
        # Mock is called but returns wrong value → IMPL_ERROR (the mock setup is fine, the impl doesn't use it correctly)
        if echo "$content" | grep -qiE 'expected.*to return|returnValue|mockReturnValue' 2>/dev/null; then
          EVIDENCE="${EVIDENCE}IMPL_ERROR: Mock return value mismatch — implementation may not use mocked dependency correctly. "
          FAULTS_FOUND=$((FAULTS_FOUND + 1))
          IMPL_FAULT_COUNT=$((IMPL_FAULT_COUNT + 1))
        fi
      fi
    fi
  fi

  # ── Shared: type mismatch ──
  if echo "$content" | grep -qiE 'expected.*string.*received.*number|expected.*number.*received.*string|expected.*type.*string.*but received.*number' 2>/dev/null; then
    EVIDENCE="${EVIDENCE}IMPL_ERROR: Type mismatch in assertion — implementation likely returns wrong type. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
  fi

  # ── Shared: HTTP status code mismatch ──
  if echo "$content" | grep -qiE 'expected.*201.*received.*200|expected.*200.*received.*201|expected.*404.*received.*200|expected.*500.*received.*200|expected.*200.*received.*500' 2>/dev/null; then
    EVIDENCE="${EVIDENCE}IMPL_ERROR: HTTP status mismatch — implementation returns wrong status code. "
    FAULTS_FOUND=$((FAULTS_FOUND + 1))
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

# ── Check 5: Spec-aware comparison (optional) ──────────────────
check_spec_mismatch() {
  if [ -z "$ACCEPTANCE_CRITERIA_FILE" ] || [ ! -f "$ACCEPTANCE_CRITERIA_FILE" ]; then
    return
  fi

  if [ -z "$TEST_OUTPUT_FILE" ] || [ ! -f "$TEST_OUTPUT_FILE" ]; then
    return
  fi

  local criteria_content test_content
  criteria_content=$(cat "$ACCEPTANCE_CRITERIA_FILE" 2>/dev/null || echo "")
  test_content=$(cat "$TEST_OUTPUT_FILE" 2>/dev/null || echo "")

  # Extract expected HTTP status codes from acceptance criteria
  local expected_status
  expected_status=$(echo "$criteria_content" | grep -oiE '(returns|status|response).*[2345][0-9]{2}' | grep -oE '[2345][0-9]{2}' | head -1 || true)

  if [ -n "$expected_status" ]; then
    # Check if test output shows a different status code
    local actual_status
    actual_status=$(echo "$test_content" | grep -oiE 'received.*[2345][0-9]{2}' | grep -oE '[2345][0-9]{2}' | head -1 || true)
    if [ -n "$actual_status" ] && [ "$actual_status" != "$expected_status" ]; then
      EVIDENCE="${EVIDENCE}SPEC_MISMATCH: Spec expects HTTP $expected_status but test shows HTTP $actual_status — implementation may follow spec differently than written. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
    fi
  fi

  # Extract expected exception/throw patterns from acceptance criteria
  local expected_throw
  expected_throw=$(echo "$criteria_content" | grep -oiE '(throws|raises|exception).*[A-Z][a-zA-Z]+' | grep -oE '[A-Z][a-zA-Z]+' | head -1 || true)
  if [ -n "$expected_throw" ]; then
    # Check if test output shows a different exception
    if echo "$test_content" | grep -qE '(\w+Exception|\w+Error)' 2>/dev/null; then
      local actual_throw
      actual_throw=$(echo "$test_content" | grep -oE '[A-Z][a-zA-Z]+(Exception|Error)' | head -1 || true)
      if [ -n "$actual_throw" ] && [ "$actual_throw" != "$expected_throw" ]; then
        EVIDENCE="${EVIDENCE}SPEC_MISMATCH: Spec expects $expected_throw but test shows $actual_throw — wrong exception type. "
        FAULTS_FOUND=$((FAULTS_FOUND + 1))
      fi
    fi
  fi

  # Extract validation patterns from acceptance criteria (e.g., "validates email format", "must be between X and Y")
  local expected_range
  expected_range=$(echo "$criteria_content" | grep -oiE '(between|range|length).*[0-9]+.*[0-9]+' | head -1 || true)
  if [ -n "$expected_range" ]; then
    if echo "$test_content" | grep -qiE 'out of range|invalid.*length|too short|too long' 2>/dev/null; then
      EVIDENCE="${EVIDENCE}SPEC_MISMATCH: Spec defines a range but test reports out-of-range — boundary implementation may differ from spec. "
      FAULTS_FOUND=$((FAULTS_FOUND + 1))
    fi
  fi
}

# ── Run all checks ─────────────────────────────────────────────
check_test_runner
analyze_test_output
check_impl_structure
run_deterministic_test
check_spec_mismatch

# ── Detect mixed faults ────────────────────────────────────────
if [ "$TEST_FAULT_COUNT" -gt 0 ] && [ "$IMPL_FAULT_COUNT" -gt 0 ]; then
  MIXED_FAULTS="true"
fi

# ── Determine classification based on evidence ─────────────────
if [ "$MIXED_FAULTS" = "true" ]; then
  CLASSIFICATION="AMBIGUOUS"
  CONFIDENCE="high"
  EVIDENCE="${EVIDENCE}MIXED: Both TEST_FAULT ($TEST_FAULT_COUNT) and IMPL_ERROR ($IMPL_FAULT_COUNT) detected simultaneously. "
elif echo "$EVIDENCE" | grep -q "SPEC_MISMATCH"; then
  CLASSIFICATION="SPEC_MISMATCH"
  CONFIDENCE="high"
elif echo "$EVIDENCE" | grep -q "TEST_FAULT"; then
  CLASSIFICATION="TEST_FAULT"
  CONFIDENCE="high"
elif echo "$EVIDENCE" | grep -q "IMPL_ERROR"; then
  CLASSIFICATION="IMPL_ERROR"
  CONFIDENCE="high"
elif echo "$EVIDENCE" | grep -q "ENV_FAULT"; then
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
if [ "$MIXED_FAULTS" = "true" ]; then
  REQUIRED_ACTION="HUMAN"
elif [ "$CLASSIFICATION" = "SPEC_MISMATCH" ]; then
  REQUIRED_ACTION="HUMAN"
elif [ "$CLASSIFICATION" = "TEST_FAULT" ] && [ "$CONFIDENCE" = "high" ]; then
  REQUIRED_ACTION="FIX_TEST"
elif [ "$CLASSIFICATION" = "IMPL_ERROR" ] && [ "$CONFIDENCE" = "high" ]; then
  REQUIRED_ACTION="FIX_IMPL"
elif [ "$CLASSIFICATION" = "ENV_FAULT" ]; then
  REQUIRED_ACTION="FIX_ENV"
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
echo "IMPL_FAULT_COUNT=${IMPL_FAULT_COUNT}"
echo "MIXED_FAULTS=${MIXED_FAULTS}"
echo "REQUIRED_ACTION=${REQUIRED_ACTION}"
