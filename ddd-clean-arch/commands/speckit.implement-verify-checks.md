# ── IMPLEMENT VERIFY — QUALITY CHECKS ──────────────────────────
# Referenced by: speckit.implement-verify.md (orchestrator)
# Contains: snapshot restore, diagnostic enforcement, quality checks, smoke test

# ── FILE SNAPSHOT / ROLLBACK ──────────────────────────────────
# Before verification, check if a pre-task snapshot exists.
# If verification fails, restore files from snapshot rather than
# leaving partial changes on disk.

─────────────────────────────────────────
STEP 2.5 — RESTORE FROM SNAPSHOT ON FAILURE
─────────────────────────────────────────
If any quality check (STEP 3) or smoke test (STEP 4) fails:

  1. Check for pre-task snapshot:
     FEATURE_DIR="[feature_dir from tasks.md]"
     TASK_ID="[current task ID]"
     if [ -f "$FEATURE_DIR/.artifacts/snapshots/${TASK_ID}.snapshot.json" ]; then
       bash scripts/check-point.sh rollback "$FEATURE_DIR" "$TASK_ID"
     fi

  2. If rollback succeeds: print "FILES RESTORED from pre-task snapshot."
     and mark task IN_PROGRESS (not DONE).
  3. If no snapshot exists: print "NO SNAPSHOT AVAILABLE — partial files remain."
     and mark task IN_PROGRESS with note: "partial_files_remain".

─────────────────────────────────────────
STEP 2.6 — DIAGNOSTIC ENFORCEMENT CHECK
─────────────────────────────────────────
Before running quality checks, verify no diagnostic enforcement violations:

If .artifacts/diagnostic-enforcement.action exists:
  Run: bash scripts/diagnostic-enforcement.sh --verify --auto-revert "$(bash scripts/find-first-feature.sh)"
  Read the result:
    ENFORCEMENT=ENFORCED — proceed to quality checks.
    ENFORCEMENT=VIOLATION_FOUND — STOP. Revert ALL unauthorized changes:
      1. For each VIOLATION-N line, identify the violated file.
      2. Run: git checkout HEAD -- <file>
      3. The --auto-revert flag should have done this, but verify manually.
      4. Do NOT proceed until violations are resolved.
    ENFORCEMENT=NOT_APPLICABLE — proceed to quality checks.

  Additionally, check REQUIRED_ACTION directly:
    If REQUIRED_ACTION=FIX_TEST:
      You should NOT be modifying implementation files at this stage.
      The previous step indicated the test is wrong, not the implementation.
      Revert any implementation changes and fix the test instead.
    If REQUIRED_ACTION=HUMAN:
      Stop. Print: "DIAGNOSTIC ENFORCEMENT: HUMAN review required."
      Do NOT proceed with quality checks.

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

This executes all deterministic checks (A, AS, BC, D, E, F, I, K, L, O, OW, R, US, V, W, Z) in parallel.
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
STEP 3C — REPORT DETERMINISTIC CHECK FAILURES
─────────────────────────────────────────
If check-runner.sh reported failures:
  DO NOT modify implementation files during verification.
  1. Read .artifacts/check-results/[X].result for each failed check.
  2. For each failure: create a fix task in tasks.md (Type: fix, linked to current TASK-N).
  3. Re-run check-runner.sh from the beginning.
  4. If the SAME check still fails after re-run: mark the current task IN_PROGRESS
     with note "check_failure — fix task created" and do NOT mark DONE.
  5. If not fixable after 2 re-runs: mark ABANDONED.

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
  GLOBAL CAP: Max 10 total correction attempts across ALL checks for a task.
  Track via: bash scripts/state-engine.sh get "$FEATURE_DIR" corrections.global_total
  If global cap reached: stop and escalate to human review.

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
