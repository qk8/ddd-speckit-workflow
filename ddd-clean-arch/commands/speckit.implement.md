Read CLAUDE.md fully.

Determine the current feature: scan .specify/specs/ and find the feature
whose tasks.md contains the first TODO task.
Read its plan.md and tasks.md.

PARALLEL MODE (batch independent tasks):
  The workflow YAML passes this instruction via input.args. When you see this
  section, process tasks in batches instead of one at a time:
  1. Find ALL TODO tasks whose Depends-on tasks are all DONE.
  2. Group them by dependency level:
     Level 0: tasks with no depends-on (or only DONE dependencies)
     Level 1: tasks whose only depends-on are Level 0 tasks
     Level 2+: tasks whose depends-on are all at lower levels
  3. Process each level as a batch. Within a batch, process tasks sequentially.
  4. After all tasks in a batch complete, print: "Batch complete: [N] tasks done."
  5. Continue to the next level. Stop when no more TODO tasks with all dependencies met.
  6. In batch mode, the completion report covers the entire batch.

Use targeted spec loading — read only the plan.md sections relevant to
the next task's Type. Do not read plan.md end to end.
Read the spec-sections mapping from templates/spec-sections.md.

Check for IN_PROGRESS tasks first:
  Follow the task selection protocol: guides/task-selection.md

Check all Depends-on tasks. If any is not DONE:
  Print: BLOCKED: TASK-[N] — incomplete dependencies: [list]
  Print: Run /speckit.status to see what is unblocked.
  Stop.

REVISION HISTORY:
  If .specify/specs/[feature]/revision_history.md exists, read it.
  This file contains summaries of previous revision attempts from
  prior revise cycles. Do not repeat fixes that were already tried
  and rejected. Read the last 3 entries only. Do not attempt to read the entire file.

━━ TASK PLAN ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Task: TASK-[N] — [title]
Type: [type]
Test file to create: [derived from §13 for this type — path and tool]
Impl files to create: [from Scope.Creates]
Files to modify: [from Scope.Modifies]
Acceptance criteria: [numbered, verbatim from task]
Do NOT: [verbatim from task]
Layer rules for this type: [from CLAUDE.md]
§16 constraints that apply: [relevant ones]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Print the plan and wait for the user to confirm before proceeding.

If the user confirms, immediately update tasks.md:
  Change Status from TODO to IN_PROGRESS for TASK-[N].
  This marks the session as active. If this session is interrupted before
  completion, check-tasks.sh will detect IN_PROGRESS and warn the next session.

If at any point the user asks to stop or the session is interrupted:
  Update tasks.md for TASK-[N]:
    Status: ABANDONED
    Abandoned at: [which step was in progress — Step 1 / Step 2 / Step 3 check [X]]
    Partial files: [list any files that were created or modified before interruption]
  Print: "Task marked ABANDONED. On next session, review partial files before restarting."
  The partial files may need manual cleanup before the task is restarted as TODO.

─────────────────────────────────────────
STEP 1 — WRITE FAILING TESTS (TDD, outside-in)
─────────────────────────────────────────
Start from the outermost test that proves the acceptance criteria.
Work inward to unit tests. Write ALL test files before any implementation.

Read plan.md §13 to determine the test type, location, and naming convention.
The test file is permanent — it will be committed alongside the implementation
and will run in regression for every future task.

  Read templates/test-instructions/[actual type value].md for the test instructions
  matching the current task Type (e.g., if Type is backend-domain, read
  templates/test-instructions/backend-domain.md).

START THE DEV ENVIRONMENT if not running (plan.md §14 task_runner.dev).
Wait until ready. API tests and E2E tests need it to fail meaningfully.
Follow the dev server failure protocol from guides/dev-server-failure-protocol.md.
Print: "Dev server started and healthy — proceeding."

TEST DATA ISOLATION — enforce before writing test code:
  Read plan.md §13 test_data_strategy.
  Every test you write must follow these rules:
    - Unit and integration tests: use factory functions from
      plan.md §13 test_data_strategy.factory_location
      Never construct domain objects by hand in test code.
    - API tests: each test creates its own data via the API or test helpers
      and cleans up in teardown. Never depend on data from another test.
    - E2E tests: use the approach from plan.md §13 e2e_data_setup.strategy.
      Each test creates its own user / entity and is independent.
      Tests must pass when run in any order and in parallel.
  If the factory location does not exist yet: create it as part of this task.

RUN THE TESTS. Expected: FAIL (implementation does not exist yet).
Print full output.
  - Unit tests: fail with "class not found" or assertion errors — correct.
  - API tests: fail with connection refused or 404 — both are correct.
  - E2E tests: fail with "element not found" or navigation error — correct.

If any test passes at this stage: STOP.
A test that passes before implementation exists is testing nothing.
Rewrite it to fail, then continue.

CAPTURE RED PHASE EVIDENCE:
  Print the exact test runner output showing the failure.
  Include the assertion message (e.g., "expected 404 but got 200").
  This output proves the test fails for the right reason.
  Do NOT proceed to STEP 2 until this evidence is printed.

Confirm: "Test file: [path] — [N] test cases, all failing. Proceeding."

─────────────────────────────────────────
STEP 1.5 — TEST AUDIT REPORT
─────────────────────────────────────────
Before writing any implementation, audit the tests you just wrote.
Produce a TEST AUDIT REPORT with these sections:

### Test Name → Acceptance Criterion Mapping
For each test case:
  Test: "[test name]"
  Maps to: "Acceptance criterion #[N] from tasks.md"
  Proof: "This test verifies [specific behavior] by asserting [specific value/condition]"

### Assertion Quality Check
For each test, verify:
  - [ ] No trivial assertions (expect(true), expect(200).toBe(200), expect(x).toEqual(x))
  - [ ] No empty mocks (jest.fn(), vi.fn() with no return value)
  - [ ] No over-masking (mocking the layer under test instead of the boundary)
  - [ ] Each assertion checks a meaningful outcome, not just "no error"
  If any check fails: rewrite the test assertion. Do not proceed with weak assertions.

### Test Data Verification
  - [ ] Factory/fixture functions used (not hand-constructed domain objects)
  - [ ] Each test creates its own data (no shared state between tests)
  - [ ] Cleanup/teardown present for API and E2E tests

Print: "TEST AUDIT: [N] tests audited, [N] issues fixed, [N] issues flagged for human review."
Print the full audit report above.

─────────────────────────────────────────
STEP 2 — IMPLEMENT
─────────────────────────────────────────
Write the implementation until the tests from Step 1 pass.

Rules (non-negotiable):
- Exact names from plan.md — any deviation is a bug, not a style choice.
- Never violate a layer rule or §16 constraint. Redesign instead.
- Never ask permission to violate a rule.
- Only touch: Scope.Creates, Scope.Modifies, and the test file from Step 1.
- Never implement any part of another task speculatively.
- Spec conflict found → stop and report. Never resolve unilaterally.

After writing implementation, RUN THE TESTS and verify they pass:
  [test runner command from plan.md §13]
Print full output.
  - All new tests must PASS
  - Report: "Tests: [N] passed, [N] failed"

Then RUN THE FULL REGRESSION SUITE:
  [regression_command.all from plan.md §13]
Print: "Regression: [total N] tests, [N] failed"
  - Zero new failures allowed
  - If any pre-existing test fails: STOP, diagnose root cause, fix, re-run

─────────────────────────────────────────
INLINE CORRECTION LOOP (if tests fail)
─────────────────────────────────────────
If any test fails after implementation, follow the correction loop:
guides/correction-loop.md (triage → integrity audit → 3 attempts → escalation).

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
