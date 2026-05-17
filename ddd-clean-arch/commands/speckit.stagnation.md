# ── speckit.stagnation — Stagnation Diagnosis & Guidance ──────────
# Diagnoses implementation stagnation and provides actionable guidance.
#
# Usage: Run when check-stagnation.sh reports STAGNANT=true.
# Does NOT implement or fix anything — only reports and guides.

─────────────────────────────────────────
STEP 1 — RUN STAGNATION CHECK
─────────────────────────────────────────

Run: bash scripts/check-stagnation.sh "$(bash scripts/find-first-feature.sh)"

Read the output:
  STAGNANT=true/false
  CONSECUTIVE_NO_PROGRESS=N
  CONSECUTIVE_CONTINUES=N
  REVISION_ONLY=true/false

─────────────────────────────────────────
STEP 2 — DIAGNOSE
─────────────────────────────────────────

If STAGNANT=false:
  Print: "No stagnation detected. Implementation is progressing normally."
  Proceed with implementation.

If STAGNANT=true:
  Print: "IMPLEMENTATION STAGNATION DETECTED"
  Print: "  Consecutive no-progress iterations: $CONSECUTIVE_NO_PROGRESS"
  Print: "  Consecutive continue options taken: $CONSECUTIVE_CONTINUES"
  Print: "  Revision-only loop: $REVISION_ONLY"

  If REVISION_ONLY=true:
    Print: "WARNING: Revision loop detected — revising without completing tasks."
    Print: "Recommended: Select 'troubleshoot' or 'abort' (not 'continue')."

  If CONSECUTIVE_CONTINUES >= 2:
    Print: "WARNING: Continue option exhausted ($CONSECUTIVE_CONTINUES consecutive continues)."
    Print: "You must troubleshoot or abort."

─────────────────────────────────────────
STEP 3 — ACTIONABLE GUIDANCE
─────────────────────────────────────────

Review the stuck task in tasks.md:
  1. Read the task's acceptance criteria and scope.
  2. Check Depends-on tasks: are they all DONE?
  3. Check if any test files exist for this task.
  4. Check error memory for known failure patterns on this task type.

Print one of:
  "TASK IS BLOCKED — Depends-on tasks not met. Unblock or revise dependencies."
  "TASK HAS NO TESTS — write-test step may have failed. Run /speckit.write-test manually."
  "TASK IS FLAKY — check .specify/memory/conventions.md for quarantine status."
  "TASK SCOPE MAY BE UNREALISTIC — consider splitting into smaller sub-tasks."
  "SPEC GAP — implementation cannot satisfy acceptance criteria as written."

─────────────────────────────────────────
STEP 4 — OUTPUT REPORT
─────────────────────────────────────────

Write findings to: .artifacts/stagnation-report.md
  - Detected at: timestamp
  - Consecutive no-progress: N
  - Consecutive continues: N
  - Revision-only: true/false
  - Stuck task: TASK-[N] — [title]
  - Diagnosis: [from step 3]
  - Recommended action: [troubleshoot / abort / split task / revise spec]

Print: "Run /speckit.implement to continue after addressing stagnation."
