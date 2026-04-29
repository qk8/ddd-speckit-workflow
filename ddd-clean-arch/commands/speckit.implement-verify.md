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

GLOBAL ITERATION CAP:
  Across all loops (correction, check-fix, regression), after 5 total
  correction iterations, STOP and escalate to human review.
  Print: "MAX CORRECTION ITERATIONS (5) REACHED — escalating to human review."

  Cap hierarchy:
    1. Correction loop (STEP 2): max 3 attempts per test failure
    2. Check-fix loop (STEP 3): max 2 attempts per check violation
    3. GLOBAL CAP: max 5 total iterations across all loops combined

─────────────────────────────────────────
STEP 4 — COMPLETION REPORT
─────────────────────────────────────────

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
