#!/usr/bin/env bash
# Adversarial Input Check (Check T / resilience.adversarial)
# Verifies adversarial input handling (malformed input, rate limiting, chaos scenarios).
#
# Usage: check-adversarial.sh <feature_dir> [--run] [--help]
#
# --run: actually execute the test suite and check for unhandled exceptions
#        on malformed inputs. Requires a working test runner.
# --pattern: (default) pattern matching only — outputs SKIP when test runner
#            is unavailable, otherwise reports pattern coverage.
#
# Writes PASS/FAIL/SKIP to .artifacts/check-results/resilience_adversarial.result

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

# ── Parse flags ────────────────────────────────────────────────────
RUN_MODE=false
if [ "${1:-}" = "--help" ]; then
  check_help "check-adversarial.sh" "<feature_dir> [--run] [--help]"
fi

FEATURE_DIR=""
for arg in "$@"; do
  case "$arg" in
    --run) RUN_MODE=true ;;
    --pattern) ;; # explicit pattern mode (default)
    -*) continue ;; # skip unknown flags
    *) [ -z "$FEATURE_DIR" ] && FEATURE_DIR="$arg" ;;
  esac
done

FEATURE_DIR="${FEATURE_DIR:?Usage: check-adversarial.sh <feature_dir> [--run] [--help]}"

echo "ADVERSARIAL: Scanning ${FEATURE_DIR}"

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
  echo "ADVERSARIAL: SKIP (no recognized language in ${FEATURE_DIR})"
  check_write_result "$FEATURE_DIR" "adversarial" "SKIP"
  exit 0
fi

# ── Try to detect test runner ────────────────────────────────────
TEST_RUNNER=""
TEST_RUN_CMD=""
case "$LANGUAGE" in
  typescript)
    if [ -f "${FEATURE_DIR}/package.json" ]; then
      TEST_RUN_CMD=$(grep -oE '"test"[[:space:]]*:[[:space:]]*"[^"]+"' "${FEATURE_DIR}/package.json" 2>/dev/null | head -1 | sed 's/"test"[[:space:]]*:[[:space:]]*"\(.*\)"/\1/' || true)
      if [ -n "$TEST_RUN_CMD" ]; then
        TEST_RUNNER="npm"
      fi
    fi
    if [ -z "$TEST_RUNNER" ] && command -v npx &>/dev/null; then
      TEST_RUNNER="npx"
      TEST_RUN_CMD="vitest"
    fi
    ;;
  python)
    if command -v pytest &>/dev/null; then
      TEST_RUNNER="pytest"
      TEST_RUN_CMD="pytest"
    elif [ -f "${FEATURE_DIR}/pyproject.toml" ] && grep -q '^\[tool.pytest' "${FEATURE_DIR}/pyproject.toml" 2>/dev/null; then
      TEST_RUNNER="pip+pytest"
      TEST_RUN_CMD="pytest"
    fi
    ;;
  java)
    if [ -f "${FEATURE_DIR}/mvnw" ]; then
      TEST_RUNNER="maven"
      TEST_RUN_CMD="./mvnw test -q"
    elif command -v mvn &>/dev/null; then
      TEST_RUNNER="maven"
      TEST_RUN_CMD="mvn test -q"
    elif [ -f "${FEATURE_DIR}/gradlew" ]; then
      TEST_RUNNER="gradle"
      TEST_RUN_CMD="./gradlew test --quiet"
    elif command -v gradle &>/dev/null; then
      TEST_RUNNER="gradle"
      TEST_RUN_CMD="gradle test --quiet"
    fi
    ;;
  go)
    if command -v go &>/dev/null; then
      TEST_RUNNER="go"
      TEST_RUN_CMD="go test ./..."
    fi
    ;;
esac

# ── RUN mode: actually execute the test suite ─────────────────────
if [ "$RUN_MODE" = true ]; then
  if [ -z "$TEST_RUNNER" ]; then
    echo "ADVERSARIAL: SKIP (no test runner found for ${LANGUAGE})"
    check_write_result "$FEATURE_DIR" "adversarial" "SKIP"
    exit 0
  fi

  echo "ADVERSARIAL: RUN mode — executing tests via ${TEST_RUNNER}: ${TEST_RUN_CMD}"
  cd "$FEATURE_DIR"

  # Run the test suite, capture exit code
  set +e
  TEST_OUTPUT=$(eval "$TEST_RUN_CMD" 2>&1)
  TEST_EXIT=$?
  set -e

  if [ "$TEST_EXIT" -ne 0 ]; then
    echo "ADVERSARIAL: FAIL — tests did not pass (exit code: ${TEST_EXIT})"
    echo "ADVERSARIAL: Test output:"
    echo "$TEST_OUTPUT" | tail -20
    check_write_result "$FEATURE_DIR" "adversarial" "FAIL" "tests_failed_exit_${TEST_EXIT}"
    exit 0
  fi

  # Check for unhandled exceptions / crashes in test output
  CRASHES=0
  for pattern in 'UnhandledPromiseRejection' 'unhandled rejection' 'FATAL' 'panic: ' 'Segmentation fault' 'EXC_BAD_ACCESS' 'Fatal error' 'FATAL EXCEPTION'; do
    if echo "$TEST_OUTPUT" | grep -qi "$pattern" 2>/dev/null; then
      CRASHES=$((CRASHES + 1))
      echo "ADVERSARIAL: WARNING — found '$pattern' in test output"
    fi
  done

  if [ "$CRASHES" -gt 0 ]; then
    echo "ADVERSARIAL: FAIL — ${CRASHES} crash/unhandled exception pattern(s) in test output"
    check_write_result "$FEATURE_DIR" "adversarial" "FAIL" "crashes_detected"
    exit 0
  fi

  echo "ADVERSARIAL: PASS — tests executed cleanly, no crashes detected"
  check_write_result "$FEATURE_DIR" "adversarial" "PASS"
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
  if [ -z "$TEST_RUNNER" ]; then
    echo "ADVERSARIAL: SKIP (no test runner available for pattern matching)"
    check_write_result "$FEATURE_DIR" "adversarial" "SKIP"
  else
    echo "ADVERSARIAL: WARN (test files found but no runner — pattern matching only, no execution)"
    check_write_result "$FEATURE_DIR" "adversarial" "SKIP" "no_test_runner"
  fi
  exit 0
fi

# ── Check for adversarial input test patterns ────────────────────
ADVERSARIAL_PATTERNS=0

case "$LANGUAGE" in
  typescript)
    # Check for oversized payload tests
    OVERSIZED=$(echo "$TEST_FILES" | xargs grep -cl 'oversize\|max.*size\|payload.*size\|body.*limit\|content.*length' 2>/dev/null || true)
    [ -n "$OVERSIZED" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for malformed JSON tests
    MALFORMED=$(echo "$TEST_FILES" | xargs grep -cl 'malformed.*json\|invalid.*json\|broken.*json\|parse.*error\|SyntaxError' 2>/dev/null || true)
    [ -n "$MALFORMED" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for injection tests
    INJECTION=$(echo "$TEST_FILES" | xargs grep -cl 'injection\|<script\|union.*select\|sql.*inject\|xss\|<svg\|onerror=' 2>/dev/null || true)
    [ -n "$INJECTION" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for rate limiting tests
    RATE_LIMIT=$(echo "$TEST_FILES" | xargs grep -cl 'rate.*limit\|throttl\|too.*many.*request\|429\|E429' 2>/dev/null || true)
    [ -n "$RATE_LIMIT" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for fuzz/edge case tests
    FUZZ=$(echo "$TEST_FILES" | xargs grep -cl 'fuzz\|edge.*case\|unicode\|special.*char\|emoji\|extremely.*long\|max.*length' 2>/dev/null || true)
    [ -n "$FUZZ" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))
    ;;

  python)
    # Check for oversized payload tests
    OVERSIZED=$(echo "$TEST_FILES" | xargs grep -cl 'oversize\|max.*size\|payload.*size\|body.*limit' 2>/dev/null || true)
    [ -n "$OVERSIZED" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for malformed input tests
    MALFORMED=$(echo "$TEST_FILES" | xargs grep -cl 'malformed\|invalid.*input\|broken.*json\|parse.*error' 2>/dev/null || true)
    [ -n "$MALFORMED" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for injection tests
    INJECTION=$(echo "$TEST_FILES" | xargs grep -cl 'injection\|sql.*inject\|xss\|<script\|escape' 2>/dev/null || true)
    [ -n "$INJECTION" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for rate limiting tests
    RATE_LIMIT=$(echo "$TEST_FILES" | xargs grep -cl 'rate.*limit\|throttl\|too.*many\|429' 2>/dev/null || true)
    [ -n "$RATE_LIMIT" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for fuzz/edge case tests
    FUZZ=$(echo "$TEST_FILES" | xargs grep -cl 'fuzz\|edge.*case\|unicode\|special.*char\|extremely.*long' 2>/dev/null || true)
    [ -n "$FUZZ" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))
    ;;

  java)
    # Check for oversized payload tests
    OVERSIZED=$(echo "$TEST_FILES" | xargs grep -cl 'oversize\|max.*size\|payload.*size' 2>/dev/null || true)
    [ -n "$OVERSIZED" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for malformed input tests
    MALFORMED=$(echo "$TEST_FILES" | xargs grep -cl 'malformed\|invalid.*input\|parse.*error' 2>/dev/null || true)
    [ -n "$MALFORMED" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for injection tests
    INJECTION=$(echo "$TEST_FILES" | xargs grep -cl 'injection\|sql.*inject\|xss\|<script' 2>/dev/null || true)
    [ -n "$INJECTION" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for rate limiting tests
    RATE_LIMIT=$(echo "$TEST_FILES" | xargs grep -cl 'rate.*limit\|throttl\|429\|TooManyRequests' 2>/dev/null || true)
    [ -n "$RATE_LIMIT" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))
    ;;

  go)
    # Check for oversized payload tests
    OVERSIZED=$(echo "$TEST_FILES" | xargs grep -cl 'max.*size\|max.*body\|max.*length\|oversize' 2>/dev/null || true)
    [ -n "$OVERSIZED" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for malformed input tests
    MALFORMED=$(echo "$TEST_FILES" | xargs grep -cl 'malformed\|invalid.*input\|parse.*error' 2>/dev/null || true)
    [ -n "$MALFORMED" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for injection tests
    INJECTION=$(echo "$TEST_FILES" | xargs grep -cl 'injection\|sql.*inject\|xss\|<script' 2>/dev/null || true)
    [ -n "$INJECTION" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))

    # Check for rate limiting tests
    RATE_LIMIT=$(echo "$TEST_FILES" | xargs grep -cl 'rate.*limit\|throttl\|429' 2>/dev/null || true)
    [ -n "$RATE_LIMIT" ] && ADVERSARIAL_PATTERNS=$((ADVERSARIAL_PATTERNS + 1))
    ;;
esac

# ── Report results ───────────────────────────────────────────────
if [ "$ADVERSARIAL_PATTERNS" -ge 2 ]; then
  echo "ADVERSARIAL: PASS — ${ADVERSARIAL_PATTERNS} adversarial test pattern type(s) detected"
  check_write_result "$FEATURE_DIR" "adversarial" "PASS"
  exit 0
fi

echo "ADVERSARIAL: FAIL — only ${ADVERSARIAL_PATTERNS} adversarial test pattern type(s) found (need at least 2)"
check_write_result "$FEATURE_DIR" "adversarial" "FAIL"
exit 0
