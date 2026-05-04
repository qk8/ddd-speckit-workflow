You are continuing implementation of a task. The code was just written
and tests pass. Now run quality checks and produce the completion report.

Read tasks.md to determine the current task (first IN_PROGRESS or first TODO).
Read plan.md §13 and CLAUDE.md for layer rules and constraints.

─────────────────────────────────────────
STEP 3 — RUN QUALITY CHECKS
─────────────────────────────────────────
Read the current task type from tasks.md.
Load applicable checks from ddd-clean-arch/preset.yml, filtered by tier:

TIER FILTERING:
  preset.yml assigns each check a tier:
  - critical (A, BC, D, I, L, Z): run every task — non-negotiable quality gates
  - secondary (E, F, G, J, K, M, N, O): run only when the LAST task for a
    module type completes (e.g., last backend-api task)
  - tertiary (H, P, Q, R, S, T, U): skip entirely during per-task execution —
    handled in Phase 6 code review and Phase 7 final verify

  For this task, run only critical-tier checks.
  Check which module type this task belongs to (from tasks.md Type field).
  If this is the last task of that type (count remaining TODO/IN_PROGRESS tasks
  of the same type), also run secondary-tier checks for that module.

─────────────────────────────────────────
STEP 3A — DETERMINISTIC CHECKS (check-runner.sh)
─────────────────────────────────────────
Run the deterministic check engine:

  bash scripts/check-runner.sh "[feature_dir]" "[task_type]"

This executes all deterministic checks (A, AS, BC, D, E, F, I, K, L, O, OW, R, US, Z) in parallel.
Results are written to .artifacts/check-results/<check-id>.result (PASS/FAIL).

If check-runner.sh exits 0: all deterministic checks passed. Proceed to STEP 3B.
If check-runner.sh exits 1: deterministic checks failed. Proceed to STEP 3C.

─────────────────────────────────────────
STEP 3B — BATCHED CLAUDE CHECKS
─────────────────────────────────────────
For non-deterministic checks that need Claude judgment (G, H, J, M, N, P, Q, S, T):

If this is the LAST task of the current module type, run these checks:
  - Read the sub-check file from commands/checks/check_[X]_[name].mdc for each
  - Execute each check. Record result: PASS | FAIL — details.

For non-last tasks, skip batched Claude checks (handled at module boundary).

Note: Checks O (Security Hardening) and U (Session & Token Security) are now
deterministic (OW, US scripts) and run in STEP 3A. They are no longer here.

─────────────────────────────────────────
STEP 3C — FIX DETERMINISTIC CHECK FAILURES
─────────────────────────────────────────
If check-runner.sh reported failures:
  1. Read .artifacts/check-results/[X].result for each failed check.
  2. Attempt to fix the underlying issue.
  3. Re-run check-runner.sh from the beginning.
  4. If not fixable after 2 attempts: mark ABANDONED.

─────────────────────────────────────────
STEP 3D — ERROR BUDGET & ESCALATION
─────────────────────────────────────────
ERROR BUDGET:
  - Critical checks: 0 error budget — ALL must pass. No exceptions.
  - Secondary checks: 1 error budget — at most one may fail (logged as warning).
  - If error budget exceeded: stop revising, produce summary report, escalate.

PER-CHECK ITERATION CAP:
  Deterministic checks (check-runner.sh): up to 2 fix attempts.
  Batched Claude checks: up to 2 fix attempts.
  The correction loop (STEP 2) gets up to 3 attempts per test failure.
  There is NO global cap — each check is independent.

  If the SAME check fails 3 consecutive times:
    1. Print: "CHECK [X] FAILED 3 TIMES — escalating to human review."
    2. Create .artifacts/failure-report.md:
       ## Failure Report — Check [X] ([check_name])
       - **Task**: [TASK-N]
       - **Check**: [X] — [check_name]
       - **Tier**: [critical/secondary]
       - **Attempt 1**: [summary of fix attempt + error]
       - **Attempt 2**: [summary of fix attempt + error]
       - **Recommendation**: ABANDON or HUMAN REVIEW
    3. Mark task ABANDONED in tasks.md (Status: ABANDONED, Abandoned at: STEP 3D check [X]).
    4. Print: "Task ABANDONED due to unresolvable check failure."
    5. Proceed to next task (do NOT block the workflow).

A task cannot be marked DONE until every applicable check passes — unless it has been
ABANDONED per the procedure above, in which case the failure report serves as the
record and the workflow continues to the next task.

─────────────────────────────────────────
STEP 4 — SMOKE TEST (CODE-LEVEL VALIDATION)
─────────────────────────────────────────
Before marking the task DONE, verify the code actually compiles/builds.
This prevents the stagnation detector from counting tasks as done when
the code does not actually work.

Read plan.md §13 for the build/compile command:
  [build_command from plan.md §13, or "none" if no build step]

PRE-VALIDATION:
  Before running the build command, verify the required files exist:
  - If build_command starts with "npm": verify package.json exists
  - If build_command starts with "mvn": verify pom.xml exists
  - If build_command starts with "gradle": verify build.gradle exists
  - If build_command starts with "go": verify go.mod exists
  - If build_command starts with "pytest": verify pytest config exists
  - If the required file does NOT exist: flag as BUILD_COMMAND_ERROR,
    add a fix task to tasks.md to correct plan.md §13, and skip smoke test.

If build_command is not "none":
  RUN: [build_command]
  Use scripts/validate-tests.sh to capture and validate the result:
    bash scripts/validate-tests.sh "[build_command]" "pass"
  Read the output. If TEST_RESULT is "fail":
    1. STOP — do NOT mark the task DONE.
    2. Revert tasks.md Status from DONE back to IN_PROGRESS.
    3. Print: "SMOKE TEST FAILED — reverted to IN_PROGRESS for review."
    4. Print: "See: $TEST_OUTPUT_FILE"
    5. After each failure, check if the SAME error message appeared before:
       - If error is about a missing file/command that plan.md says exists:
         Flag BUILD_COMMAND_MISMATCH — add fix task to correct plan.md §13.
       - If error is about missing source files: this is an implementation error.
    6. Attempt to fix the build (max 2 attempts, same correction loop as STEP 2).
    7. If still failing after 2 attempts: mark ABANDONED, print FAILURE_REPORT.md.

If no build step (build_command is "none"):
  Run a minimal import/load check instead:
    - For Node.js/TypeScript: run "node -e 'require(\"./src/index\")'" or equivalent
    - For Python: run "python -c 'import [main_module]'"
    - For Go: run "go build ./..." in the module root
    - For Ruby: run "ruby -c lib/**/*.rb"
  Use scripts/validate-tests.sh with expected "pass".
  If it fails: same fix-and-revert protocol as above.

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

━━ SPEC LEARNINGS ━━━━━━━━━━━━━━━━━━━━━━
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

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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
bash scripts/check-point.sh write "$FEATURE_DIR" task_done "$TASK_ID" "$TASK_TYPE" "$BUILT" "$TEST_FILE" 2>/dev/null || true

echo "Checkpoint updated: $TASK_ID marked DONE in .workflow-state.json"
