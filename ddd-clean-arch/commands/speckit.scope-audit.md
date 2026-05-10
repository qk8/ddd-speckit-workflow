# ── speckit.scope-audit — Scope Audit Command ────────────────────
# Verifies every source file in the feature directory has a task owner.
# Flags unowned files as potential feature creep.
#
# Usage: Run after each task implementation and periodically during the session.

─────────────────────────────────────────
STEP 1 — RUN SCOPE AUDIT
─────────────────────────────────────────
Run: bash scripts/scope-audit.sh "$(bash scripts/find-first-feature.sh)" --strict

This scans all source files (excluding .artifacts, .git, node_modules, .specify)
and checks each against the tracking files in .artifacts/created-files/.

─────────────────────────────────────────
STEP 2 — REVIEW RESULTS
─────────────────────────────────────────
If PASS with 0 unowned:
  Print: "SCOPE AUDIT PASS — all files have task owners"
  Proceed with implementation.

If unowned files found:
  1. For each unowned file, determine:
     - Is it part of the current task's scope? If so, add it to the task.
     - Is it from a previous task that forgot to track it? If so, retroactively track it.
     - Is it stray/unrelated code? If so, remove or move it.

  2. For files that belong to the current task:
     Run: bash scripts/track-created-files.sh "$(bash scripts/find-first-feature.sh)" [task_id] [file1] [file2] ...

  3. Re-run audit to confirm all files are now tracked.

─────────────────────────────────────────
STEP 3 — PERIODIC AUDIT (every 20 tasks)
─────────────────────────────────────────
After every 20 tasks, run a full scope audit:

  bash scripts/scope-audit.sh "$(bash scripts/find-first-feature.sh)" --strict

If any unowned files found:
  - Add them to appropriate tasks
  - Update .artifacts/created-files/<task_id>.files
  - Document in .artifacts/scope-audit-log.md

Print: "PERIODIC SCOPE AUDIT COMPLETE — [N] unowned files resolved"
