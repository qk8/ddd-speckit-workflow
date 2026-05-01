#!/usr/bin/env bash
# Regression Tests (Check BC)
# Executes the regression test command defined in plan.md §13 (Testing Strategy)
# and reports PASS/FAIL — verifying no existing tests broke.
set -euo pipefail

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_DIR" ]; then
  echo "REGRESSION: SKIP (no feature directory)"
  exit 0
fi

PLAN_FILE="${FEATURE_DIR}/plan.md"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

RESULT_FILE="${RESULTS_DIR}/BC.result"

# ── Extract regression command from plan.md ─────────────────────
# Looks in §13 (Testing Strategy) for lines like:
#   regression_command.all: npm test
#   regression_command.api_only: pytest tests/api/
# Falls back to common patterns if not found.
extract_regression_command() {
  if [ ! -f "$PLAN_FILE" ]; then
    return 1
  fi

  # Search for regression_command.all: or regression_command.api_only:
  local cmd
  cmd=$(grep -E '^\s*regression_command\.(all|api_only)\s*:\s*' "$PLAN_FILE" 2>/dev/null | tail -1 | sed 's/^[^:]*:\s*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

  if [ -n "$cmd" ]; then
    echo "$cmd"
    return 0
  fi

  # ── Fallback: auto-detect common test commands ──────────────
  # Heuristic: look at package.json, requirements.txt, pom.xml, go.mod, build.gradle
  local has_node has_python has_java has_go

  has_node=false
  has_python=false
  has_java=false
  has_go=false

  if [ -f "$FEATURE_DIR/package.json" ] || [ -f "package.json" ]; then
    has_node=true
  fi
  if [ -f "$FEATURE_DIR/requirements.txt" ] || [ -f "requirements.txt" ] || [ -f "$FEATURE_DIR/Pipfile" ] || [ -f "$FEATURE_DIR/pyproject.toml" ] || [ -f "requirements.txt" ]; then
    has_python=true
  fi
  if [ -f "$FEATURE_DIR/pom.xml" ] || [ -f "pom.xml" ]; then
    has_java=true
  fi
  if [ -f "$FEATURE_DIR/go.mod" ] || [ -f "go.mod" ]; then
    has_go=true
  fi

  # Also check src directory structure for language hints
  if echo "$FEATURE_DIR" | grep -qiE '/(src|lib)/' 2>/dev/null; then
    if ls "$FEATURE_DIR" 2>/dev/null | grep -qiE '\.java$'; then
      has_java=true
    fi
    if ls "$FEATURE_DIR" 2>/dev/null | grep -qiE '\.go$'; then
      has_go=true
    fi
    if ls "$FEATURE_DIR" 2>/dev/null | grep -qiE '\.(py|rb)$'; then
      has_python=true
    fi
  fi

  # Node.js
  if [ "$has_node" = true ]; then
    # Check for CI-friendly scripts first
    if grep -q '"test:ci"' "$FEATURE_DIR/package.json" 2>/dev/null || grep -q '"test:ci"' "package.json" 2>/dev/null; then
      echo "npm run test:ci"
      return 0
    fi
    if [ -f "$FEATURE_DIR/node_modules/.bin/jest" ] || [ -f "node_modules/.bin/jest" ]; then
      echo "npm test"
      return 0
    fi
    if [ -f "$FEATURE_DIR/yarn.lock" ] || [ -f "yarn.lock" ]; then
      echo "yarn test"
      return 0
    fi
    echo "npm test"
    return 0
  fi

  # Python
  if [ "$has_python" = true ]; then
    if [ -f "$FEATURE_DIR/pytest.ini" ] || [ -f "pytest.ini" ] || [ -f "$FEATURE_DIR/setup.cfg" ] || [ -f "setup.cfg" ]; then
      echo "python -m pytest"
      return 0
    fi
    echo "pytest"
    return 0
  fi

  # Java
  if [ "$has_java" = true ]; then
    if [ -f "$FEATURE_DIR/mvnw" ] || [ -f "mvnw" ]; then
      echo "./mvnw test"
      return 0
    fi
    if [ -f "$FEATURE_DIR/gradlew" ] || [ -f "gradlew" ]; then
      echo "gradle test"
      return 0
    fi
    if [ -f "$FEATURE_DIR/pom.xml" ] || [ -f "pom.xml" ]; then
      echo "mvn test"
      return 0
    fi
    return 1
  fi

  # Go
  if [ "$has_go" = true ]; then
    echo "go test ./..."
    return 0
  fi

  return 1
}

REGRESSION_COMMAND=$(extract_regression_command 2>/dev/null || true)

if [ -z "$REGRESSION_COMMAND" ]; then
  echo "REGRESSION: SKIP (no regression_command configured in plan.md)"
  echo "PASS" > "$RESULT_FILE"
  exit 0
fi

# ── Execute the command via validate-tests.sh or directly ──────
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPTS_DIR/validate-tests.sh" ]; then
  # Use validate-tests.sh — captures full output, parses test runner results
  VALIDATE_OUTPUT=$(bash "$SCRIPTS_DIR/validate-tests.sh" "$REGRESSION_COMMAND" "pass" 2>&1)

  # Print the command and full validate output
  echo "REGRESSION: ${REGRESSION_COMMAND}"
  echo "$VALIDATE_OUTPUT"

  # Extract result from validate-tests.sh output
  TEST_EXIT_CODE=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_EXIT_CODE=" | cut -d= -f2)
  TEST_RESULT=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_RESULT=" | cut -d= -f2)
  TEST_PASSED=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_PASSED=" | cut -d= -f2 || echo "0")
  TEST_FAILED=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_FAILED=" | cut -d= -f2 || echo "0")
  TEST_TOTAL=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_TOTAL=" | cut -d= -f2 || echo "0")
  # TEST_OUTPUT_FILE from validate-tests.sh
  TEST_OUTPUT_FILE=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_OUTPUT_FILE=" | cut -d= -f2 || echo "")

  # Determine PASS/FAIL for BC check
  BC_EXIT_CODE=0
  if [ "$TEST_RESULT" = "fail" ]; then
    BC_EXIT_CODE=1
  fi
else
  # No validate-tests.sh — run directly
  OUTPUT=""
  EXIT_CODE=0
  OUTPUT=$(eval "$REGRESSION_COMMAND" 2>&1) || EXIT_CODE=$?

  echo "REGRESSION: ${REGRESSION_COMMAND}"
  if [ -n "$OUTPUT" ]; then
    echo "$OUTPUT"
  fi

  TEST_EXIT_CODE=$EXIT_CODE
  BC_EXIT_CODE=$EXIT_CODE

  # Try to parse test counts from output
  TEST_PASSED=0
  TEST_FAILED=0
  TEST_TOTAL=0

  # Try common patterns
  if echo "$OUTPUT" | grep -q "Test Suites:" 2>/dev/null; then
    TEST_PASSED=$(echo "$OUTPUT" | grep "Test Suites:" | grep -o "[0-9]* passed" | grep -o "[0-9]*" || echo "0")
    TEST_FAILED=$(echo "$OUTPUT" | grep "Test Suites:" | grep -o "[0-9]* failed" | grep -o "[0-9]*" || echo "0")
    TEST_TOTAL=$((TEST_PASSED + TEST_FAILED))
  elif echo "$OUTPUT" | grep -q "Tests:" 2>/dev/null; then
    TEST_PASSED=$(echo "$OUTPUT" | grep "Tests:" | grep -o "[0-9]* passed" | grep -o "[0-9]*" || echo "0")
    TEST_FAILED=$(echo "$OUTPUT" | grep "Tests:" | grep -o "[0-9]* failed" | grep -o "[0-9]*" || echo "0")
    TEST_TOTAL=$((TEST_PASSED + TEST_FAILED))
  elif echo "$OUTPUT" | grep -q "passing" 2>/dev/null; then
    TEST_PASSED=$(echo "$OUTPUT" | grep "passing" | grep -o "[0-9]* passing" | grep -o "[0-9]*" || echo "0")
    TEST_FAILED=$(echo "$OUTPUT" | grep "failing" | grep -o "[0-9]* failing" | grep -o "[0-9]*" || echo "0")
    TEST_TOTAL=$((TEST_PASSED + TEST_FAILED))
  elif echo "$OUTPUT" | grep -q "passed" 2>/dev/null; then
    TEST_PASSED=$(echo "$OUTPUT" | grep -o "[0-9]* passed" | head -1 | grep -o "[0-9]*" || echo "0")
    TEST_FAILED=$(echo "$OUTPUT" | grep -o "[0-9]* failed" | head -1 | grep -o "[0-9]*" || echo "0")
    TEST_TOTAL=$((TEST_PASSED + TEST_FAILED))
  fi

  # Defaults if still zero
  : "${TEST_PASSED:=0}"
  : "${TEST_FAILED:=0}"
  : "${TEST_TOTAL:=0}"
fi

# ── Write results ──────────────────────────────────────────────
TOTAL_TESTS=${TEST_TOTAL:-0}
NEW_FAILURES=${TEST_FAILED:-0}

if [ "$BC_EXIT_CODE" -eq 0 ]; then
  {
    echo "PASS"
    echo "REGRESSION: PASS — 0 new failures, ${TOTAL_TESTS} total tests"
  } > "$RESULT_FILE"
  echo "REGRESSION: PASS — 0 new failures, ${TOTAL_TESTS} total tests"
  exit 0
else
  {
    echo "FAIL"
    echo "REGRESSION: FAIL — ${NEW_FAILURES} new failure(s) found"
  } > "$RESULT_FILE"
  echo "REGRESSION: FAIL — ${NEW_FAILURES} new failure(s) found"
  exit 1
fi
