Read .artifacts/unified-context.json. This file contains all context for the current task:
  - Task details (id, title, status, type, depends_on, scope, acceptance_criteria, do_not)
  - Relevant plan.md sections (FULL text, no truncation)
  - §16 constraints
  - Layer rules (only relevant layers for this task type)
  - Test instructions (FULL text, no truncation)
  - Error memory corrections
  - Checkpoint state

If unified-context.json does not exist, generate it:
  Run: bash scripts/unified-context.sh "$(bash scripts/find-first-feature.sh)" [task_id] [task_type]

# ── Single-task mode (Fix 13: parallel batch support) ─────────
# If input.args starts with "--single-task TASK-N", process ONLY
# that specific task. This enables true parallel batch execution
# where each task gets its own prompt call.
#
# Usage: speckit.write-test --single-task TASK-3
#
# In single-task mode:
#   - Skip the PARALLEL MODE section entirely
#   - Use the explicitly specified task ID instead of auto-detecting
#   - Process only that one task's test file

# ── Determine target task ──────────────────────────────────────
if input.args starts with "--single-task ":
  TARGET_TASK_ID = extract the task ID from input.args
  Determine the current feature: scan .specify/specs/ and find the feature
  whose tasks.md contains the first TODO task.
  But override: use TARGET_TASK_ID instead of the first TODO task.
else:
  Determine the current feature: scan .specify/specs/ and find the feature
  whose tasks.md contains the first TODO task.
  TARGET_TASK_ID = auto-detected task ID

Read its plan.md and tasks.md.

CHECKPOINT RECOVERY (read .workflow-state.json first):
  If .workflow-state.json exists in the feature directory, read it.
  This file contains structured checkpoint data from previous iterations:
    - Task statuses (DONE, IN_PROGRESS, ABANDONED) with timestamps
    - Check results per task (deterministic and batched Claude checks)
    - Stagnation state and retrospective schedule
  Use the checkpoint to:
    1. Verify task state consistency with tasks.md (flag discrepancies)
    2. Skip re-running checks that already passed (read .checks from checkpoint)
    3. Recover from interruption: if tasks.md shows IN_PROGRESS but checkpoint
       shows DONE, trust tasks.md (it is the source of truth)
    4. If tasks.md is missing or unreadable, fall back to checkpoint data
  Print: "Checkpoint loaded: [N] tasks tracked" if checkpoint found.

PARALLEL MODE (batch independent tasks):
  The workflow YAML passes this instruction via input.args. When you see this
  section, process tasks in batches instead of one at a time:
  1. Read tasks.md and find ALL TODO tasks whose Depends-on tasks are all DONE.
     Derive the batch directly from tasks.md — do NOT rely on .artifacts/batch_tasks.txt
     (that file is written AFTER processing, not before).
  2. Process each task in the batch sequentially (write tests for TASK-N, then TASK-N+1).
  3. After all tasks in a batch complete, print: "Batch complete: [N] tasks done."
  4. Write the batch task list to .artifacts/batch_tasks.txt:
     echo "TASK-N, TASK-M, ..." > .artifacts/batch_tasks.txt
     This file is read by downstream steps (verify, batch-consistency) — not by write-test itself.
  5. Continue to the next batch (repeat: find TODO tasks with all deps DONE).
  6. Stop when no more TODO tasks have all dependencies met.
  7. In batch mode, the completion report covers the entire batch.
  If no batch can be formed (no TODO tasks with all deps met):
    Print: "No batch available — all deps unmet or no TODO tasks remain."
    Exit cleanly. Do NOT attempt to process tasks with unmet dependencies.

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

━━ KNOWN PATTERNS (from error memory) ━━━━━━━━━━━━━━━━━━━━━━━━━
Run: bash scripts/error-memory.sh read "$(bash scripts/find-first-feature.sh)"
This prints any known correction patterns, abandoned task reasons,
and drift patterns from recent tasks. Apply these learnings to
avoid repeating past mistakes on this task.
If no patterns are printed: no prior learnings — proceed normally.

━━ TASK PLAN ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Task: ${TARGET_TASK_ID:-TASK-[N]} — [title]
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
    Abandoned at: [which step was in progress — Step 1 / Step 2 check [X]]
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
Use scripts/validate-tests.sh to capture and validate the result:
  bash scripts/validate-tests.sh "[test_runner_command_from_plan_md_§13]" "fail"
Read the output variables: TEST_RESULT, TEST_FAILED, TEST_OUTPUT_FILE.

If TEST_RESULT is "unexpected_pass": STOP.
A test that passes before implementation exists is testing nothing.
Rewrite it to fail, then re-run validate-tests.sh.

If TEST_RESULT is "error": the test runner itself failed.
Diagnose the issue (missing dependency? wrong command?) and fix before proceeding.

CAPTURE RED PHASE EVIDENCE:
  Read $TEST_OUTPUT_FILE and print the failure lines showing the test fails.
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
STEP 1.6 — DETERMINISTIC TEST QUALITY CHECK
─────────────────────────────────────────
The self-audit above is advisory. Run the deterministic quality checker to catch
anti-patterns the LLM may overlook or self-censor:

  bash scripts/verify-test-quality.sh "[test_file_path]"

If it reports ERRORS: fix each one before proceeding.
If it reports WARNINGS: note them for human review but do not block.
If the test file path is not known, pass the test directory:
  bash scripts/verify-test-quality.sh "[test_directory]"

Print: "DETERMINISTIC CHECK: [N] errors, [M] warnings"

─────────────────────────────────────────
STEP 1.7 — TEST COMPLETENESS CHECK
─────────────────────────────────────────
Verify test coverage is complete before proceeding to implementation:

POSITIVE COVERAGE (happy path):
  For each acceptance criterion, confirm at least one test exists.
  Test name should reference the specific scenario (not just "test 1").

NEGATIVE COVERAGE (error paths):
  For each public method / API endpoint, confirm at least one negative test:
    - Invalid input (empty string, null, wrong type, out-of-range value)
    - Unauthorized access (missing auth, wrong role, expired token)
    - Conflict detection (duplicate key, concurrent modification)
    - Resource exhaustion (empty collection, missing dependency)
  If the acceptance criteria only cover happy paths: add at least one
  negative test per public interface. Document why no negative test is needed
  if the interface is internal-only.

SEMANTIC QUALITY:
  Tests must PROVE acceptance criteria, not just exercise code:
    - "expect(result.status).toBe(200)" alone is NOT sufficient
    - "expect(result.body.data.id).toBe(expectedId)" PROVES the right entity was created
    - Prefer specific assertions over "no exception thrown"
    - Each test should have exactly one primary assertion about the outcome
    - Helper assertions (setup verification) are acceptable

Print: "TEST COMPLETENESS: [N] positive, [N] negative, [N] semantic issues"

─────────────────────────────────────────
STEP 1.8 — SPEC-TO-TEST VALIDATION
─────────────────────────────────────────
Validate that test assertions match spec acceptance criteria:

Run: bash scripts/spec-to-test-validate.sh <feature_dir> <task_id>

If VALIDATION=PASS: all spec criteria are reflected in test assertions. Proceed.
If VALIDATION=NEEDS_REVIEW: fix the mismatches listed, then re-run the script.
Do NOT proceed until VALIDATION=PASS or document why each mismatch is intentional.

Common mismatches this catches:
  - Test asserts wrong expected value (e.g., expect(5) when spec says 6)
  - Test missing assertion for a behavioral criterion
  - Test asserts a different exception type than spec requires
  - Test missing negative/edge-case assertions

Print: "SPEC-TO-TEST: VALIDATION=[PASS|NEEDS_REVIEW]"
