#!/usr/bin/env bash
# Architectural Tests (Check A)
# Executes the architecture test command defined in plan.md §20
# (Architectural Test Inventory) and reports PASS/FAIL.
set -euo pipefail

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_DIR" ]; then
  echo "ARCH TESTS: SKIP (no feature directory)"
  exit 0
fi

PLAN_FILE="${FEATURE_DIR}/plan.md"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

RESULT_FILE="${RESULTS_DIR}/A.result"

# ── Extract arch_test_command from plan.md ──────────────────────
# Looks in §20 (Architectural Test Inventory) for lines like:
#   arch_test_command: ./mvnw test -pl :arch-unit-tests
#   arch_test_command: npx madge --circular src/
#   architectural_test: ./gradlew archTest
# Falls back to skipping if not found.
extract_arch_command() {
  if [ ! -f "$PLAN_FILE" ]; then
    return 1
  fi

  # Search for arch_test_command: or architectural_test: pattern
  # Use grep to find matching lines, then extract the command after the colon
  local cmd
  cmd=$(grep -E '^\s*(arch_test_command|architectural_test)\s*:\s*' "$PLAN_FILE" 2>/dev/null | tail -1 | sed 's/^[^:]*:\s*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

  if [ -z "$cmd" ]; then
    return 1
  fi

  echo "$cmd"
}

ARCH_COMMAND=$(extract_arch_command 2>/dev/null || true)

if [ -z "$ARCH_COMMAND" ]; then
  echo "ARCH TESTS: SKIP (no arch_test_command configured in plan.md)"
  echo "PASS" > "$RESULT_FILE"
  exit 0
fi

echo "ARCH TESTS: ${ARCH_COMMAND}"

# ── Execute the command, capture output and exit code ──────────
OUTPUT=""
EXIT_CODE=0
OUTPUT=$(eval "$ARCH_COMMAND" 2>&1) || EXIT_CODE=$?

# Print captured output
if [ -n "$OUTPUT" ]; then
  echo "$OUTPUT"
fi

# ── Determine violations from output ───────────────────────────
# Many arch test tools report violations as lines matching specific patterns.
# We count lines that look like failures or violations.
VIOLATIONS=0
if [ "$EXIT_CODE" -ne 0 ]; then
  # Non-zero exit code means at least one violation was found
  VIOLATIONS=1

  # Try to extract a numeric violation count from common output patterns
  # Pattern: "X violations found" or "X failed" etc.
  COUNT_FROM_OUTPUT=$(echo "$OUTPUT" | grep -oE '[0-9]+ violation[s]?\b' 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
  if [ -n "$COUNT_FROM_OUTPUT" ]; then
    VIOLATIONS="$COUNT_FROM_OUTPUT"
  fi

  # Pattern: "X error(s)" (e.g., from dependency check tools)
  COUNT_ERRORS=$(echo "$OUTPUT" | grep -oE '[0-9]+ error' 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
  if [ -n "$COUNT_ERRORS" ] && [ "$COUNT_ERRORS" -gt "$VIOLATIONS" ] 2>/dev/null; then
    VIOLATIONS="$COUNT_ERRORS"
  fi
fi

# ── Write results ──────────────────────────────────────────────
if [ "$EXIT_CODE" -eq 0 ]; then
  {
    echo "PASS"
    echo "ARCH TESTS: PASS — 0 violations"
  } > "$RESULT_FILE"
  echo "ARCH TESTS: PASS — 0 violations"
  exit 0
else
  {
    echo "FAIL"
    echo "ARCH TESTS: FAIL — ${VIOLATIONS} violations"
  } > "$RESULT_FILE"
  echo "ARCH TESTS: FAIL — ${VIOLATIONS} violations"
  exit 1
fi
