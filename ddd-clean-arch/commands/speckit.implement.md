# ── speckit.implement — Focused Implementation ───────────────────
# Delegates to focused commands for task selection, impact analysis,
# and correction loop. Keeps this command lean for LLM context.

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

Rules (non-negotiable):
- Exact names from plan.md — any deviation is a bug, not a style choice.
- Never violate a layer rule or §16 constraint. Redesign instead.
- Never ask permission to violate a rule.
- Only touch: Scope.Creates, Scope.Modifies, and the test file from the previous step.
- Never implement any part of another task speculatively.
- Spec conflict found → stop and report. Never resolve unilaterally.
- After implementation, scope-guard.sh --enforce will verify changes match task scope.
  Exit code 2 (MAJOR_VIOLATION): abort the current task immediately. Do NOT commit.
  Exit code 1 (MINOR_VIOLATION): document why the change was necessary, then continue.
  Exit code 0 (WITHIN_SCOPE): proceed normally.
- If context-health.sh reports DEGRADED: re-read plan.md §1-3 (architecture) and spec.md.
  Summarize key decisions from your context window before proceeding.

─────────────────────────────────────────
STEP 0 — TASK SELECTION & PARTIAL FILE CHECK
─────────────────────────────────────────

Run: command: speckit.select-task
integration: claude
input:
  args: >
    Select the current task per guides/task-selection.md.
    Check for partial files from interrupted runs.
    Report selected task and any partial file warnings.

─────────────────────────────────────────
STEP 0.5 — ERROR MEMORY & RETRY BUDGET
─────────────────────────────────────────

Read known patterns:
  bash scripts/error-memory.sh read "$(bash scripts/find-first-feature.sh)"
This prints any known correction patterns, abandoned task reasons,
and drift patterns from recent tasks. Apply these learnings.

Check retry budget:
  bash scripts/retries-remaining.sh "$(bash scripts/find-first-feature.sh)" "[task_id]"
If any dimension shows 0 remaining: flag the risk before proceeding.

─────────────────────────────────────────
STEP 1 — CROSS-TASK IMPACT ANALYSIS
─────────────────────────────────────────

Run: command: speckit.impact
integration: claude
input:
  args: >
    Analyze cross-task file dependencies for the current task.
    Report HIGH risk files and interface change warnings.

─────────────────────────────────────────
STEP 2 — IMPLEMENT
─────────────────────────────────────────

Write the implementation until the tests from the previous step pass.

After writing implementation, RUN THE TESTS and verify they pass:
  Use scripts/validate-tests.sh to capture and validate the result:
    bash scripts/validate-tests.sh "[test_runner_command_from_plan_md_§13]" "pass"
  Read the output variables: TEST_RESULT, TEST_PASSED, TEST_FAILED, TEST_OUTPUT_FILE.

If TEST_RESULT is "pass":
  RUN THE FULL REGRESSION SUITE:
    bash scripts/validate-tests.sh "[regression_command.all from plan.md §13]" "pass"
  If TEST_RESULT is "fail":
    Enter correction loop (see STEP 3).

If TEST_RESULT is "fail":
  Enter correction loop (see STEP 3).

─────────────────────────────────────────
STEP 3 — CORRECTION LOOP (if tests fail)
─────────────────────────────────────────

Run: command: speckit.correction-loop
integration: claude
input:
  args: >
    Execute the correction loop for test failures.
    TEST_OUTPUT_FILE: $TEST_OUTPUT_FILE
    task_type: [task_type]
    FEATURE_DIR: $(bash scripts/find-first-feature.sh)
    Follow diagnostic classifier output. Respect global cap of 10.

─────────────────────────────────────────
STEP 4 — VERIFY & RECORD
─────────────────────────────────────────

Run: command: speckit.implement-verify
integration: claude
input:
  args: >
    Continue from the just-completed implementation.
    Run quality checks (STEP 3) and produce the completion report (STEP 4).
    Do NOT re-implement — only verify and report.

# Track which files this task created/modified for future impact analysis.
FEATURE_DIR="$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")"
TASK_ID="[task_id from unified-context]"
if [ -n "$FEATURE_DIR" ]; then
  bash scripts/track-created-files.sh "$FEATURE_DIR" "$TASK_ID" [list_of_created_modified_files] 2>/dev/null || true
fi
