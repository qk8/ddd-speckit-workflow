# ── speckit.spec-fix — Spec Fix Task Creation ───────────────────
# Converts spec delta findings into ordered fix tasks with
# fix-code vs fix-spec categorization.
#
# Process:
#   1. Run speckit.spec-delta to get the delta report
#   2. For each issue in the delta report:
#      a. Fix-code path: spec correct, code wrong → add fix task to tasks.md
#      b. Fix-spec path: spec wrong, code correct → add spec_revision task
#   3. Use spec-authorized-changes.sh log to record each approved fix-spec change
#   4. Reset cascade counters atomically via spec-revision-counter.sh reset --cascade
#   5. Print summary of added tasks and affected tasks

─────────────────────────────────────────
STEP 1 — READ DELTA REPORT
─────────────────────────────────────────
Read: .artifacts/spec-delta.md (produced by speckit.spec-delta)
Parse:
  - Changes Detected section → list of changed files + status
  - Cascade Impact section → affected tasks + severity
  - Recommendation → fix-code / fix-spec / no-action

─────────────────────────────────────────
STEP 2 — CREATE FIX TASKS
─────────────────────────────────────────

If recommendation is fix-code:
  For each UNAUTHORIZED change where spec is correct:
    Add to tasks.md:
      ## FIX-TASK-[N]
      Title: [Specific fix action to align code with spec]
      Type: [type matching existing tasks that produced the code]
      Depends on: [tasks that produced the code being fixed]
      Scope:
        Modifies: [exact file path]
      Acceptance criteria:
        - [Verifiable: "calling X.Y() returns Z"]
      Do NOT: [scope-creep guard — list what not to change]

If recommendation is fix-spec:
  For each UNAUTHORIZED change where code is correct:
    a. Add to tasks.md:
      ## FIX-TASK-[N]
      Title: [Specific spec correction]
      Type: spec_revision
      Depends on: [tasks that produced the current spec version]
      Scope:
        Modifies:
          - plan.md (list sections)
          - spec.md (list sections)
          - tasks.md (reset affected tasks to TODO)
      Acceptance criteria:
        - [Verifiable spec correction criteria]
      Do NOT: [scope-creep guard]
    b. Reset affected DONE tasks to TODO in tasks.md
    c. Log authorized change:
       bash scripts/spec-authorized-changes.sh <feature_dir> log plan.md "spec fix: <reason>" "$FIX_TASK_ID"
       bash scripts/spec-authorized-changes.sh <feature_dir> log spec.md "spec fix: <reason>" "$FIX_TASK_ID"
    d. Reset cascade counters:
       bash scripts/spec-revision-counter.sh <feature_dir> reset --cascade

─────────────────────────────────────────
STEP 3 — PRINT SUMMARY
─────────────────────────────────────────
Output:
  FIX-TASKS_ADDED=N
  AFFECTED_TASKS_RESET=[TASK-1,TASK-2,...]
  AUTHORIZED_CHANGES_LOGGED=[plan.md,spec.md,...]
