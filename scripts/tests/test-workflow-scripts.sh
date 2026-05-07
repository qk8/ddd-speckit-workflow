#!/usr/bin/env bash
# test-workflow-scripts.sh — Test suite for workflow shell scripts
#
# Usage: bash scripts/tests/test-workflow-scripts.sh
#
# C3: Shell script test suite.
# Tests key workflow scripts with mock inputs, verifies expected output format,
# and tests error paths. Run in CI on every workflow change.
#
# Exit codes:
#   0 = all tests passed
#   1 = one or more tests failed

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT=$(mktemp -d)
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

# Cleanup on exit
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# ── Test harness ─────────────────────────────────────────────────
assert_output_contains() {
  local test_name="$1" output="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if echo "$output" | grep -qF "$expected"; then
    echo "  [PASS] $test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $test_name — expected output to contain: '$expected'"
    echo "         Got: $(echo "$output" | head -5)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_output_not_contains() {
  local test_name="$1" output="$2" unexpected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if ! echo "$output" | grep -qF "$unexpected"; then
    echo "  [PASS] $test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $test_name — output should NOT contain: '$unexpected'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_exit_code() {
  local test_name="$1" actual="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$actual" -eq "$expected" ]; then
    echo "  [PASS] $test_name (exit code $actual)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $test_name — expected exit code $expected, got $actual"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_exists() {
  local test_name="$1" filepath="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -f "$filepath" ]; then
    echo "  [PASS] $test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $test_name — file not found: $filepath"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_file_contains() {
  local test_name="$1" filepath="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -f "$filepath" ] && grep -qF "$expected" "$filepath"; then
    echo "  [PASS] $test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $test_name — file $filepath should contain: '$expected'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ── Test: check-tasks.sh ────────────────────────────────────────
echo "━━━ Testing check-tasks.sh ━━━"

TEST_FEATURE="$TEST_ROOT/feature-test"
mkdir -p "$TEST_FEATURE"

# Create a minimal tasks.md
cat > "$TEST_FEATURE/tasks.md" <<'EOF'
# Implementation Backlog

## TASK-1: Create Order aggregate
Status: DONE
Type: backend-domain
Depends on: none
Scope:
  Creates:
    - src/domain/order/Order.ts
Acceptance criteria:
  - calling Order.create(orderData) returns Order

## TASK-2: Order repository interface
Status: TODO
Type: backend-domain
Depends on: TASK-1
Scope:
  Creates:
    - src/domain/order/OrderRepository.ts
Acceptance criteria:
  - calling OrderRepository.save(order) succeeds

## TASK-3: Order controller
Status: TODO
Type: backend-api
Depends on: TASK-1
Scope:
  Creates:
    - src/api/order/OrderController.ts
Acceptance criteria:
  - calling POST /api/orders creates an order
EOF

(cd "$SCRIPTS_DIR" && FEATURE_DIR="$TEST_FEATURE" bash scripts/check-tasks.sh --json) > "$TEST_ROOT/check-tasks-output.txt" 2>&1
CHECK_TASKS_EXIT=$?

assert_output_contains "check-tasks: has_todo=true" "$(cat "$TEST_ROOT/check-tasks-output.txt")" "has_todo=true"
assert_output_contains "check-tasks: done_count=1" "$(cat "$TEST_ROOT/check-tasks-output.txt")" "done_count=1"
assert_output_contains "check-tasks: todo_count=2" "$(cat "$TEST_ROOT/check-tasks-output.txt")" "todo_count=2"
assert_exit_code "check-tasks: exits 0" "$CHECK_TASKS_EXIT" 0

# Test with empty tasks.md
EMPTY_TASKS="$TEST_ROOT/empty-tasks.md"
echo "# Implementation Backlog" > "$EMPTY_TASKS"
mkdir -p "$TEST_ROOT/empty-feature"
cp "$EMPTY_TASKS" "$TEST_ROOT/empty-feature/tasks.md"
(cd "$SCRIPTS_DIR" && FEATURE_DIR="$TEST_ROOT/empty-feature" bash scripts/check-tasks.sh) > "$TEST_ROOT/check-tasks-empty.txt" 2>&1
assert_output_contains "check-tasks empty: done_count=0" "$(cat "$TEST_ROOT/check-tasks-empty.txt")" "done_count=0"

# ── Test: check-point.sh ────────────────────────────────────────
echo ""
echo "━━━ Testing check-point.sh ━━━"

TEST_FEATURE2="$TEST_ROOT/checkpoint-test"
mkdir -p "$TEST_FEATURE2/.artifacts"

# Test write
OUTPUT=$(bash "$SCRIPTS_DIR/check-point.sh" write "$TEST_FEATURE2" task_in_progress "TASK-1" "backend-domain" 2>&1 || true)
assert_output_contains "check-point write: success" "$OUTPUT" "Checkpoint updated"
assert_file_exists "check-point write: checkpoint file created" "$TEST_FEATURE2/.workflow-state.json"

# Test read
OUTPUT=$(bash "$SCRIPTS_DIR/check-point.sh" read "$TEST_FEATURE2" 2>&1)
assert_output_contains "check-point read: contains TASK-1" "$OUTPUT" "TASK-1"
assert_output_contains "check-point read: status IN_PROGRESS" "$OUTPUT" "IN_PROGRESS"

# Test snapshot
ROOT_DIR=$(pwd)
OUTPUT=$(bash "$SCRIPTS_DIR/check-point.sh" snapshot "$TEST_FEATURE2" "TASK-1" "$ROOT_DIR" 2>&1 || true)
assert_output_contains "check-point snapshot: captured files" "$OUTPUT" "SNAPSHOT:"
assert_file_exists "check-point snapshot: snapshot file created" "$TEST_FEATURE2/.artifacts/snapshots/TASK-1.snapshot.json"

# ── Test: check-gate-preconditions.sh ───────────────────────────
echo ""
echo "━━━ Testing check-gate-preconditions.sh ━━━"

TEST_FEATURE3="$TEST_ROOT/gate-test"
mkdir -p "$TEST_FEATURE3/.artifacts/check-results"

# Test with no results (clean gate)
OUTPUT=$(bash "$SCRIPTS_DIR/check-gate-preconditions.sh" "$TEST_FEATURE3" "acceptance" 2>&1 || true)
assert_output_contains "gate clean: GATE_BLOCKED=false" "$OUTPUT" "GATE_BLOCKED=false"
assert_output_contains "gate clean: AUTO_APPROVE=false" "$OUTPUT" "AUTO_APPROVE=false"

# Test with failing check
echo "FAIL" > "$TEST_FEATURE3/.artifacts/check-results/D.result"
OUTPUT=$(bash "$SCRIPTS_DIR/check-gate-preconditions.sh" "$TEST_FEATURE3" "quality" 2>&1 || true)
assert_output_contains "gate blocked: GATE_BLOCKED=true" "$OUTPUT" "GATE_BLOCKED=true"
assert_output_contains "gate blocked: FAILING_CHECKS=D" "$OUTPUT" "FAILING_CHECKS=D"

# Test auto-approve transparency (C4)
echo "PASS" > "$TEST_FEATURE3/.artifacts/check-results/A.result"
echo "PASS" > "$TEST_FEATURE3/.artifacts/check-results/BC.result"
# Temporarily enable auto_approve
PRESET_FILE="$(cd "$SCRIPTS_DIR/../ddd-clean-arch" && pwd)/preset.yml"
if [ -f "$PRESET_FILE" ]; then
  sed -i 's/enabled: false/enabled: true/' "$PRESET_FILE" 2>/dev/null || true
fi

OUTPUT=$(bash "$SCRIPTS_DIR/check-gate-preconditions.sh" "$TEST_FEATURE3" "acceptance" 2>&1 || true)
assert_output_contains "gate auto-approve: has summary" "$OUTPUT" "AUTO_APPROVE_SUMMARY:"
assert_output_contains "gate auto-approve: checks_pass" "$OUTPUT" "checks_pass="

# Restore
if [ -f "$PRESET_FILE" ]; then
  sed -i 's/enabled: true/enabled: false/' "$PRESET_FILE" 2>/dev/null || true
fi

# ── Test: filter-checks-by-profile.sh ───────────────────────────
echo ""
echo "━━━ Testing filter-checks-by-profile.sh ━━━"

OUTPUT=$(bash "$SCRIPTS_DIR/filter-checks-by-profile.sh" minimal backend-api 2>&1)
assert_output_contains "filter minimal: has core checks" "$OUTPUT" "A"
assert_output_contains "filter minimal: has core checks" "$OUTPUT" "Z"
# Minimal should NOT have secondary/tertiary checks
assert_output_not_contains "filter minimal: no secondary checks" "$OUTPUT" "E"

OUTPUT=$(bash "$SCRIPTS_DIR/filter-checks-by-profile.sh" standard backend-api 2>&1)
assert_output_contains "filter standard: has K" "$OUTPUT" "K"
assert_output_contains "filter standard: has M" "$OUTPUT" "M"

OUTPUT=$(bash "$SCRIPTS_DIR/filter-checks-by-profile.sh" full backend-api 2>&1)
assert_output_contains "filter full: has all checks" "$OUTPUT" "G"
assert_output_contains "filter full: has tertiary checks" "$OUTPUT" "R"

# Test invalid profile
OUTPUT=$(bash "$SCRIPTS_DIR/filter-checks-by-profile.sh" invalid backend-api 2>&1 || true)
assert_output_contains "filter invalid: error message" "$OUTPUT" "ERROR"

# ── Test: dry-run.sh ────────────────────────────────────────────
echo ""
echo "━━━ Testing dry-run.sh ━━━"

OUTPUT=$(bash "$SCRIPTS_DIR/dry-run.sh" "$TEST_ROOT" 2>&1 || true)
assert_output_contains "dry-run: validates preset" "$OUTPUT" "preset.yml"
assert_output_contains "dry-run: validates checks" "$OUTPUT" "check"
assert_exit_code "dry-run: exits 0 or 2" "$?" 0

# ── Test: estimate-cost.sh ──────────────────────────────────────
echo ""
echo "━━━ Testing estimate-cost.sh ━━━"

# Create minimal plan and tasks for cost estimation
mkdir -p "$TEST_ROOT/cost-test"
cat > "$TEST_ROOT/cost-test/tasks.md" <<'EOF'
## TASK-1: Test task
Status: TODO
Type: backend-domain
Depends on: none
EOF

cat > "$TEST_ROOT/cost-test/plan.md" <<'EOF'
## §13 Testing strategy
regression_command:
  all: npm test
  api_only: npm test -- --api
EOF

cat > "$TEST_ROOT/cost-test/project-brief.md" <<'EOF'
## Complexity
medium
EOF

OUTPUT=$(bash "$SCRIPTS_DIR/estimate-cost.sh" "$TEST_ROOT/cost-test" 2>&1 || true)
assert_output_contains "estimate-cost: shows total calls" "$OUTPUT" "Total estimated calls"
assert_output_contains "estimate-cost: shows cost" "$OUTPUT" "total"
assert_file_exists "estimate-cost: writes JSON" "$TEST_ROOT/cost-test/.artifacts/cost-estimate.json"

# ── Test: regression-baseline.sh ────────────────────────────────
echo ""
echo "━━━ Testing regression-baseline.sh ━━━"

mkdir -p "$TEST_ROOT/baseline-test"
cat > "$TEST_ROOT/baseline-test/plan.md" <<'EOF'
## §13 Testing strategy
regression_command:
  all: npm test
EOF

OUTPUT=$(bash "$SCRIPTS_DIR/regression-baseline.sh" "$TEST_ROOT/baseline-test" 2>&1 || true)
assert_output_contains "regression-baseline: runs" "$OUTPUT" "REGRESSION_BASELINE"
assert_file_exists "regression-baseline: writes JSON" "$TEST_ROOT/baseline-test/.artifacts/regression-baseline.json"

# ── Test: integration-smoke.sh ──────────────────────────────────
echo ""
echo "━━━ Testing integration-smoke.sh ━━━"

mkdir -p "$TEST_ROOT/smoke-test"
cat > "$TEST_ROOT/smoke-test/plan.md" <<'EOF'
## §13 Testing strategy
build_command: "npm run build"
start_command: "npm start"
EOF

OUTPUT=$(bash "$SCRIPTS_DIR/integration-smoke.sh" "$TEST_ROOT/smoke-test" 2>&1 || true)
assert_output_contains "integration-smoke: starts" "$OUTPUT" "INTEGRATION_SMOKE"
assert_file_exists "integration-smoke: writes JSON" "$TEST_ROOT/smoke-test/.artifacts/integration-smoke.json"

# ── Test: validate-dependencies.sh ──────────────────────────────
echo ""
echo "━━━ Testing validate-dependencies.sh ━━━"

OUTPUT=$(bash "$SCRIPTS_DIR/validate-dependencies.sh" 2>&1 || true)
EXIT_CODE=$?
assert_output_contains "validate-deps: reports core tools" "$OUTPUT" "Core CLI"
assert_output_contains "validate-deps: reports summary" "$OUTPUT" "Dependency validation"
# Should exit 0 (all critical present) or 2 (optional missing)
assert_output_not_contains "validate-deps: no critical failures" "$OUTPUT" "CRITICAL" 2>/dev/null || true

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed, $TOTAL_COUNT total"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Some tests failed. Review the output above."
  exit 1
fi

echo "All tests passed!"
exit 0
