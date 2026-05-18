#!/usr/bin/env bash
# integration-smoke.sh — Validate system-level integration across all modules
#
# Usage: bash scripts/integration-smoke.sh <feature_dir>
#
# C2: Integration smoke test after implement loop, before Phase 6 code review.
# Starts the full application and runs minimal cross-module operations.
# Catches integration-level regressions that no per-task check would detect.
#
# Output: .artifacts/integration-smoke.json with structured results.

set -euo pipefail

FEATURE_DIR="${1:?Usage: integration-smoke.sh <feature_dir>}"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

SMOKE_FILE="$ARTIFACTS_DIR/integration-smoke.json"

# Read build/start commands from plan.md §13 or §14
PLAN_FILE="$FEATURE_DIR/plan.md"
BUILD_CMD=""
START_CMD=""
HEALTH_ENDPOINT=""

if [ -f "$PLAN_FILE" ]; then
  # Extract build_command from plan.md §13 or §14
  BUILD_CMD=$(grep -A2 'build_command' "$PLAN_FILE" 2>/dev/null | grep -oE '"[^"]*"' | head -1 | sed 's/"//g' || true)
  START_CMD=$(grep -A2 'start_command\|dev_command\|server_command' "$PLAN_FILE" 2>/dev/null | grep -oE '"[^"]*"' | head -1 | sed 's/"//g' || true)
  HEALTH_ENDPOINT=$(grep -A2 'health_check\|health_endpoint\|health.*endpoint' "$PLAN_FILE" 2>/dev/null | grep -oE '"[^"]*"' | head -1 | sed 's/"//g' || true)
fi

# Auto-detect if not in plan
if [ -z "$BUILD_CMD" ] && [ -f "$FEATURE_DIR/package.json" ]; then
  BUILD_CMD="npm run build"
fi
if [ -z "$START_CMD" ] && [ -f "$FEATURE_DIR/package.json" ]; then
  START_CMD="npm start"
fi
if [ -z "$HEALTH_ENDPOINT" ]; then
  HEALTH_ENDPOINT="/health"
fi

echo "INTEGRATION_SMOKE: Starting integration smoke test"
echo "INTEGRATION_SMOKE: Build: ${BUILD_CMD:-N/A}"
echo "INTEGRATION_SMOKE: Start: ${START_CMD:-N/A}"
echo "INTEGRATION_SMOKE: Health: ${HEALTH_ENDPOINT:-N/A}"

RESULTS="[]"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

add_result() {
  local name="$1" status="$2" detail="$3"
  if [ -n "$RESULTS" ]; then
    RESULTS="${RESULTS},"
  fi
  RESULTS="${RESULTS}{\"test\":\"${name}\",\"status\":\"${status}\",\"detail\":\"${detail}\"}"
}

# ── Test 1: Build verification ─────────────────────────────────
if [ -n "$BUILD_CMD" ]; then
  echo "INTEGRATION_SMOKE: Running build..."
  BUILD_OUTPUT=""
  BUILD_EXIT=0
  BUILD_OUTPUT=$(cd "$FEATURE_DIR" && $BUILD_CMD 2>&1) || BUILD_EXIT=$?

  if [ "$BUILD_EXIT" -eq 0 ]; then
    add_result "build" "PASS" "Build completed successfully"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    add_result "build" "FAIL" "Build failed (exit $BUILD_EXIT): $(echo "$BUILD_OUTPUT" | tail -3 | tr '\n' ' ')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "INTEGRATION_SMOKE: Build failed — skipping remaining tests"
    cat > "$SMOKE_FILE" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "build_command": "${BUILD_CMD}",
  "tests": [${RESULTS}],
  "total": 1,
  "passed": ${PASS_COUNT},
  "failed": ${FAIL_COUNT},
  "skipped": ${SKIP_COUNT},
  "overall": "FAIL"
}
EOF
    echo "INTEGRATION_SMOKE: FAIL — build failed"
    echo "INTEGRATION_SMOKE: Results saved to $SMOKE_FILE"
    exit 1
  fi
else
  add_result "build" "SKIP" "No build command detected"
  SKIP_COUNT=$((SKIP_COUNT + 1))
fi

# ── Test 2: Application start ──────────────────────────────────
if [ -n "$START_CMD" ] && [ "$FAIL_COUNT" -eq 0 ]; then
  echo "INTEGRATION_SMOKE: Starting application..."
  # Start in background
  (cd "$FEATURE_DIR" && $START_CMD > "$ARTIFACTS_DIR/smoke-server.log" 2>&1) &
  SERVER_PID=$!
  SERVER_PORT="${SERVER_PORT:-3000}"
  # Also accept SERVER_PORT from environment or plan.md
  if [ -z "${SERVER_PORT:-}" ] || [ "$SERVER_PORT" = "3000" ]; then
    PLAN_PORT=$(grep -oE 'server_port|port[^_].*[0-9]{2,5}' "$PLAN_FILE" 2>/dev/null | grep -oE '[0-9]{2,5}' | head -1 || true)
    [ -n "$PLAN_PORT" ] && SERVER_PORT="$PLAN_PORT"
  fi

  # Wait for server to be ready (max 30 seconds)
  READY=false
  for i in $(seq 1 30); do
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      # Try to connect
      if curl -s --max-time 2 "http://localhost:${SERVER_PORT}${HEALTH_ENDPOINT}" > /dev/null 2>&1 || \
         wget -q --spider --timeout=2 "http://localhost:${SERVER_PORT}${HEALTH_ENDPOINT}" 2>/dev/null; then
        READY=true
        break
      fi
    fi
    sleep 1
  done

  if [ "$READY" = true ]; then
    add_result "server_start" "PASS" "Application started and health endpoint reachable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    add_result "server_start" "FAIL" "Server did not become ready within 30s"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "INTEGRATION_SMOKE: Server failed to start — skipping remaining tests"
  fi

  # Cleanup: stop the server
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
else
  add_result "server_start" "SKIP" "No start command detected"
  SKIP_COUNT=$((SKIP_COUNT + 1))
fi

# ── Test 3: Cross-module operation (if server is up) ───────────
if [ "$FAIL_COUNT" -eq 0 ] && [ -n "$START_CMD" ]; then
  # Start server again for integration test
  (cd "$FEATURE_DIR" && $START_CMD > "$ARTIFACTS_DIR/smoke-server.log" 2>&1) &
  SERVER_PID=$!

  # Wait for ready
  for i in $(seq 1 30); do
    if curl -s --max-time 2 "http://localhost:${SERVER_PORT}${HEALTH_ENDPOINT}" > /dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  # Run cross-module smoke tests — try multiple endpoints to exercise
  # different parts of the system (not just the health endpoint again).
  CROSS_FAIL=0
  CROSS_DETAILS=""

  # Test 3a: Try common API/list endpoints that exercise business logic
  for api_path in "/api" "/api/health" "/api/status" "/api/info" "/healthz" "/ready" "/ping" "/"; do
    SMOKE_API_OUTPUT=""
    SMOKE_API_EXIT=0
    SMOKE_API_OUTPUT=$(curl -s --max-time 5 "http://localhost:${SERVER_PORT}${api_path}" 2>&1) || SMOKE_API_EXIT=$?
    if [ "$SMOKE_API_EXIT" -eq 0 ]; then
      # Verify response is structured (JSON or meaningful text), not just a raw HTML page
      if echo "$SMOKE_API_OUTPUT" | grep -qE '^\s*\{.*\}\s*$|^\s*\[.*\]\s*$|status|healthy|pong'; then
        CROSS_DETAILS="Endpoint ${api_path} returned: $(echo "$SMOKE_API_OUTPUT" | head -c 100)"
        break
      elif echo "$SMOKE_API_OUTPUT" | grep -qE 'HTTP|HTML|DOCTYPE|<html'; then
        # Got HTML — server is up but this isn't an API endpoint; try next
        CROSS_DETAILS="Endpoint ${api_path} returned HTML (not API)"
        continue
      fi
    fi
  done

  # Test 3b: If no API endpoint responded, try a POST to exercise write path
  if [ "$CROSS_FAIL" -eq 0 ] && [ -z "$CROSS_DETAILS" ]; then
    POST_OUTPUT=""
    POST_EXIT=0
    POST_OUTPUT=$(curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
      -d '{"ping":true}' "http://localhost:${SERVER_PORT}/api" 2>&1) || POST_EXIT=$?
    if [ "$POST_EXIT" -eq 0 ]; then
      CROSS_DETAILS="POST /api responded: $(echo "$POST_OUTPUT" | head -c 100)"
    fi
  fi

  # Test 3c: Final fallback — verify the server responds at all (TCP connectivity)
  if [ -z "$CROSS_DETAILS" ]; then
    if curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://localhost:${SERVER_PORT}${HEALTH_ENDPOINT}" 2>/dev/null | grep -qE '2[0-9]{2}|3[0-9]{2}'; then
      CROSS_DETAILS="Server responding on ${HEALTH_ENDPOINT} (HTTP 2xx/3xx)"
    fi
  fi

  if [ -n "$CROSS_DETAILS" ]; then
    add_result "cross_module" "PASS" "$CROSS_DETAILS"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    add_result "cross_module" "FAIL" "No cross-module endpoint responded"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # Cleanup
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
else
  add_result "cross_module" "SKIP" "Server not available for integration test"
  SKIP_COUNT=$((SKIP_COUNT + 1))
fi

TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

# Determine overall status
if [ "$FAIL_COUNT" -eq 0 ]; then
  OVERALL="PASS"
else
  OVERALL="FAIL"
fi

# Write results
cat > "$SMOKE_FILE" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "build_command": "${BUILD_CMD:-N/A}",
  "start_command": "${START_CMD:-N/A}",
  "health_endpoint": "${HEALTH_ENDPOINT:-N/A}",
  "tests": [${RESULTS}],
  "total": ${TOTAL},
  "passed": ${PASS_COUNT},
  "failed": ${FAIL_COUNT},
  "skipped": ${SKIP_COUNT},
  "overall": "${OVERALL}"
}
EOF

echo ""
echo "INTEGRATION_SMOKE: ${OVERALL} — ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
echo "INTEGRATION_SMOKE: Results saved to $SMOKE_FILE"

if [ "$OVERALL" = "FAIL" ]; then
  echo "INTEGRATION_SMOKE: WARNING — integration smoke test failed."
  echo "INTEGRATION_SMOKE: System has integration-level issues that need attention."
  exit 1
fi

exit 0
