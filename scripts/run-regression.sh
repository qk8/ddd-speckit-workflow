#!/usr/bin/env bash
# Regression Tests (Check BC)
# Executes the regression test command defined in plan.md §13 (Testing Strategy)
# and reports PASS/FAIL — verifying no existing tests broke.
#
# Usage:
#   run-regression.sh <feature_dir>          # Full regression suite
#   run-regression.sh --changed-only <dir>   # Run only tests affected by recent changes
set -euo pipefail

CHANGED_ONLY=false
FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  echo "REGRESSION: SKIP (no feature directory)"
  exit 0
fi

# Handle --changed-only flag
if [ "$FEATURE_DIR" = "--changed-only" ]; then
  CHANGED_ONLY=true
  FEATURE_DIR="${2:-}"
  if [ -z "$FEATURE_DIR" ]; then
    echo "REGRESSION: SKIP (no feature directory)"
    exit 0
  fi
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

# ── Changed-only mode: scope regression to affected tests ──────
extract_changed_tests() {
  local feature_dir="$1"
  local tasks_file="${feature_dir}/tasks.md"

  # Count DONE tasks to determine diff baseline.
  # NOTE: Task IDs (TASK-3, etc.) are NOT git commit hashes and cannot be
  # used as git revisions. We count actual DONE entries in tasks.md and
  # use HEAD~N to diff against the last N completed tasks.
  if [ ! -f "$tasks_file" ]; then
    return 1
  fi

  local done_count
  done_count=$(grep -c "^Status: DONE$" "$tasks_file" 2>/dev/null || echo 0)
  if [ "$done_count" -eq 0 ]; then
    return 1
  fi

  # Count DONE tasks to determine diff baseline.
  # NOTE: Task IDs (TASK-3, etc.) are NOT git commit hashes and cannot be
  # used as git revisions. We count actual DONE entries in tasks.md and
  # use HEAD~N to diff against the last N completed tasks.
  local done_count
  done_count=$(grep -c "^Status: DONE$" "$tasks_file" 2>/dev/null || echo 0)
  if [ "$done_count" -gt 0 ]; then
    changed_files=$(git diff --name-only "HEAD~${done_count}..HEAD" 2>/dev/null || true)
  else
    changed_files=$(git diff --name-only HEAD~1..HEAD 2>/dev/null || true)
  fi

  # If git diff fails (no commits, not a repo, etc.), fallback
  if [ -z "$changed_files" ]; then
    return 1
  fi

  # Map changed source files to affected test files
  # Uses common naming conventions: src/foo.ts → tests/unit/foo.test.ts
  # or src/foo.ts → tests/foo.test.ts
  local test_files=""
  while IFS= read -r src_file; do
    [ -z "$src_file" ] && continue
    # Skip test files themselves
    echo "$src_file" | grep -qE '/(test|spec|__tests__)/' && continue
    # Skip node_modules, build outputs
    echo "$src_file" | grep -qE '(node_modules|dist|build|vendor)' && continue

    local base ext
    base=$(basename "$src_file" | sed 's/\.[^.]*$//')
    ext="${src_file##*.}"

    # Only process source files (not config, docs, etc.)
    case "$ext" in
      ts|js|py|java|kt|go|rb) ;;
      *) continue ;;
    esac

    # Find matching test files using naming conventions
    # Convention 1: tests/unit/<base>.test.<ext>
    # Convention 2: tests/<base>.test.<ext>
    # Convention 3: <base>.test.<ext>
    # Convention 4: <base>.spec.<ext>
    for pattern in \
      "${feature_dir}/tests/unit/${base}.test.${ext}" \
      "${feature_dir}/tests/unit/${base}.spec.${ext}" \
      "${feature_dir}/tests/${base}.test.${ext}" \
      "${feature_dir}/tests/${base}.spec.${ext}" \
      "${base}.test.${ext}" \
      "${base}.spec.${ext}" \
      "${feature_dir}/tests/unit/${base}_test.${ext}" \
      "${feature_dir}/tests/${base}_test.${ext}" \
      "${feature_dir}/tests/unit/test_${base}.${ext}" \
      "${feature_dir}/tests/test_${base}.${ext}" \
      "${feature_dir}/test_${base}.${ext}" \
      "${feature_dir}/tests/${base}Test.${ext}" \
      "${feature_dir}/tests/unit/${base}Test.${ext}" \
      "${feature_dir}/__tests__/${base}.test.${ext}" \
    ; do
      if [ -f "$pattern" ]; then
        test_files="${test_files}${pattern} "
      fi
    done

    # Also check: if the source file itself IS a test file, run it directly
    if echo "$src_file" | grep -qiE '(test|spec)'; then
      test_files="${test_files}${src_file} "
    fi
  done <<< "$changed_files"

  if [ -n "$test_files" ]; then
    echo "$test_files" | tr ' ' '\n' | sort -u | tr '\n' ' '
    return 0
  fi
  return 1
}

if [ "$CHANGED_ONLY" = true ]; then
  CHANGED_TEST_FILES=$(extract_changed_tests "$FEATURE_DIR" 2>/dev/null || true)
  if [ -n "$CHANGED_TEST_FILES" ]; then
    echo "REGRESSION (changed-only): ${CHANGED_TEST_FILES}" >&2
    # Run only the affected test files via the test runner
    # Detect test runner and pass file list
    REGRESSION_COMMAND=$(extract_regression_command 2>/dev/null || true)
    if [ -n "$REGRESSION_COMMAND" ]; then
      # Append changed test files to the command
      # Most test runners accept file arguments: npm test file1 file2, pytest file1 file2
      REGRESSION_COMMAND="${REGRESSION_COMMAND} ${CHANGED_TEST_FILES}"
    fi
  else
    echo "REGRESSION (changed-only): no affected tests found, falling back to full suite" >&2
    REGRESSION_COMMAND=$(extract_regression_command 2>/dev/null || true)
  fi
else
  REGRESSION_COMMAND=$(extract_regression_command 2>/dev/null || true)
fi

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
  # Use bash -c instead of eval to avoid executing in current shell context.
  # plan.md commands are human-approved, but bash -c adds a safety boundary.
  OUTPUT=$(bash -c "$REGRESSION_COMMAND" 2>&1) || EXIT_CODE=$?

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
