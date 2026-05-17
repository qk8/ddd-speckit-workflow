# ── speckit.correction-loop — Inline Correction Loop ──────────────
# Called when tests fail after implementation.
# Delegates to diagnostic classifier, then executes a bounded correction loop.
#
# Usage: Called from speckit.implement when validate-tests.sh returns failure.
# Requires: TEST_OUTPUT_FILE set to path of test output.

─────────────────────────────────────────
STEP 1 — DIAGNOSTIC CLASSIFICATION
─────────────────────────────────────────

Run the independent diagnostic classifier:
  bash scripts/diagnostic-classifier.sh \
    "$(bash scripts/find-first-feature.sh)" \
    "[task_type]" \
    "$(cat $TEST_OUTPUT_FILE)" \
    "$(cat ${TEST_OUTPUT_FILE%.txt}_impl.out 2>/dev/null || echo '')"

Read the diagnostic output: CLASSIFICATION, EVIDENCE, CONFIDENCE, REQUIRED_ACTION, MIXED_FAULTS.
Save diagnostic output to: .artifacts/diagnostic-output.txt

ENFORCED ACTION FROM DIAGNOSTIC (NON-NEGOTIABLE):
  FIX_TEST  → You MUST NOT modify implementation files. Fix ONLY the test file.
  FIX_IMPL  → Fix the implementation only. Do NOT modify test files.
  FIX_ENV   → Fix environment configuration ONLY. Do NOT touch application or test code.
  HUMAN     → STOP. Print evidence. Mark task for human review. Proceed to next task.
  RETRY     → Use EVIDENCE to guide choice between test or implementation fixes.

If MIXED_FAULTS=true: STOP. Print "Mixed faults detected — human review required."
  Mark task for human review. Proceed to next task.

─────────────────────────────────────────
STEP 2 — TRIAGE (per guides/correction-loop.md)
─────────────────────────────────────────

Classify each failing test into EXACTLY ONE:
  [T] Test Flaw   — Test is incorrectly written. Fix the test, not implementation.
  [I] Implementation Error — Implementation doesn't satisfy acceptance criterion.
  [E] Environment Failure — Missing dependency, misconfigured environment.
  [R] Regression  — Previously passing test now fails due to current task changes.

─────────────────────────────────────────
STEP 3 — CORRECTION ATTEMPTS (max 3)
─────────────────────────────────────────

GLOBAL_CAP = 10 total correction attempts across all checks for a task.
Track: bash scripts/state-engine.sh get "$FEATURE_DIR" corrections.global_total

Before each attempt:
  1. Record current state of all modified files:
     mkdir -p ".artifacts/correction-snapshots/attempt-${ATTEMPT_NUM}"
     git diff --name-only | while read f; do
       cp "$f" ".artifacts/correction-snapshots/attempt-${ATTEMPT_NUM}/" 2>/dev/null || true
     done

Attempt 1:
  1. Diagnose root cause by reading error output, tracing execution.
  2. Apply a targeted, minimal fix. Do NOT refactor unrelated code.
  3. Run the FULL test suite via: bash scripts/validate-tests.sh "[test_runner]" "pass"
  4. If all pass: STOP correction loop. Continue to next step.

Attempt 2:
  1. Re-read relevant contracts (api-contract.yaml, data-model.sql, interfaces)
     and acceptance criteria (tasks.md).
  2. Reconsider whether the implementation approach is misaligned.
  3. Apply a revised approach.
  4. Run the FULL test suite.
  5. If all pass: STOP correction loop.

Attempt 3:
  1. Broaden diagnosis: check hidden dependencies, shared state side effects,
     implicit assumptions in earlier tasks, transitive contract violations.
  2. Apply a fix addressing the root cause, not the symptom.
  3. Run the FULL test suite.
  4. If all pass: STOP correction loop.

After each attempt:
  - Increment global counter: bash scripts/state-engine.sh task-incr corrections.global_total
  - If global_total >= 10: STOP. Print "ESCALATION: Global correction cap (10) reached."
    Mark task for human review. Proceed to next task.
  - If this attempt made things worse or same: restore from snapshot
    rm -rf .artifacts/correction-snapshots/attempt-${ATTEMPT_NUM}

─────────────────────────────────────────
STEP 4 — ENFORCEMENT CHECK
─────────────────────────────────────────

After completing the correction loop:
  bash scripts/diagnostic-enforcement.sh --verify "$(bash scripts/find-first-feature.sh)"
Read the result:
  ENFORCEMENT=ENFORCED — no violations, proceed.
  ENFORCEMENT=VIOLATION_FOUND — revert unauthorized changes and re-run correction loop.
  ENFORCEMENT=NOT_APPLICABLE — no diagnostic was run.

─────────────────────────────────────────
STEP 5 — ESCALATION (if 3 attempts exhausted)
─────────────────────────────────────────

If tests still fail after 3 attempts:
  1. Generate FAILURE_REPORT.md with:
       - created_at, task_id, phase, status: BLOCKED
       - failing_tests (name, file, error, T/I/E/R category)
       - correction_attempts (hypothesis, fix, files, result)
       - root_cause_hypothesis, recommended_human_action
  2. Update tasks.md: Status: ABANDONED, note "ESCALATION: 3 correction attempts exhausted"
  3. Print: "ESCALATION: 3 correction attempts exhausted. See FAILURE_REPORT.md"
  4. Halt. Do NOT proceed to next step.
