# Inline Correction Loop

When tests fail after implementation, follow this protocol before proceeding.

## TRIAGE CLASSIFICATION

Classify each failing test into EXACTLY ONE:

**[T] Test Flaw** — The test is incorrectly written. The acceptance criterion
is valid; the test fails to correctly express it.
FIX: Rewrite the test. Do NOT touch the implementation.

**[I] Implementation Error** — The implementation does not satisfy the
acceptance criterion. The test correctly expresses what is required.
FIX: Fix the implementation.

**[E] Environment Failure** — The failure is caused by a missing dependency,
misconfigured environment, version conflict, or external
service unavailability. The code and tests are correct.
FIX: Fix the environment configuration. Do NOT touch the application code.

**[R] Regression** — A previously passing test now fails as a side effect of
changes made in the current task unit.
FIX: Identify which change broke the existing test. Fix the regression.

## TEST INTEGRITY AUDIT

Before touching ANY implementation:

1. Does this test correctly express the acceptance criterion?
2. Is the assertion testing what it claims to test?
3. Are the test inputs realistic and non-degenerate?
4. Is the test isolated?
5. Could this be a flaky test?

IF [T] — Fix the test. Re-run full suite.
IF [E] — Fix the environment. Re-run full suite.
IF [I] or [R] — Proceed to correction attempts.

## CORRECTION ATTEMPTS (max 3)

Attempt 1:
  1. Diagnose root cause by reading error output, tracing execution.
  2. Apply a targeted, minimal fix. Do NOT refactor unrelated code.
  3. Run the FULL test suite.
  4. If all pass: STOP. Continue to next step.

Attempt 2:
  1. Re-read relevant contracts (api-contract.yaml, data-model.sql,
     interfaces) and acceptance criteria (tasks.md).
  2. Reconsider whether the implementation approach is misaligned.
  3. Apply a revised approach.
  4. Run the FULL test suite.
  5. If all pass: STOP. Continue to next step.

Attempt 3:
  1. Broaden diagnosis: check for hidden dependencies, shared state
     side effects, implicit assumptions in earlier tasks, transitive
     contract violations.
  2. Apply a fix addressing the root cause, not the symptom.
  3. Run the FULL test suite.
  4. If all pass: STOP. Continue to next step.

## ESCALATION (After 3 Failed Attempts)

  1. Generate FAILURE_REPORT.md with:
       - created_at, task_id, phase, status: BLOCKED
       - failing_tests (name, file, error, T/I/E/R category)
       - correction_attempts (hypothesis, fix, files, result)
       - root_cause_hypothesis, recommended_human_action
  2. Update tasks.md:
       Status: ABANDONED
       Abandoned at: speckit.implement
  3. Print: "ESCALATION: 3 correction attempts exhausted. See FAILURE_REPORT.md"
  4. Halt. Do NOT proceed to next step.
