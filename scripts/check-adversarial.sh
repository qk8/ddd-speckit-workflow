#!/usr/bin/env bash
# Adversarial Input Check (Check T / resilience.adversarial)
# Verifies adversarial input handling (malformed input, rate limiting, chaos scenarios).
#
# Usage: check-adversarial.sh <feature_dir>
#
# Writes PASS/FAIL to .artifacts/check-results/resilience_adversarial.result

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-adversarial.sh <feature_dir>}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

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
  echo "SKIP" > "${RESULTS_DIR}/resilience_adversarial.result"
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
  echo "ADVERSARIAL: SKIP (no test files found)"
  echo "SKIP" > "${RESULTS_DIR}/resilience_adversarial.result"
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
  echo "PASS" > "${RESULTS_DIR}/resilience_adversarial.result"
  exit 0
fi

echo "ADVERSARIAL: FAIL — only ${ADVERSARIAL_PATTERNS} adversarial test pattern type(s) found (need at least 2)"
echo "FAIL" > "${RESULTS_DIR}/resilience_adversarial.result"
exit 0
