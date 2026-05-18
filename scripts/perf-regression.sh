#!/usr/bin/env bash
# perf-regression.sh — End-to-end performance regression baseline.
#
# After all tasks complete, generates synthetic load from the API contract
# and compares response times against the performance budget from plan.md §10.
# Flags any endpoint that exceeds its budget.
#
# Usage: perf-regression.sh <feature_dir>

set -euo pipefail

FEATURE_DIR="${1:?Usage: perf-regression.sh <feature_dir>}"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
RESULT_FILE="$ARTIFACTS_DIR/perf-regression-result.json"
mkdir -p "$ARTIFACTS_DIR"

PLAN_FILE="$FEATURE_DIR/plan.md"
CONTRACT_FILE=""

# Find api-contract.yaml
for f in "$FEATURE_DIR/.specify/specs/*/api-contract.yaml" \
         "$FEATURE_DIR/docs/spec/api-contract.yaml" \
         "$FEATURE_DIR/api-contract.yaml"; do
  [ -f "$f" ] && CONTRACT_FILE="$f" && break
done

# Extract performance budget from plan.md §10
P95_BUDGET_MS=""
P99_BUDGET_MS=""
THROUGHPUT_RPS=""
if [ -f "$PLAN_FILE" ]; then
  IN_SECTION10=false
  while IFS= read -r line; do
    if echo "$line" | grep -qE '§10|Performance' 2>/dev/null; then
      IN_SECTION10=true
    fi
    if [ "$IN_SECTION10" = true ] && echo "$line" | grep -qiE '§[1-9][0-9]' 2>/dev/null; then
      IN_SECTION10=false
    fi
    if [ "$IN_SECTION10" = true ]; then
      if echo "$line" | grep -qiE 'p95.*[0-9]+' 2>/dev/null; then
        P95_BUDGET_MS=$(echo "$line" | grep -oE '[0-9]+' | head -1 || true)
      fi
      if echo "$line" | grep -qiE 'p99.*[0-9]+' 2>/dev/null; then
        P99_BUDGET_MS=$(echo "$line" | grep -oE '[0-9]+' | head -1 || true)
      fi
      if echo "$line" | grep -qiE 'throughput.*[0-9]+' 2>/dev/null; then
        THROUGHPUT_RPS=$(echo "$line" | grep -oE '[0-9]+' | head -1 || true)
      fi
    fi
  done < "$PLAN_FILE"
fi

# Default budgets if not found
P95_BUDGET_MS="${P95_BUDGET_MS:-500}"
P99_BUDGET_MS="${P99_BUDGET_MS:-1000}"

echo "PERF_REGRESSION: p95 budget: ${P95_BUDGET_MS}ms, p99 budget: ${P99_BUDGET_MS}ms"

# If no API contract, try to discover endpoints from code
ENDPOINTS=""
if [ -n "$CONTRACT_FILE" ]; then
  # Parse endpoints from api-contract.yaml
  IN_PATHS=false
  CURRENT_PATH=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^paths:' 2>/dev/null; then
      IN_PATHS=true
      continue
    fi
    if [ "$IN_PATHS" = true ]; then
      if echo "$line" | grep -qE '^  /' 2>/dev/null; then
        CURRENT_PATH=$(echo "$line" | sed 's/^  *//' | sed 's/:.*//')
      fi
      if echo "$line" | grep -qE '^\s+(get|post|put|delete|patch):' 2>/dev/null && [ -n "$CURRENT_PATH" ]; then
        METHOD=$(echo "$line" | grep -oE '(get|post|put|delete|patch)' | head -1)
        ENDPOINTS="${ENDPOINTS}${METHOD} ${CURRENT_PATH}\n"
      fi
      if echo "$line" | grep -qE '^[a-z]' 2>/dev/null && ! echo "$line" | grep -qE '^  ' 2>/dev/null; then
        IN_PATHS=false
        CURRENT_PATH=""
      fi
    fi
  done < "$CONTRACT_FILE"
else
  # Auto-discover endpoints from code
  cd "$FEATURE_DIR"
  ENDPOINTS=$(
    for pattern in \
      '@(Get|Post|Put|Delete|Patch)\(' \
      '@@(Get|Post|Put|Delete|Patch)Mapping' \
      '@app\.(get|post|put|delete|patch)\(' \
      '@(route|router)\.(get|post|put|delete|patch)\(' \
      'app\.(get|post|put|delete|patch)\(' \
      'router\.(get|post|put|delete|patch)\('; do
      find . -type f \( -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.java' -o -name '*.go' -o -name '*.rs' \) \
        -not -path '*/node_modules/*' -not -path '*/.artifacts/*' -not -path '*/test*' \
        -exec grep -lE "$pattern" {} \; 2>/dev/null
    done | head -10
  )
  cd - > /dev/null
fi

if [ -z "$(echo -e "$ENDPOINTS" | tr -d '[:space:]')" ]; then
  echo "PERF_REGRESSION: SKIP — no endpoints found"
  cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')",
  "status": "SKIPPED",
  "reason": "No endpoints found to test",
  "endpoints_tested": 0,
  "violations": []
}
EOF
  exit 0
fi

# Start the server if a start command exists
START_CMD=""
if [ -f "$PLAN_FILE" ]; then
  START_CMD=$(grep -A2 'start_command\|dev_command\|server_command' "$PLAN_FILE" 2>/dev/null | grep -oE '"[^"]*"' | head -1 | sed 's/"//g' || true)
fi

SERVER_PID=""
SERVER_PORT="${SERVER_PORT:-3000}"
SERVER_READY=false

if [ -n "$START_CMD" ]; then
  echo "PERF_REGRESSION: Starting server for testing..."
  (cd "$FEATURE_DIR" && $START_CMD > "$ARTIFACTS_DIR/perf-server.log" 2>&1) &
  SERVER_PID=$!

  # Wait for server to be ready (max 30 seconds)
  for i in $(seq 1 30); do
    if curl -s --max-time 2 "http://localhost:${SERVER_PORT}/health" > /dev/null 2>&1 || \
       curl -s --max-time 2 "http://localhost:${SERVER_PORT}/" > /dev/null 2>&1; then
      SERVER_READY=true
      break
    fi
    sleep 1
  done
fi

# Run performance tests
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
ENDPOINTS_TESTED=0
VIOLATIONS=""
TOTAL_TIME=0

while IFS= read -r endpoint_line; do
  [ -z "$endpoint_line" ] && continue
  METHOD=$(echo "$endpoint_line" | awk '{print $1}')
  PATH_URL=$(echo "$endpoint_line" | awk '{print $2}')
  [ -z "$PATH_URL" ] && continue

  # Skip non-GET methods for basic perf test (POST/PUT/DELETE need request bodies)
  [ "$METHOD" != "get" ] && continue

  # Measure response time (3 samples, take median)
  DELAYS=""
  for i in 1 2 3; do
    DELAY=$(curl -s -o /dev/null -w "%{time_total}" "http://localhost:${SERVER_PORT}${PATH_URL}" 2>/dev/null || echo "999")
    DELAY_MS=$(echo "$DELAY" | awk '{printf "%d", $1 * 1000}')
    DELAYS="${DELAYS} ${DELAY_MS}"
  done

  # Calculate median
  MEDIAN=$(echo "$DELAYS" | tr ' ' '\n' | grep -v '^$' | sort -n | awk 'NR==2{print}')
  [ -z "$MEDIAN" ] && MEDIAN=0

  ENDPOINTS_TESTED=$((ENDPOINTS_TESTED + 1))
  TOTAL_TIME=$((TOTAL_TIME + MEDIAN))

  # Check against budget
  if [ "$MEDIAN" -gt "$P95_BUDGET_MS" ]; then
    VIOLATIONS="${VIOLATIONS}{\"endpoint\":\"${PATH_URL}\",\"median_ms\":${MEDIAN},\"budget_ms\":${P95_BUDGET_MS}},
"
    echo "PERF_REGRESSION: VIOLATION — ${METHOD} ${PATH_URL}: ${MEDIAN}ms > ${P95_BUDGET_MS}ms budget"
  else
    echo "PERF_REGRESSION: OK — ${METHOD} ${PATH_URL}: ${MEDIAN}ms (budget: ${P95_BUDGET_MS}ms)"
  fi
done <<< "$(echo -e "$ENDPOINTS" | sort -u)"

# Cleanup
if [ -n "$SERVER_PID" ]; then
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
fi

# Determine overall status
VIOLATION_COUNT=$(echo "$VIOLATIONS" | grep -c '"endpoint"' 2>/dev/null || echo 0)
if [ "$VIOLATION_COUNT" -eq 0 ]; then
  OVERALL="PASS"
else
  OVERALL="FAIL"
fi

# Write result
cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "status": "$OVERALL",
  "p95_budget_ms": $P95_BUDGET_MS,
  "p99_budget_ms": $P99_BUDGET_MS,
  "endpoints_tested": $ENDPOINTS_TESTED,
  "violations": [${VIOLATIONS%,}],
  "avg_response_ms": $((TOTAL_TIME / (ENDPOINTS_TESTED > 0 ? ENDPOINTS_TESTED : 1)))
}
EOF

echo ""
echo "PERF_REGRESSION: ${OVERALL} — ${ENDPOINTS_TESTED} endpoints tested, ${VIOLATION_COUNT} violation(s)"
echo "PERF_REGRESSION: Results saved to $RESULT_FILE"

if [ "$OVERALL" = "FAIL" ]; then
  echo "PERF_REGRESSION: WARNING — performance budget exceeded. Review $RESULT_FILE for details."
  exit 1
fi

exit 0
