# ── IMPLEMENT VERIFY — COMPLETION REPORT ───────────────────────
# Referenced by: speckit.implement-verify.md (orchestrator)
# Contains: completion report, checkpoint, error memory, trends

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 5 — COMPLETION REPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Print:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COMPLETION REPORT — TASK-[N]

Test file: [path] ([N] test cases committed)

Acceptance criteria:
  [1] [criterion] → SATISFIED — [test name that proves it]
  ...

Do NOT constraint: [restate] → RESPECTED — [how]

Read templates/check-report-template.md for the 21-check results table.

Test data isolation: [confirmed — factory/fixture used | N/A for unit tests]

SMOKE TEST: [PASS — build/load verified | N/A — no build step]
ROLLBACK FILES: [list of files restored/removed | none]
ROLLBACK NOTE: [rollback note from tasks.md | none]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── SPEC LEARNINGS ────────────────────────────────────────────
A) Spec decision wrong/impractical?    [yes — description | none]
B) Gap requiring a decision?           [yes — description | none]
C) CLAUDE.md rule ambiguous?           [yes — description | none]
D) Assumption invalidated by library?  [yes — description | none]

For each finding: propose a change to plan.md [section.field → new value].
Do NOT apply until user confirms. List all and wait for confirmation.
After confirmation: update plan.md and record in tasks.md.

# ── PERSIST UNAPPLIED LEARNINGS ───────────────────────────
# If any spec learning was proposed but NOT applied (user rejected or not yet
# confirmed), persist it to a pending file so speckit.retrospect can cross-check.

Read the current feature directory from tasks.md (the directory containing tasks.md).
PENDING_DIR="[feature_dir]/.artifacts"
mkdir -p "$PENDING_DIR"
PENDING_FILE="$PENDING_DIR/pending-learnings.md"

For each learning that was proposed but NOT applied:
  Append to pending-learnings.md:
    ## TASK-[N] — [date in UTC]
    - Type: [A|B|C|D from spec learnings categories]
    - Description: [the learning]
    - Proposed change: [plan.md section.field -> new value]
    - Status: PENDING
    - Rejected: [yes/no/unknown]

Print: "Pending learnings written to $PENDING_FILE"

Update tasks.md for TASK-[N]:
  Status: DONE
  Built: [one sentence]
  Test file: [path]
  Spec changes applied: [list | none]
  Perf warning: [Check [J] warning text | none]
    (Record any performance budget warnings here so retrospect can read them.)
  Rollback note: [regression note | none]
    (If this task was rolled back and retried, record the reason.)

# Recovery note for the next session if this task was previously ABANDONED:
# If the task was previously ABANDONED and this is a restart, verify that
# partial files from the previous attempt are consistent with what was just built.
# Remove any stale partial artifacts before marking DONE.

Count total DONE tasks. The workflow (check-tasks.sh) handles adaptive retrospective
cadence based on project complexity. Print a completion notice:
  "[N] tasks completed."

# ── PERSIST CHECKPOINT ──────────────────────────────────────
# After updating tasks.md, write structured checkpoint data
# so future sessions can resume without re-parsing tasks.md.

FEATURE_DIR="[feature_dir from tasks.md location]"
TASK_ID="[current task ID, e.g. TASK-3]"
TASK_TYPE="[task type from tasks.md]"
BUILT="[one sentence from Built field]"
TEST_FILE="[path from Test file field]"

mkdir -p "$FEATURE_DIR/.artifacts"

# Write checkpoint using check-point.sh helper (bash 3.2 compatible)
bash scripts/check-point.sh write "$FEATURE_DIR" task_done "$TASK_ID" "$TASK_TYPE" "$BUILT" "$TEST_FILE" 2>/dev/null || {
    echo "WARNING: Checkpoint write failed for $TASK_ID — state may not persist across sessions." >&2
    echo "Continuing anyway — tasks.md is the source of truth." >&2
  }

echo "Checkpoint updated: $TASK_ID marked DONE in .workflow-state.json"

# ── UPDATE ERROR MEMORY ─────────────────────────────────────
# Record corrections and patterns from this task for future tasks.
# The diagnostic-classifier.sh output (from STEP 2) contains
# classification info that can be used to populate error memory.

FEATURE_DIR="[feature_dir from tasks.md location]"
TASK_ID="[current task ID, e.g. TASK-3]"

# If any corrections were made during the inline correction loop,
# record them in error memory for future tasks to learn from.
# The diagnostic classifier output (if available) has the classification
# AND specific evidence for targeted learning.

if [ -f "$TEST_OUTPUT_FILE" ]; then
  # Extract classification and specific evidence from diagnostic output
  DIAG_CLASS=$(cat "${TEST_OUTPUT_FILE%.txt}_diag.out" 2>/dev/null | grep "^CLASSIFICATION=" | head -1 | sed 's/CLASSIFICATION=//')
  DIAG_EVIDENCE=$(cat "${TEST_OUTPUT_FILE%.txt}_diag.out" 2>/dev/null | grep "^EVIDENCE=" | head -1 | sed 's/EVIDENCE=//')

  if [ -n "$DIAG_CLASS" ]; then
    # Store both classification and specific evidence
    bash scripts/error-memory.sh update "$FEATURE_DIR" "$TASK_ID" "$DIAG_CLASS" "${DIAG_EVIDENCE:-Test failure during implementation}" "Review diagnostic output and apply fix pattern" "${DIAG_EVIDENCE:-}" 2>/dev/null || true
  fi

  # Extract IMPL_FAULT_COUNT for error memory
  DIAG_IMPL_COUNT=$(cat "${TEST_OUTPUT_FILE%.txt}_diag.out" 2>/dev/null | grep "^IMPL_FAULT_COUNT=" | head -1 | sed 's/IMPL_FAULT_COUNT=//')
  DIAG_MIXED=$(cat "${TEST_OUTPUT_FILE%.txt}_diag.out" 2>/dev/null | grep "^MIXED_FAULTS=" | head -1 | sed 's/MIXED_FAULTS=//')
  if [ -n "$DIAG_MIXED" ] && [ "$DIAG_MIXED" = "true" ]; then
    bash scripts/error-memory.sh update "$FEATURE_DIR" "$TASK_ID" "mixed_faults" "Mixed TEST_FAULT and IMPL_ERROR detected — requires human review" "Cross-fault diagnosis needed" "" 2>/dev/null || true
  fi
fi

# Record any drift patterns detected during quick drift check
if [ -f "$FEATURE_DIR/.artifacts/post-implementation-drift.md" ]; then
  DRIFT_ISSUES=$(grep -c "VIOLATION\|DRIFT" "$FEATURE_DIR/.artifacts/post-implementation-drift.md" 2>/dev/null || echo 0)
  # Note: grep -c returns non-zero when count is 0, hence || echo 0 is safe here
  if [ "$DRIFT_ISSUES" -gt 0 ]; then
    bash scripts/error-memory.sh update "$FEATURE_DIR" "$TASK_ID" "drift" "$DRIFT_ISSUES drift violations detected" "Review plan.md §16 constraints" 2>/dev/null || true
  fi
fi

echo "Error memory updated for $TASK_ID"

# ── LOG TEST HEALTH TRENDS ────────────────────────────────────
# Track test metrics over time to detect degradation.
FEATURE_DIR="[feature_dir from tasks.md location]"
TASK_ID="[current task ID]"
TASK_TYPE="[task type from tasks.md]"

bash scripts/test-health-log.sh "$FEATURE_DIR" "$TASK_ID" "$TASK_TYPE" 2>/dev/null || true

# ── LOG COMPLEXITY TRENDS ─────────────────────────────────────
# Track code complexity over time to detect growth.
bash scripts/complexity-trend.sh "$FEATURE_DIR" "$TASK_ID" 2>/dev/null || true
