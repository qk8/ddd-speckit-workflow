#!/usr/bin/env bash
# test-health-log.sh — Test health metrics logging for the DDD Speckit Workflow
#
# Usage: scripts/test-health-log.sh <feature_dir> <task_id> <task_type> [--test-runner "cmd"]
#
# Logs test metrics after each task and appends to trend tracking file.
# Creates/updates .artifacts/test-health.json.
#
# Bash 3.2 compatible — no jq dependency in core logic.

set -euo pipefail

FEATURE_DIR="${1:?Usage: test-health-log.sh <feature_dir> <task_id> <task_type> [--test-runner cmd]}"
TASK_ID="${2:?Usage: test-health-log.sh <feature_dir> <task_id> <task_type> [--test-runner cmd]}"
TASK_TYPE="${3:?Usage: test-health-log.sh <feature_dir> <task_id> <task_type> [--test-runner cmd]}"
TEST_RUNNER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --test-runner) TEST_RUNNER="${2:-}"; shift ;;
  esac
  shift
done

ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
HEALTH_FILE="$ARTIFACTS_DIR/test-health.json"
mkdir -p "$ARTIFACTS_DIR"

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

# ── Step 1: Discover test files ─────────────────────────────────
TEST_FILES=$(find "$FEATURE_DIR" -type f \( -name '*.test.*' -o -name '*.spec.*' -o -name '*Test.*' -o -name '*Spec.*' \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' 2>/dev/null || true)

TOTAL_TEST_COUNT=0
TOTAL_ASSERTION_COUNT=0
TOTAL_TEST_FILES=0
TEST_FILE_LIST=""

if [ -n "$TEST_FILES" ]; then
  while IFS= read -r test_file; do
    [ -f "$test_file" ] || continue
    TOTAL_TEST_FILES=$((TOTAL_TEST_FILES + 1))

    # Count test blocks
    tc=$(grep -cE '(describe|it\(|test\(|specify\()' "$test_file" 2>/dev/null || echo 0)
    TOTAL_TEST_COUNT=$((TOTAL_TEST_COUNT + tc))

    # Count assertions
    ac=$(grep -cE '(expect\(|assert(Not)?|assertEqual|assertTrue|assertFalse|assertThrows|toBe|toEqual|toStrictEqual|rejects\.rejects|resolves\.resolves)' "$test_file" 2>/dev/null || echo 0)
    TOTAL_ASSERTION_COUNT=$((TOTAL_ASSERTION_COUNT + ac))

    # Build file list
    rel_path=$(echo "$test_file" | sed "s|^${FEATURE_DIR}/||")
    if [ -n "$TEST_FILE_LIST" ]; then
      TEST_FILE_LIST="${TEST_FILE_LIST},${rel_path}"
    else
      TEST_FILE_LIST="${rel_path}"
    fi
  done <<< "$TEST_FILES"
fi

# ── Step 2: Run tests if runner provided ────────────────────────
PASS_RATE=100
EXEC_TIME_MS=0
FLAKY_COUNT=0

if [ -n "$TEST_RUNNER" ]; then
  # Run tests with timing
  START_TIME=$(date +%s%N 2>/dev/null || date +%s)

  TEST_OUTPUT=$(bash -c "$TEST_RUNNER" 2>&1 || true)

  END_TIME=$(date +%s%N 2>/dev/null || date +%s)

  # Calculate execution time in ms
  if [ ${#START_TIME} -gt 10 ]; then
    # Nanoseconds available
    EXEC_TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))
  else
    EXEC_TIME_MS=$(( (END_TIME - START_TIME) * 1000 ))
  fi

  # Parse pass rate from test output
  # Jest format: "Test Suites: X passed, Y total"
  PASSED=$(echo "$TEST_OUTPUT" | grep -oE 'Test Suites: [0-9]+ passed' | grep -oE '[0-9]+' || echo "0")
  TOTAL_TESTS=$(echo "$TEST_OUTPUT" | grep -oE 'Test Suites: [0-9]+ passed, [0-9]+ total' | grep -oE '[0-9]+ total' | grep -oE '[0-9]+' || echo "$TOTAL_TEST_COUNT")

  if [ "$TOTAL_TESTS" -gt 0 ] 2>/dev/null; then
    PASS_RATE=$((PASSED * 100 / TOTAL_TESTS))
  fi

  # Flaky test detection (quick check — only for small suites)
  if [ "$TOTAL_TEST_COUNT" -lt 50 ]; then
    TEST_OUTPUT2=$(bash -c "$TEST_RUNNER" 2>&1 || true)
    if [ "$TEST_OUTPUT" != "$TEST_OUTPUT2" ]; then
      FLAKY_COUNT=1
    fi
  fi
fi

# ── Step 3: Parse coverage (if available) ───────────────────────
COVERAGE_PERCENT=0
for cov_file in "$FEATURE_DIR/coverage.json" "$FEATURE_DIR/coverage/lcov.info" "$FEATURE_DIR/.coverage"; do
  if [ -f "$cov_file" ]; then
    COVERAGE_PERCENT=$(grep -oE '[0-9]+\.?[0-9]*%' "$cov_file" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo "0")
    break
  fi
done

# ── Step 4: Append entry to test-health.json ────────────────────
TS=$(now_utc)

# Build test_files JSON array
TEST_FILES_JSON=""
if [ -n "$TEST_FILE_LIST" ]; then
  TEST_FILES_JSON=$(echo "$TEST_FILE_LIST" | tr ',' '\n' | awk '
    BEGIN { first=1 }
    {
      if (!first) printf ", "
      printf "\"%s\"", $0
      first=0
    }
  ')
fi

# Create new entry
NEW_ENTRY="    {
      \"task_id\": \"${TASK_ID}\",
      \"task_type\": \"${TASK_TYPE}\",
      \"completed_at\": \"${TS}\",
      \"total_test_count\": ${TOTAL_TEST_COUNT},
      \"pass_rate\": ${PASS_RATE},
      \"test_execution_time_ms\": ${EXEC_TIME_MS},
      \"coverage_percent\": ${COVERAGE_PERCENT},
      \"flaky_test_count\": ${FLAKY_COUNT},
      \"assertion_count\": ${TOTAL_ASSERTION_COUNT},
      \"test_files\": [${TEST_FILES_JSON}],
      \"test_file_count\": ${TOTAL_TEST_FILES}
    }"

if [ -f "$HEALTH_FILE" ]; then
  # Read existing content
  EXISTING=$(cat "$HEALTH_FILE")

  # Check if entries array is non-empty
  if echo "$EXISTING" | grep -q '"entries"' && echo "$EXISTING" | grep -q '"task_id"'; then
    # Add comma before new entry and append
    # Find the closing ] of entries array and insert before it
    TMPFILE=$(mktemp)
    # Use awk to insert before the last ]
    awk -v entry="$NEW_ENTRY" '
      /"alerts"/ {
        # Before alerts, insert new entry
        print entry ","
        in_entry=1
      }
      { print }
    ' "$HEALTH_FILE" > "$TMPFILE"
    mv "$TMPFILE" "$HEALTH_FILE"
  else
    # Empty entries array — replace with new entry
    sed "s/\"entries\": \[\]/\"entries\": [${NEW_ENTRY}]/" "$HEALTH_FILE" > "${HEALTH_FILE}.tmp"
    mv "${HEALTH_FILE}.tmp" "$HEALTH_FILE"
  fi

  # Update timestamp
  sed -i "s/\"updated_at\": \"[^\"]*\"/\"updated_at\": \"${TS}\"/" "$HEALTH_FILE" 2>/dev/null || true
else
  # Create new file
  cat > "$HEALTH_FILE" << JSONEOF
{
  "version": 1,
  "created_at": "${TS}",
  "updated_at": "${TS}",
  "entries": [${NEW_ENTRY}],
  "alerts": [],
  "trends": {}
}
JSONEOF
fi

# ── Step 5: Compute alerts ──────────────────────────────────────
ALERTS=""
PREV_PASS_RATE=100
PREV_EXEC_TIME=0

# Read previous entry for comparison
if [ -f "$HEALTH_FILE" ]; then
  # Extract last two entries' pass rates using awk
  PREV_PASS_RATE=$(awk '
    /"pass_rate"/ {
      gsub(/.*"pass_rate":[[:space:]]*/, "")
      gsub(/[,}].*/, "")
      rates[++n] = $0 + 0
    }
    END { if (n >= 2) print rates[n-1]; else print 100 }
  ' "$HEALTH_FILE" 2>/dev/null || echo "100")

  PREV_EXEC_TIME=$(awk '
    /"test_execution_time_ms"/ {
      gsub(/.*"test_execution_time_ms":[[:space:]]*/, "")
      gsub(/[,}].*/, "")
      times[++n] = $0 + 0
    }
    END { if (n >= 2) print times[n-1]; else print 0 }
  ' "$HEALTH_FILE" 2>/dev/null || echo "0")
fi

# Alert: pass rate drop > 5%
PASS_RATE_DROP=$((PREV_PASS_RATE - PASS_RATE))
if [ "$PASS_RATE_DROP" -gt 5 ]; then
  ALERTS="${ALERTS}ALERT: Pass rate dropped ${PASS_RATE_DROP}% (${PREV_PASS_RATE}% -> ${PASS_RATE}%)
"
fi

# Alert: execution time 2x
if [ "$PREV_EXEC_TIME" -gt 0 ] && [ "$EXEC_TIME_MS" -gt $((PREV_EXEC_TIME * 2)) ]; then
  ALERTS="${ALERTS}ALERT: Execution time doubled (${PREV_EXEC_TIME}ms -> ${EXEC_TIME_MS}ms)
"
fi

# Alert: coverage drop > 3%
# (Would need previous coverage value — skip for now)

# Alert: flaky test
if [ "$FLAKY_COUNT" -gt 0 ]; then
  ALERTS="${ALERTS}ALERT: ${FLAKY_COUNT} flaky test(s) detected
"
fi

# ── Step 6: Compute trends ──────────────────────────────────────
TRENDS=""
if [ -f "$HEALTH_FILE" ]; then
  # Compute trend for total_test_count using 3-entry moving average
  TRENDS=$(awk '
    /"total_test_count"/ {
      gsub(/.*"total_test_count":[[:space:]]*/, "")
      gsub(/[,}].*/, "")
      values[++n] = $0 + 0
    }
    END {
      if (n < 3) { printf "\"total_test_count\": \"insufficient_data\"" }
      else {
        avg = (values[n] + values[n-1] + values[n-2]) / 3
        if (values[n] > avg * 1.05) printf "\"total_test_count\": \"up\""
        else if (values[n] < avg * 0.95) printf "\"total_test_count\": \"down\""
        else printf "\"total_test_count\": \"stable\""
      }
    }
  ' "$HEALTH_FILE" 2>/dev/null || echo "\"total_test_count\": \"insufficient_data\"")
fi

# Update trends in file
if [ -n "$TRENDS" ] && [ -f "$HEALTH_FILE" ]; then
  sed -i "s/\"trends\": {}/\"trends\": {${TRENDS}}/" "$HEALTH_FILE" 2>/dev/null || true
fi

# ── Step 7: Output ──────────────────────────────────────────────
echo "TEST HEALTH: ${TASK_ID} | ${TOTAL_TEST_COUNT} tests, ${PASS_RATE}% pass, ${EXEC_TIME_MS}ms, ${FLAKY_COUNT} flaky"

if [ -n "$ALERTS" ]; then
  echo "$ALERTS"
fi

exit 0
