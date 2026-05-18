# ── speckit.spec-delta — Spec Delta Report ──────────────────────
# Produces a human-readable spec delta report with cascade impact analysis.
#
# Process:
#   1. Run spec-diff-check.sh --check to find changed spec files
#   2. If AUTHORIZED or NONE: report "No unauthorized changes detected"
#   3. If UNAUTHORIZED:
#      a. Map changed sections to affected tasks (inline impact analysis)
#      b. Read pending-learnings.md and flag stale items
#      c. Read authorized-changes log to see if changes were logged
#      d. Produce report in .artifacts/spec-delta.md
#   4. Output recommendation: fix-code / fix-spec / no action

─────────────────────────────────────────
STEP 1 — DETECT SPEC CHANGES
─────────────────────────────────────────
Run: bash scripts/spec-diff-check.sh --check <feature_dir>
Read output:
  SPEC_CHANGES=NONE|AUTHORIZED|UNAUTHORIZED
  CHANGED-FILE-1=path (if changes detected)

─────────────────────────────────────────
STEP 2 — GENERATE DELTA REPORT
─────────────────────────────────────────

If SPEC_CHANGES=NONE:
  Write .artifacts/spec-delta.md:
    # Spec Delta Report
    ## Status
    No unauthorized changes detected.

If SPEC_CHANGES=AUTHORIZED:
  Write .artifacts/spec-delta.md:
    # Spec Delta Report
    ## Status
    Spec changes detected but are authorized (logged in authorized-changes.json).
    ## Changes
    - plan.md: AUTHORIZED (logged)
    - spec.md: AUTHORIZED (logged)

If SPEC_CHANGES=UNAUTHORIZED:
  1. Identify which spec files changed
  2. For each changed file, determine if it matches current task Scope.Modifies
  3. Check .artifacts/authorized-spec-changes.json for logged changes
  4. Map changed sections to affected DONE tasks:
     - Parse tasks.md for DONE tasks
     - For each DONE task, check if its Type matches affected spec sections
     - Group by severity (CRITICAL > HIGH > MEDIUM > LOW)
  5. Check pending-learnings.md for stale PENDING items
  6. Write .artifacts/spec-delta.md:

    # Spec Delta Report
    ## Changes Detected
    - plan.md: UNAUTHORIZED (changed by <task_id>, not in approved log)
    - spec.md: AUTHORIZED (logged in authorized-changes.json)

    ## Section-Level Changes
    - plan.md §4: changed (behavior modification detected)
    - spec.md §2: added (new section)

    ## Cascade Impact
    - HIGH: TASK-12 (backend-api) affected by plan.md §4 change
    - MEDIUM: TASK-8 (backend-domain) affected by spec.md §2 change

    ## Stale Pending Learnings
    - TASK-3 — 2 revisions ago, still PENDING

    ## Recommendation
    - [fix-code / fix-spec / no action]

─────────────────────────────────────────
STEP 3 — ACTION ITEMS
─────────────────────────────────────────
Based on the delta report:

If recommendation is fix-code:
  Spec is correct, code is wrong.
  Proceed with implementation to align code with spec.

If recommendation is fix-spec:
  Code is correct, spec is wrong.
  Run speckit.spec-fix to create spec revision tasks.

If no action:
  Changes are cosmetic or authorized. Continue current work.
