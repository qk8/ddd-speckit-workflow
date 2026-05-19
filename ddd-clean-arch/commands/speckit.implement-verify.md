# ── IMPLEMENT VERIFY — ORCHESTRATOR ────────────────────────────
# Reads: speckit.implement-verify-checks.md (quality checks)
#        speckit.implement-verify-report.md (completion report)

You are continuing implementation of a task. The code was just written
and tests pass. Now run quality checks and produce the completion report.

Read tasks.md to determine the current task (first IN_PROGRESS or first TODO).
Read plan.md §13 and CLAUDE.md for layer rules and constraints.

─────────────────────────────────────────
STEP 1 — READ TASK CONTEXT
─────────────────────────────────────────
Identify the current task from tasks.md. Note:
  - Task ID (e.g., TASK-3)
  - Task type (e.g., implement, test)
  - Module type (e.g., backend-domain, shared)
  - Feature directory (where tasks.md lives)
  - Build command from plan.md §13

─────────────────────────────────────────
STEP 2 — RUN QUALITY CHECKS
─────────────────────────────────────────
Execute STEP 2.5 through STEP 3D from speckit.implement-verify-checks.md:
  1. Restore from snapshot on failure (STEP 2.5)
  2. Diagnostic enforcement check (STEP 2.6)
  3. Deterministic checks via check-runner.sh (STEP 3A)
  4. Batched Claude checks if last task of module (STEP 3B)
  5. Fix deterministic check failures (STEP 3C)
  6. Error budget & escalation (STEP 3D)

─────────────────────────────────────────
STEP 3 — SMOKE TEST
─────────────────────────────────────────
Execute STEP 4 from speckit.implement-verify-checks.md:
  1. Validate build command prerequisites
  2. Run build command or import/load check
  3. Fix-and-revert protocol on failure (max 2 attempts)

─────────────────────────────────────────
STEP 4 — PRODUCE COMPLETION REPORT
─────────────────────────────────────────
Execute STEP 5 from speckit.implement-verify-report.md:
  1. Print completion report with test/acceptance summary
  2. Persist spec learnings to pending-learnings.md
  3. Update tasks.md (Status: DONE, Built, Test file, etc.)
  4. Write checkpoint via check-point.sh
  5. Update error memory from diagnostic output
  6. Log test health trends and complexity trends
