#!/usr/bin/env bash
# regression-baseline.sh — Run full test suite and save results as baseline
#
# Usage: bash scripts/regression-baseline.sh <feature_dir>
#
# C1: Full regression baseline after implement loop, before Phase 6 code review.
# This creates a golden reference that Phase 6 fix tasks can diff against.
#
# Output: .artifacts/regression-baseline.json with structured test results.

set -euo pipefail

FEATURE_DIR="${1:?Usage: regression-baseline.sh <feature_dir>}"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

BASELINE_FILE="$ARTIFACTS_DIR/regression-baseline.json"

# Read regression command from plan.md §13
PLAN_FILE="$FEATURE_DIR/plan.md"
REGRESSION_CMD=""
if [ -f "$PLAN_FILE" ]; then
  # Extract regression_command.all from plan.md §13
  IN_SECTION13=false
  while IFS= read -r line; do
    if echo "$line" | grep -q '§13\|Testing strategy'; then
      IN_SECTION13=true
    fi
    if [ "$IN_SECTION13" = true ] && echo "$line" | grep -q 'regression_command'; then
      REGRESSION_CMD=$(echo "$line" | sed 's/.*regression_command\..*:\s*//' | sed 's/^"//;s/"$//' | xargs)
      break
    fi
    # End of section 13 (next section starts)
    if [ "$IN_SECTION13" = true ] && echo "$line" | grep -qE '§[1-9][0-9]'; then
      break
    fi
  done < "$PLAN_FILE"
fi

# If no regression command found, try common patterns
if [ -z "$REGRESSION_CMD" ]; then
  if [ -f "$FEATURE_DIR/package.json" ]; then
    REGRESSION_CMD="npm test"
  elif command -v pytest &>/dev/null; then
    REGRESSION_CMD="pytest"
  elif command -v go &>/dev/null; then
    REGRESSION_CMD="go test ./..."
  fi
fi

if [ -z "$REGRESSION_CMD" ]; then
  echo "REGRESSION_BASELINE: No regression command found in plan.md §13"
  echo "REGRESSION_BASELINE: Skipping — no test runner detected."
  cat > "$BASELINE_FILE" <<'EOF'
{
  "status": "SKIPPED",
  "reason": "No regression command found",
  "timestamp": "",
  "tests": [],
  "total": 0,
  "passed": 0,
  "failed": 0,
  "skipped": 0
}
EOF
  exit 0
fi

echo "REGRESSION_BASELINE: Running full regression suite"
echo "REGRESSION_BASELINE: Command: $REGRESSION_CMD"
echo "REGRESSION_BASELINE: Baseline file: $BASELINE_FILE"

# Run the regression suite and capture output
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
OUTPUT_FILE="$ARTIFACTS_DIR/regression-baseline-output.txt"
EXIT_CODE=0

# Try running in the feature dir's root context
(cd "$FEATURE_DIR" && $REGRESSION_CMD 2>&1) > "$OUTPUT_FILE" || EXIT_CODE=$?

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
TESTS_JSON=""

if [ "$EXIT_CODE" -eq 0 ]; then
  STATUS="PASS"

  # Parse test results from common output formats
  # Jest/ Vitest format: "Test Suites: X passed, Y failed"
  _TS=$(grep -oE 'Test Suites:\s+[0-9]+ passed' "$OUTPUT_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
  _TF=$(grep -oE 'Test Suites:\s+[0-9]+ failed' "$OUTPUT_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
  _TP=$(grep -oE 'Tests:\s+[0-9]+ passed' "$OUTPUT_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
  _TFAIL=$(grep -oE 'Tests:\s+[0-9]+ failed' "$OUTPUT_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
  _TSKIP=$(grep -oE 'Tests:\s+[0-9]+ skipped' "$OUTPUT_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)

  if [ -n "${_TS:-}" ]; then
    TOTAL=$((_TS + ${_TF:-0}))
    PASSED=${_TP:-$((TOTAL - ${_TFAIL:-0}))}
    FAILED=${_TFAIL:-0}
    SKIPPED=${_TSKIP:-0}
  else
    # Generic: count lines with test names
    TOTAL=$(grep -cE '^\s*(✓|✔|✗|✘|⎼|⏱)' "$OUTPUT_FILE" 2>/dev/null || echo "0")
    PASSED=$(grep -cE '^\s*(✓|✔)' "$OUTPUT_FILE" 2>/dev/null || echo "0")
    FAILED=$(grep -cE '^\s*(✗|✘)' "$OUTPUT_FILE" 2>/dev/null || echo "0")
    SKIPPED=$(grep -cE '^\s*○|SKIP|skip|skipped' "$OUTPUT_FILE" 2>/dev/null || echo "0")
  fi

  # Extract individual test results
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^\s*(✓|✔)'; then
      name=$(echo "$line" | sed 's/^[[:space:]]*[✓✔][[:space:]]*//' | sed 's/[[:space:]]*$//')
      if [ -n "$TESTS_JSON" ]; then
        TESTS_JSON="${TESTS_JSON},"
      fi
      TESTS_JSON="${TESTS_JSON}{\"name\":\"${name}\",\"status\":\"PASS\"}"
    elif echo "$line" | grep -qE '^\s*(✗|✘)'; then
      name=$(echo "$line" | sed 's/^[[:space:]]*[✗✘][[:space:]]*//' | sed 's/[[:space:]]*$//')
      if [ -n "$TESTS_JSON" ]; then
        TESTS_JSON="${TESTS_JSON},"
      fi
      TESTS_JSON="${TESTS_JSON}{\"name\":\"${name}\",\"status\":\"FAIL\"}"
    fi
  done < "$OUTPUT_FILE"
else
  STATUS="FAIL"
  PASSED=$(grep -cE '^\s*(✓|✔)' "$OUTPUT_FILE" 2>/dev/null || echo "0")
  FAILED=$(grep -cE '^\s*(✗|✘)' "$OUTPUT_FILE" 2>/dev/null || echo "0")
  TOTAL=$((PASSED + FAILED))

  while IFS= read -r line; do
    if echo "$line" | grep -qE '^\s*(✗|✘)'; then
      name=$(echo "$line" | sed 's/^[[:space:]]*[✗✘][[:space:]]*//' | sed 's/[[:space:]]*$//')
      if [ -n "$TESTS_JSON" ]; then
        TESTS_JSON="${TESTS_JSON},"
      fi
      TESTS_JSON="${TESTS_JSON}{\"name\":\"${name}\",\"status\":\"FAIL\"}"
    fi
  done < "$OUTPUT_FILE"
fi

# Write baseline JSON
cat > "$BASELINE_FILE" <<EOF
{
  "status": "${STATUS}",
  "command": "${REGRESSION_CMD}",
  "exit_code": ${EXIT_CODE},
  "timestamp": "${TIMESTAMP}",
  "tests": [${TESTS_JSON}],
  "total": ${TOTAL},
  "passed": ${PASSED},
  "failed": ${FAILED},
  "skipped": ${SKIPPED}
}
EOF

echo ""
echo "REGRESSION_BASELINE: ${STATUS} — ${TOTAL} total, ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
echo "REGRESSION_BASELINE: Results saved to $BASELINE_FILE"
echo "REGRESSION_BASELINE: Full output: $OUTPUT_FILE"

if [ "$STATUS" = "FAIL" ]; then
  echo "REGRESSION_BASELINE: WARNING — baseline has failures. Fix before code review."
  exit 1
fi

exit 0
