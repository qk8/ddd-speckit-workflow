You are continuing implementation of a task. The code was just written
and tests pass. Now run quality checks and produce the completion report.

Read tasks.md to determine the current task (first IN_PROGRESS or first TODO).
Read plan.md §13 and CLAUDE.md for layer rules and constraints.

─────────────────────────────────────────
STEP 3 — RUN QUALITY CHECKS
─────────────────────────────────────────
Read the current task type from tasks.md.
Load applicable checks from preset-checks.yml checks[].applies_to.
For each applicable check [X], read and execute the sub-check file
from commands/checks/check_[X]_[name].mdc.

Execute each check in order. Record result: PASS | FAIL — details.
If any check FAILS:
  1. Attempt to fix. If fixable, re-run all checks from the beginning.
  2. If not fixable after 2 attempts: mark ABANDONED.

A task cannot be marked DONE until every applicable check passes.

PER-CHECK ITERATION CAP:
  Each individual check gets up to 2 fix attempts before escalating.
  The correction loop (STEP 2) gets up to 3 attempts per test failure.
  There is NO global cap — each check is independent.

  If the SAME check fails 3 consecutive times:
    Print: "CHECK [X] FAILED 3 TIMES — escalating to human review."
    Do not retry this check; proceed to the next applicable check.

─────────────────────────────────────────
STEP 4 — SMOKE TEST (CODE-LEVEL VALIDATION)
─────────────────────────────────────────
Before marking the task DONE, verify the code actually compiles/builds.
This prevents the stagnation detector from counting tasks as done when
the code does not actually work.

Read plan.md §13 for the build/compile command:
  [build_command from plan.md §13, or "none" if no build step]

If build_command is not "none":
  RUN: [build_command]
  Use scripts/validate-tests.sh to capture and validate the result:
    bash scripts/validate-tests.sh "[build_command]" "pass"
  Read the output. If TEST_RESULT is "fail":
    1. STOP — do NOT mark the task DONE.
    2. Revert tasks.md Status from DONE back to IN_PROGRESS.
    3. Print: "SMOKE TEST FAILED — reverted to IN_PROGRESS for review."
    4. Print: "See: $TEST_OUTPUT_FILE"
    5. Attempt to fix the build (max 2 attempts, same correction loop as STEP 2).
    6. If still failing after 2 attempts: mark ABANDONED, print FAILURE_REPORT.md.

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
