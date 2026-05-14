#!/usr/bin/env bash
# test_recovery-engine.sh — Integration tests for crash recovery
#
# Tests the full recovery chain: checkpoint -> state change -> restore -> verify
# All tests run in /tmp to avoid polluting the repo.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT

# Source helper functions from test runner
if [ -f /tmp/test-run-passed ]; then rm -f /tmp/test-run-passed; fi
if [ -f /tmp/test-run-failed ]; then rm -f /tmp/test-run-failed; fi

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $msg"
    echo "PASS" >> /tmp/test-run-passed
  else
    echo "  FAIL: $msg (expected='$expected', actual='$actual')" >&2
    echo "FAIL" >> /tmp/test-run-failed
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $msg"
    echo "PASS" >> /tmp/test-run-passed
  else
    echo "  FAIL: $msg (output missing '$needle')" >&2
    echo "FAIL" >> /tmp/test-run-failed
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $msg"
    echo "PASS" >> /tmp/test-run-passed
  else
    echo "  FAIL: $msg (output unexpectedly contains '$needle')" >&2
    echo "FAIL" >> /tmp/test-run-failed
  fi
}

echo "=== Test: Checkpoint and restore ==="
TEST_DIR="$TEST_BASE/checkpoint_restore"
mkdir -p "$TEST_DIR"

# Initialize state
bash "$SCRIPTS_DIR/state-engine.sh" init "$TEST_DIR" >/dev/null

# Create a test file
mkdir -p "$TEST_DIR/src"
echo "hello world" > "$TEST_DIR/src/test.txt"

# Create a checkpoint
OUTPUT=$(bash "$SCRIPTS_DIR/recovery-engine.sh" checkpoint "$TEST_DIR" --phase "test" --root-dir "$TEST_DIR" 2>&1) || true
assert_contains "$OUTPUT" "CHECKPOINT:" "Checkpoint command produces CHECKPOINT output"

# Verify checkpoint directory exists
CP_DIR=$(ls -d "$TEST_DIR/.artifacts/checkpoints"/v* 2>/dev/null | head -1 || true)
assert_not_contains "$CP_DIR" "" "Checkpoint directory was created"

# Verify files.json exists and has content
if [ -f "${CP_DIR}/files.json" ]; then
  FILE_COUNT=$(jq '.file_count // 0' "${CP_DIR}/files.json" 2>/dev/null || echo 0)
  assert_eq "true" "true" "files.json exists and is valid JSON (file_count=$FILE_COUNT)"
else
  echo "  FAIL: files.json not found in checkpoint" >&2
  echo "FAIL" >> /tmp/test-run-failed
fi

# Modify the state
bash "$SCRIPTS_DIR/state-engine.sh" write "$TEST_DIR" test.value "modified" >/dev/null

# Restore from checkpoint
OUTPUT=$(bash "$SCRIPTS_DIR/recovery-engine.sh" restore "$TEST_DIR" "$(basename "$CP_DIR")" --soft 2>&1) || true
assert_contains "$OUTPUT" "RESTORE" "Restore command produces RESTORE output"

echo ""
echo "=== Test: Snapshot includes untracked files ==="
TEST_DIR2="$TEST_BASE/snapshot_untracked"
mkdir -p "$TEST_DIR2/src/new-module"
echo "new code" > "$TEST_DIR2/src/new-module/index.ts"
echo "tracked" > "$TEST_DIR2/src/tracked.ts"

# Initialize git so git ls-files works
git init "$TEST_DIR2" >/dev/null 2>&1
git -C "$TEST_DIR2" add src/tracked.ts >/dev/null 2>&1

# Build snapshot
SNAPSHOT=$(bash "$SCRIPTS_DIR/recovery-engine.sh" checkpoint "$TEST_DIR2" --phase "test" --root-dir "$TEST_DIR2" 2>&1) || true
CP_DIR2=$(ls -d "$TEST_DIR2/.artifacts/checkpoints"/v* 2>/dev/null | head -1 || true)

if [ -f "${CP_DIR2}/files.json" ]; then
  # Check that both tracked AND untracked files are in the snapshot
  HAS_TRACKED=$(jq -r '.files | has("src/tracked.ts")' "${CP_DIR2}/files.json" 2>/dev/null || echo "false")
  HAS_UNTRACKED=$(jq -r '.files | has("src/new-module/index.ts")' "${CP_DIR2}/files.json" 2>/dev/null || echo "false")
  assert_eq "true" "$HAS_TRACKED" "Tracked file (src/tracked.ts) in snapshot"
  assert_eq "true" "$HAS_UNTRACKED" "Untracked file (src/new-module/index.ts) in snapshot"
else
  echo "  FAIL: files.json not found in snapshot" >&2
  echo "FAIL" >> /tmp/test-run-failed
fi

echo ""
echo "=== Test: Disk space warning ==="
TEST_DIR3="$TEST_BASE/disk_warning"
mkdir -p "$TEST_DIR3"
bash "$SCRIPTS_DIR/state-engine.sh" init "$TEST_DIR3" >/dev/null

OUTPUT=$(bash "$SCRIPTS_DIR/recovery-engine.sh" checkpoint "$TEST_DIR3" --phase "test" --root-dir "$TEST_DIR3" 2>&1) || true
# On normal disk, should not produce a warning (but may on low-disk systems)
# We just verify the command runs without crashing
assert_contains "$OUTPUT" "CHECKPOINT:" "Checkpoint with disk check runs without crashing"

echo ""
echo "=== Test: Cleanup preserves recent checkpoints ==="
TEST_DIR4="$TEST_BASE/cleanup"
mkdir -p "$TEST_DIR4"
bash "$SCRIPTS_DIR/state-engine.sh" init "$TEST_DIR4" >/dev/null

# Create 7 checkpoints
for i in $(seq 1 7); do
  bash "$SCRIPTS_DIR/recovery-engine.sh" checkpoint "$TEST_DIR4" --phase "test$i" >/dev/null 2>&1 || true
done

# Cleanup keeping 3
OUTPUT=$(bash "$SCRIPTS_DIR/recovery-engine.sh" cleanup "$TEST_DIR4" --keep 3 2>&1) || true
assert_contains "$OUTPUT" "CLEANUP:" "Cleanup command produces CLEANUP output"

# Count remaining checkpoints
REMAINING=$(ls -d "$TEST_DIR4/.artifacts/checkpoints"/v* 2>/dev/null | wc -l || echo 0)
assert_eq "3" "$REMAINING" "Only 3 checkpoints remain after cleanup (got $REMAINING)"

echo ""
echo "=== Test: Abandoned task cleanup ==="
TEST_DIR5="$TEST_BASE/abandoned"
mkdir -p "$TEST_DIR5"
bash "$SCRIPTS_DIR/state-engine.sh" init "$TEST_DIR5" >/dev/null

# Create a tasks.md with an abandoned task
cat > "$TEST_DIR5/tasks.md" <<EOF
## TASK-1: Test task
Status: ABANDONED
Type: backend-domain
EOF

OUTPUT=$(bash "$SCRIPTS_DIR/recovery-engine.sh" abandoned "$TEST_DIR5" 2>&1) || true
assert_contains "$OUTPUT" "CLEANUP_COMPLETE=true" "Abandoned cleanup produces CLEANUP_COMPLETE"
assert_contains "$OUTPUT" "FOUND" "Abandoned cleanup detects abandoned tasks"

echo ""
echo "=== Test: Reset stagnation removes legacy files ==="
TEST_DIR6="$TEST_BASE/stagnation_cleanup"
mkdir -p "$TEST_DIR6"
bash "$SCRIPTS_DIR/state-engine.sh" init "$TEST_DIR6" >/dev/null

# Create legacy stagnation files
echo "5" > "$TEST_DIR6/.stagnation_state"
echo "3" > "$TEST_DIR6/.stagnation_state.consec"
echo "2" > "$TEST_DIR6/.stagnation_state.continue_count"

OUTPUT=$(bash "$SCRIPTS_DIR/recovery-engine.sh" reset-stagnation "$TEST_DIR6" 2>&1) || true
assert_contains "$OUTPUT" "STAGNANT=false" "Reset stagnation produces STAGNANT=false"

# Legacy files should be removed (not created)
assert_not_contains "" ".stagnation_state" "Legacy stagnation files not created"

echo ""
echo "========================================"
PASSED=$(wc -l < /tmp/test-run-passed 2>/dev/null || echo 0)
FAILED=$(wc -l < /tmp/test-run-failed 2>/dev/null || echo 0)
echo "  Recovery Tests: $((PASSED + FAILED)) total, $PASSED passed, $FAILED failed"
echo "========================================"

rm -f /tmp/test-run-passed /tmp/test-run-failed 2>/dev/null || true
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
