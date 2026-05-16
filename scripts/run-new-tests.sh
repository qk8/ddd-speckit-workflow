#!/usr/bin/env bash
# New Tests Verification (Check BC / test_execution.new_tests)
# Verifies that new test files created in this task compile and run.
#
# Usage: run-new-tests.sh <feature_dir>
#
# Writes PASS/FAIL to .artifacts/check-results/test_execution_new_tests.result

set -euo pipefail

FEATURE_DIR="${1:?Usage: run-new-tests.sh <feature_dir>}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

echo "NEW TESTS: Scanning ${FEATURE_DIR}"

# ── Detect project type ──────────────────────────────────────────
PROJECT_TYPE=""
if [ -f "${FEATURE_DIR}/package.json" ]; then
  PROJECT_TYPE="node"
elif [ -f "${FEATURE_DIR}/requirements.txt" ] || [ -f "${FEATURE_DIR}/setup.py" ] || [ -f "${FEATURE_DIR}/pyproject.toml" ]; then
  PROJECT_TYPE="python"
elif [ -f "${FEATURE_DIR}/pom.xml" ]; then
  PROJECT_TYPE="java_maven"
elif [ -f "${FEATURE_DIR}/build.gradle" ] || [ -f "${FEATURE_DIR}/build.gradle.kts" ]; then
  PROJECT_TYPE="java_gradle"
elif [ -f "${FEATURE_DIR}/go.mod" ]; then
  PROJECT_TYPE="go"
fi

if [ -z "$PROJECT_TYPE" ]; then
  echo "NEW TESTS: SKIP (no recognized project type in ${FEATURE_DIR})"
  echo "SKIP" > "${RESULTS_DIR}/test_execution_new_tests.result"
  exit 0
fi

# ── Detect test command from project files ───────────────────────
TEST_CMD=""
case "$PROJECT_TYPE" in
  node)
    if command -v npm &>/dev/null; then
      TEST_CMD="npm test"
    elif command -v yarn &>/dev/null; then
      TEST_CMD="yarn test"
    fi
    ;;
  python)
    TEST_CMD="pytest"
    ;;
  java_maven)
    TEST_CMD="mvn test"
    ;;
  java_gradle)
    TEST_CMD="./gradlew test"
    ;;
  go)
    TEST_CMD="go test ./..."
    ;;
esac

if [ -z "$TEST_CMD" ]; then
  echo "NEW TESTS: SKIP (no test command found for ${PROJECT_TYPE})"
  echo "SKIP" > "${RESULTS_DIR}/test_execution_new_tests.result"
  exit 0
fi

# ── Find new test files via git diff ─────────────────────────────
NEW_TEST_FILES=""
if command -v git &>/dev/null && git -C "$FEATURE_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
  # Get newly added or modified test files from git
  NEW_TEST_FILES=$(git -C "$FEATURE_DIR" diff --name-only --diff-filter=ACM HEAD 2>/dev/null | grep -iE '(test|spec)' | grep -vE '\.md$' || true)

  # If no git diff available (no commits yet), scan for test files in the feature dir
  if [ -z "$NEW_TEST_FILES" ]; then
    NEW_TEST_FILES=$(find "$FEATURE_DIR" -type f \( -name '*test*' -o -name '*_test*' -o -name '*.spec.*' -o -name '*_spec*' \) \
      ! -name '*.md' ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/vendor/*' 2>/dev/null || true)
  fi
else
  # No git: scan for test files
  NEW_TEST_FILES=$(find "$FEATURE_DIR" -type f \( -name '*test*' -o -name '*_test*' -o -name '*.spec.*' -o -name '*_spec*' \) \
    ! -name '*.md' ! -path '*/node_modules/*' ! -path '*/vendor/*' 2>/dev/null || true)
fi

# Filter to only files that exist and are not in artifacts/.artifacts
NEW_TEST_FILES=$(echo "$NEW_TEST_FILES" | grep -v '/\.artifacts/' | grep -v '/tests/' || echo "$NEW_TEST_FILES" | grep -v '/\.artifacts/' || true)

# Remove leading feature_dir path for cleaner output
CLEAN_TESTS=$(echo "$NEW_TEST_FILES" | sed "s|^${FEATURE_DIR}/||" | grep -v '^$' || true)

if [ -z "$CLEAN_TESTS" ]; then
  echo "NEW TESTS: SKIP (no new test files detected)"
  echo "SKIP" > "${RESULTS_DIR}/test_execution_new_tests.result"
  exit 0
fi

TEST_COUNT=$(echo "$CLEAN_TESTS" | grep -cv '^$' || echo 0)
echo "NEW TESTS: Found ${TEST_COUNT} new test file(s):"
echo "$CLEAN_TESTS" | while read -r f; do echo "  - $f"; done

# ── Run tests ────────────────────────────────────────────────────
cd "$FEATURE_DIR"
OUTPUT=$(eval "$TEST_CMD" 2>&1) || {
  echo "NEW TESTS: FAIL"
  echo "$OUTPUT" >&2
  echo "FAIL" > "${RESULTS_DIR}/test_execution_new_tests.result"
  echo "---" >> "${RESULTS_DIR}/test_execution_new_tests.result"
  echo "$OUTPUT" >> "${RESULTS_DIR}/test_execution_new_tests.result"
  exit 1
}

echo "NEW TESTS: PASS — new tests compiled and ran successfully"
echo "PASS" > "${RESULTS_DIR}/test_execution_new_tests.result"
exit 0
