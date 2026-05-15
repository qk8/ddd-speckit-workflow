Read .artifacts/unified-context.json. This file contains all context for the current task:
  - Task details (id, title, status, type, depends_on, scope, acceptance_criteria, do_not)
  - Relevant plan.md sections (FULL text, no truncation)
  - §16 constraints
  - Layer rules (only relevant layers for this task type)
  - Test instructions
  - Error memory corrections
  - Checkpoint state

If unified-context.json does not exist, generate it:
  Run: bash scripts/unified-context.sh "$(bash scripts/find-first-feature.sh)" [task_id] [task_type]

━━ TASK PLAN (condensed) ━━━━━━━━━━━━━━━━━━━━
Task: [task.id] — [task.title]
Type: [task.type]
Test file (written by previous step): [discover from feature directory — look for newly created test files]
Impl files to create: [from task.scope.creates]
Files to modify: [from task.scope.modifies]
Acceptance criteria: [from task.acceptance_criteria, numbered]
Do NOT: [from task.do_not]
Layer rules for this type: [from layer_rules]
§16 constraints that apply: [from constraints.rules]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

─────────────────────────────────────────
STEP 0 — TASK SELECTION (per guides/task-selection.md)
─────────────────────────────────────────
Before selecting which task to implement, follow the task selection protocol:

1. Scan tasks.md for any task with Status: IN_PROGRESS.
   If found: continue with that task.
2. If no IN_PROGRESS task: find the first TODO task where all Depends-on tasks are DONE.
3. Skip tasks whose Depends-on includes any non-DONE task (these are BLOCKED).
4. Among eligible TODO tasks, prefer: backend-domain > backend-infra > backend-api >
   shared > integration > frontend-data > frontend-feature > e2e.

Print: "Selected TASK-[N] — [title] (Type: [type])"

━━ KNOWN PATTERNS (from error memory) ━━━━━━━━━━━━━━━━━━━━━━━━━
Run: bash scripts/error-memory.sh read "$(bash scripts/find-first-feature.sh)"
This prints any known correction patterns, abandoned task reasons,
and drift patterns from recent tasks. Apply these learnings to
avoid repeating past mistakes on this task.
If no patterns are printed: no prior learnings — proceed normally.

Rules (non-negotiable):
- Exact names from plan.md — any deviation is a bug, not a style choice.
- Never violate a layer rule or §16 constraint. Redesign instead.
- Never ask permission to violate a rule.
- Only touch: Scope.Creates, Scope.Modifies, and the test file from the previous step.
- Never implement any part of another task speculatively.
- Spec conflict found → stop and report. Never resolve unilaterally.

─────────────────────────────────────────
STEP 1.5 — CROSS-TASK IMPACT CHECK
─────────────────────────────────────────
Before implementing, check if files being modified overlap with past or future tasks:

Run: bash scripts/impact-analysis.sh "$(bash scripts/find-first-feature.sh)" [task_id] [task_type] --show-tests
Read the impact report. If any HIGH risk files are reported:
  1. Print: "HIGH RISK: <file> — <N> overlapping tasks"
  2. Review the overlap: which past task created/modified the file, which future task will touch it
  3. If interface-breaking: note which future tasks may need updates
  4. Print: "INTERFACE CHANGE WARNING: <file> — future tasks <list> may need updates"

─────────────────────────────────────────
STEP 2 — IMPLEMENT
─────────────────────────────────────────
Write the implementation until the tests from the previous step pass.

After writing implementation, RUN THE TESTS and verify they pass:
  Use scripts/validate-tests.sh to capture and validate the result:
    bash scripts/validate-tests.sh "[test_runner_command_from_plan_md_§13]" "pass"
  Read the output variables: TEST_RESULT, TEST_PASSED, TEST_FAILED, TEST_OUTPUT_FILE.

If TEST_RESULT is "fail":
  - TEST_FAILED test(s) failed (exit code $TEST_EXIT_CODE)
  - Do NOT proceed. Enter the INLINE CORRECTION LOOP.
  - The full raw output is in: $TEST_OUTPUT_FILE

Then RUN THE FULL REGRESSION SUITE:
  bash scripts/validate-tests.sh "[regression_command.all from plan.md §13]" "pass"
  Read the output. If TEST_RESULT is "fail":
    - Zero new failures allowed
    - STOP. Run diagnostic classifier on regression output:
      bash scripts/diagnostic-classifier.sh \
        "$(bash scripts/find-first-feature.sh)" \
        "[task_type]" \
        "$(cat $TEST_OUTPUT_FILE)" \
        "$(cat ${TEST_OUTPUT_FILE%.txt}_impl.out 2>/dev/null || echo '')"
    - Do NOT self-diagnose regression failures — use the classifier output.
    - Fix, re-run

INLINE CORRECTION LOOP (if tests fail)
  MAX_CORRECTION_ITERATIONS = 3 per test failure check.
  GLOBAL_CORRECTION_CAP = 10 total correction attempts across all checks for a task.
  Track global count in state.json: bash scripts/state-engine.sh get "$FEATURE_DIR" corrections.global_total

  BEFORE classifying the failure, run the independent diagnostic:
    bash scripts/diagnostic-classifier.sh \
      "$(bash scripts/find-first-feature.sh)" \
      "[task_type]" \
      "$(cat $TEST_OUTPUT_FILE)" \
      "$(cat ${TEST_OUTPUT_FILE%.txt}_impl.out 2>/dev/null || echo '')"
  Read the diagnostic output: CLASSIFICATION, EVIDENCE, CONFIDENCE, REQUIRED_ACTION, MIXED_FAULTS.
  Pass this evidence to the LLM classification — do NOT self-classify without it.
  Read guides/correction-loop.md (triage → integrity audit → 3 attempts → escalation).

  3c. ROLLBACK SNAPSHOT PER ATTEMPT:
    Before each correction attempt:
      1. Record current state of all modified files:
         git diff --name-only | while read f; do
           mkdir -p ".artifacts/correction-snapshots/attempt-${CORRECTION_NUM}"
           cp "$f" ".artifacts/correction-snapshots/attempt-${CORRECTION_NUM}/" 2>/dev/null || true
         done
      2. After the fix, if tests still fail:
         - If this attempt improved results (fewer failures): keep changes
         - If this attempt made things worse or same: restore from snapshot
             rm -rf .artifacts/correction-snapshots/attempt-${CORRECTION_NUM}

  3d. GLOBAL CAP CHECK:
    After each correction attempt, increment global counter.
    If global_total >= 10: STOP. Print: "ESCALATION: Global correction cap (10) reached."
    Mark task for human review. Proceed to next task.

  ENFORCED ACTION FROM DIAGNOSTIC (NON-NEGOTIABLE):
  If REQUIRED_ACTION=FIX_TEST:
    You MUST NOT modify implementation files. Violation creates a compliance record
    that will be flagged in the periodic retro check. Fix ONLY the test file.
    Rewrite the failing test assertion, then re-run validate-tests.sh.
    If tests still fail with REQUIRED_ACTION=FIX_TEST on re-diagnosis: escalate to human review.

  If REQUIRED_ACTION=HUMAN:
    STOP. Do not attempt further corrections.
    Print: "ESCALATION: Diagnostic confidence too low for automated resolution."
    Print: "Evidence: $EVIDENCE"
    If MIXED_FAULTS=true: Print: "Mixed faults detected (TEST_FAULT + IMPL_ERROR) — human review required."
    Mark task for human review in tasks.md (add note: requires human review).
    Proceed to next task.

  If REQUIRED_ACTION=FIX_IMPL:
    Proceed with implementation fixes only. Do NOT modify test files.
    The diagnostic has identified this as a genuine implementation error.

  If REQUIRED_ACTION=FIX_ENV:
    Fix the environment configuration ONLY (install missing dependencies,
    fix test runner config, update environment variables).
    Do NOT modify application code or test files.
    After fix, re-run validate-tests.sh to verify.

  If REQUIRED_ACTION=RETRY:
    You may attempt either test or implementation fixes, but use the
    EVIDENCE field to guide your choice. Do not self-classify without evidence.

When STEP 2 completes successfully, print:
"IMPLEMENT-CODE DONE — proceeding to quality checks."

# ── RECORD FILE TRACKING ──────────────────────────────────────
# Track which files this task created/modified for future impact analysis.
# Discover files by looking at git status or the files you just created/modified.
FEATURE_DIR="$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")"
TASK_ID="[task_id from unified-context]"
if [ -n "$FEATURE_DIR" ]; then
  bash scripts/track-created-files.sh "$FEATURE_DIR" "$TASK_ID" [list_of_created_modified_files] 2>/dev/null || true
fi
