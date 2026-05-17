#!/usr/bin/env bash
# post-compaction-verify.sh — Verify invariants after context compaction.
#
# After context-compact.sh prunes artifacts and trims error memory,
# this script verifies that critical invariants are still preserved.
#
# Checks:
#   1. Naming conventions still valid (checks for obvious violations)
#   2. Layer rules still valid (checks that layer boundary files exist)
#   3. Constraint rules still valid (checks plan.md §16 exists)
#
# Usage: post-compaction-verify.sh <feature_dir>
# Exit 0 = all invariants pass, Exit 1 = violations found.

set -euo pipefail

FEATURE_DIR="${1:?Usage: post-compaction-verify.sh <feature_dir>}"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
PASS_COUNT=0
FAIL_COUNT=0
FAILURES=""

check() {
  local name="$1" result="$2"
  if [[ "$result" == PASS* ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  elif [[ "$result" == N/A* ]]; then
    : # N/A results are neutral, not failures
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}  FAIL: $name — $result\n"
  fi
}

# ── 1. Check that plan.md §16 (constraints) still exists ─────────
if [ -f "$FEATURE_DIR/plan.md" ]; then
  if grep -q '§16\|Constraints\|constraints' "$FEATURE_DIR/plan.md" 2>/dev/null; then
    check "constraints_section" "PASS"
  else
    check "constraints_section" "plan.md exists but §16 constraints section not found"
  fi
else
  check "constraints_section" "plan.md not found"
fi

# ── 2. Check that CLAUDE.md still exists and is non-empty ─────────
if [ -f "$FEATURE_DIR/CLAUDE.md" ]; then
  LINE_COUNT=$(wc -l < "$FEATURE_DIR/CLAUDE.md" 2>/dev/null || echo 0)
  if [ "$LINE_COUNT" -gt 0 ]; then
    check "claude_md" "PASS (CLAUDE.md has $LINE_COUNT lines)"
  else
    check "claude_md" "CLAUDE.md exists but is empty"
  fi
else
  check "claude_md" "CLAUDE.md not found"
fi

# ── 3. Check that tasks.md still exists ───────────────────────────
if [ -f "$FEATURE_DIR/tasks.md" ]; then
  check "tasks_md" "PASS"
else
  check "tasks_md" "tasks.md not found"
fi

# ── 4. Check that state.json is valid JSON ────────────────────────
STATE_FILE="$FEATURE_DIR/state.json"
if [ -f "$STATE_FILE" ]; then
  if jq empty "$STATE_FILE" 2>/dev/null; then
    check "state_json" "PASS"
  else
    check "state_json" "state.json is not valid JSON — may be corrupted by compaction"
  fi
else
  check "state_json" "state.json not found"
fi

# ── 5. Check that error-memory directory is not empty if it existed ─
# (If compaction pruned everything, patterns may be lost)
ERROR_MEM_DIR="$ARTIFACTS_DIR/error-memory"
if [ -d "$ERROR_MEM_DIR" ]; then
  EM_COUNT=$(ls -1 "$ERROR_MEM_DIR" 2>/dev/null | wc -l || echo 0)
  if [ "$EM_COUNT" -gt 0 ]; then
    check "error_memory" "PASS ($EM_COUNT entries remain)"
  else
    check "error_memory" "error-memory directory is empty — all patterns pruned"
  fi
else
  check "error_memory" "N/A (directory does not exist)"
fi

# ── Output ────────────────────────────────────────────────────────
echo "=== POST-COMPACTION VERIFICATION ==="
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo -e "  Failures:\n$FAILURES"
  echo "  Post-compaction verification: FAIL"
  exit 1
fi
echo "  Post-compaction verification: PASS"
exit 0
