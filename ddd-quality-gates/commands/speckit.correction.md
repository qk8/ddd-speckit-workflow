# speckit.correction

Run when tests fail after implementation.

This command:
1. Reads the test failure output
2. Classifies each failure into T/I/E/R triage
3. Audits test integrity (5 questions)
4. Attempts fixes (max 3), running full suite after each
5. If all 3 attempts fail: generates FAILURE_REPORT.md and halts

─────────────────────────────────────────
TRIAGE CLASSIFICATION
─────────────────────────────────────────
Classify each failing test into EXACTLY ONE category:

  [T] Test Flaw    — The test is incorrectly written. The acceptance criterion
                     is valid; the test fails to correctly express it.
                     FIX: Rewrite the test. Do NOT touch the implementation.

  [I] Implementation Error — The implementation does not satisfy the
                     acceptance criterion. The test correctly expresses what
                     is required.
                     FIX: Fix the implementation.

  [E] Environment Failure — The failure is caused by a missing dependency,
                     misconfigured environment, version conflict, or external
                     service unavailability. The code and tests are correct.
                     FIX: Fix the environment configuration. Do NOT touch
                     the application code.

  [R] Regression   — A previously passing test now fails as a side effect of
                     changes made in the current task unit. Neither the test
                     nor the pre-existing implementation was intended to change.
                     FIX: Identify which change broke the existing test.
                     Fix the regression.

─────────────────────────────────────────
TEST INTEGRITY AUDIT
─────────────────────────────────────────
Before touching ANY implementation, evaluate every failing test:

  1. Does this test correctly express the acceptance criterion?
     Read the criterion. Read the test. Do they match?
  2. Is the assertion testing what it claims to test?
     Could the test pass for the wrong reason?
  3. Are the test inputs realistic and non-degenerate?
     Do edge case inputs actually exercise the edge case?
  4. Is the test isolated?
     Is it accidentally testing a dependency instead of the unit under test?
  5. Could this be a flaky test?
     Is there timing sensitivity, ordering sensitivity, or shared mutable state?

  IF classified [T] — Test Flaw:
    Fix the test to correctly express the acceptance criterion.
    Do NOT touch the implementation.
    Re-run the full suite.

  IF classified [E] — Environment Failure:
    Fix the environment configuration (not the application code).
    Re-run the full suite.

  IF classified [I] or [R]:
    Confirm the test is valid (per the 5 questions above) before
    touching implementation. Proceed to CORRECTION ATTEMPTS.

─────────────────────────────────────────
CORRECTION ATTEMPTS (max 3)
─────────────────────────────────────────
Attempt 1:
  1. Diagnose the root cause of the failure by reading the error output,
     tracing execution, and identifying the specific line of logic that fails.
  2. Apply a targeted, minimal fix. Do NOT refactor unrelated code.
  3. Run the FULL test suite (not just the new tests).
  4. If all tests pass: STOP. Return to implement loop.

Attempt 2:
  1. Re-read the relevant contracts (api-contract.yaml, data-model.sql,
     interfaces) and acceptance criteria (tasks.md).
  2. Reconsider whether your implementation approach is fundamentally
     misaligned with the contract or criteria.
  3. Apply a revised approach.
  4. Run the FULL test suite.
  5. If all tests pass: STOP. Return to implement loop.

Attempt 3:
  1. Broaden the diagnosis. Check for:
     - Hidden dependencies between task units.
     - Side effects in shared state or global configuration.
     - Implicit assumptions in earlier task units that are now violated.
     - Transitive contract violations.
  2. Apply a fix addressing the root cause, not the symptom.
  3. Run the FULL test suite.
  4. If all tests pass: STOP. Return to implement loop.

─────────────────────────────────────────
ESCALATION (After 3 Failed Attempts)
─────────────────────────────────────────
Attempt 4 does not exist. When 3 implementation attempts fail:

  1. Generate FAILURE_REPORT.md (see template).
  2. Update tasks.md for TASK-[N]:
       Status: ABANDONED
       Abandoned at: speckit.correction — 3 attempts exhausted
       Partial files: [list any files that were created or modified]
  3. Print: "ESCALATION: 3 correction attempts exhausted. See FAILURE_REPORT.md"
  4. Halt. Do NOT attempt to work around the failure.
  5. Do NOT proceed to any subsequent phase.

FAILURE_REPORT.md schema:
  ---
  created_at: [ISO-8601]
  task_id: [TASK-XXX]
  phase: implement
  status: BLOCKED

  failing_tests:
    - test_name: [name]
      test_file: [path]
      error_output: |
        [full error output]
      category: T | I | E | R

  correction_attempts:
    - attempt: 1
      hypothesis: [root cause hypothesis]
      fix_applied: [what was changed]
      files_modified: [list of files]
      result: [full suite output summary]
    - attempt: 2
      ...
    - attempt: 3
      ...

  root_cause_hypothesis: |
    [Best current understanding of why the failure occurs]

  recommended_human_action: |
    [Specific action the human should take — NOT "investigate further"]

  files_modified_this_session: [list]
