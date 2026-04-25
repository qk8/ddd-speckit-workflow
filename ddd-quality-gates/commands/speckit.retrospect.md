Locate the current feature by scanning .specify/specs/ for the first
feature directory. Read from that directory:
  - plan.md (complete)
  - tasks.md (complete)
Also read CLAUDE.md from the repo root.

Run on adaptive cadence (check-tasks.sh): simple=15, medium=10, complex=5 DONE tasks.
Does not implement or fix anything.
Reports alignment and waits for decisions.

━━ SECTION 1: PROGRESS ━━━━━━━━━━━━━━━━━

DONE: [N] | TODO: [N] | IN_PROGRESS: [N] | ABANDONED: [N] | Total: [N] | Progress: [N]%

Count all four task states from tasks.md:
  DONE, TODO, IN_PROGRESS, ABANDONED.
List all spec changes from DONE tasks ("Spec changes applied" lines).
Cross-check: are all in plan.md?
  UNSYNCED: TASK-[N] recorded "[change]" but plan.md §[section] still old value.

━━ SECTION 2: PERFORMANCE BUDGET ━━━━━━

plan.md §10: end_to_end=[N]ms, backend_p95=[N]ms, frontend=[N]ms

Read tasks.md DONE entries for "Perf warning:" lines:
  Extract fields from tasks.md DONE entries using a reusable parser:
    TASKS_FILE="<feature_dir>/tasks.md"
    awk -v status="DONE" -v field="Perf warning" '
      /^## TASK-/ { task_header = $0; header = 1 }
      /^Status: DONE/ { found = 1 }
      header && found && $0 ~ "^Perf warning:" {
        val = $0; sub(/^[^:]*: */, "", val)
        print task_header " | Perf warning: " val
      }
      /^###/ { header = 0 }
    ' "$TASKS_FILE"
  backend-api tasks with perf warnings: list each endpoint, measured p95, budget.
  frontend-feature tasks with perf warnings: list each page, measured LCP, budget.

If any Perf warning exists in tasks.md:
  WARNING: [N] task(s) exceeded performance budget.
  List: TASK-[N] — [endpoint/page] [warning text from tasks.md]

Budget plausible: yes | uncertain | likely violated
Basis: [measured data from tasks.md Perf warnings | no data yet]
Recommendation: [none | run a load test | revisit budget]

━━ SECTION 3: ROLLBACKS ━━━━━━━━━━━━━━

Read tasks.md DONE entries for "Rollback note:" lines:
  Same parser pattern, different field:
    awk -v status="DONE" -v field="Rollback note" '
      /^## TASK-/ { task_header = $0; header = 1 }
      /^Status: DONE/ { found = 1 }
      header && found && $0 ~ "^Rollback note:" {
        val = $0; sub(/^[^:]*: */, "", val)
        print task_header " | Rollback note: " val
      }
      /^###/ { header = 0 }
    ' "$TASKS_FILE"

If any Rollback note exists in tasks.md:
  ROLLBACK: [N] task(s) were rolled back due to unfixable regressions.
  List: TASK-[N] — [rollback text from tasks.md]

These tasks should be reviewed:
  - Was the task scope incorrect?
  - Did a spec assumption prove wrong?
  - Should the task be split into smaller sub-tasks?
Recommendation: [none | revise task scope | add spec clarification]

━━ SECTION 4: EDGE CASE COVERAGE ━━━━━━

For each FAILURE in plan.md §15:
  1. Search the codebase for handlers/validators related to this failure.
     Look in: domain classes (invariants), API layer (validation),
     frontend (input guards), error handling (§7).
  2. If found in tests: Addressed = yes
  3. If found in code but not tested: Addressed = partially
  4. If not found: Addressed = no
  FAILURE: [name] | Addressed: [yes | no | partially]
  Evidence: [file:line | not yet implemented] | Risk: [consequence]

Covered: [N] / [total]
Uncovered high-risk: [name — consequence]

━━ SECTION 5: SELF-CRITIQUE REALITY CHECK

For each WEAK_POINT in plan.md §18:
  Status: not_manifested | early_signs | actively_problematic
  Evidence: [found | none] | Action: none | monitor | address now

  20x load: DONE tasks that would need rework? List.
  Second team: module boundaries that make handoff difficult? Be specific.
  Key dep lost: any external dependency NOT behind a port?
    VIOLATION: [dependency] not behind a port — replacement expensive.

━━ SECTION 6: TEST SUITE HEALTH ━━━━━━━━

Run arch tests from §20. PASS = layer rules are mechanically enforced.
Also run: plan.md §13 regression_command.all
If contract_only is defined: also run plan.md §13 regression_command.contract_only
Print: total tests, passed, failed, duration.
If any test fails that was passing before: latent regression.
  State which test fails and which recent task likely introduced it.

FLAKY TEST AUDIT: scan .specify/specs/[feature]/tasks.md DONE entries and
.specify/memory/conventions.md decision log for any mention of
"flaky", "quarantine", "retry", or "sleep".
  For each quarantined test: is it still in quarantine? Is the ticket still open?
  If a test has been in quarantine longer than plan.md §13 flaky_test_protocol.max_time_in_quarantine:
    OVERDUE: [test name] — quarantined since TASK-[N], deadline exceeded
    Action required: fix or delete with documented justification.

SECRET SCANNING AUDIT:
  If gitleaks is installed:
    Run: gitleaks detect --source . --redact -q
    Required: no secrets detected.
    If found: SECURITY: secret found in [file] — rotate the credential immediately.
  Else:
    Print: "WARNING: gitleaks not installed — skipping secret scan."
  Also verify: are all .env files in .gitignore?
               does .env.example exist with placeholder values only?

Near-violations in DONE task completion reports related to constraints?
  Scan "Spec changes applied" in DONE tasks for any constraint concerns.
  List any.

━━ SECTION 7: RECOMMENDATIONS ━━━━━━━━

MUST DO (before continuing):
  - [action]: [reason]

SHOULD DO (within next 5 tasks):
  - [action]: [reason]

CONSIDER (no urgency):
  - [action]: [reason]

If nothing: "Retrospective complete. Spec and implementation are aligned."

━━ WAITING FOR DECISIONS ━━━━━━━━━━━━━━

For each MUST DO: ask user. Wait for response.
For unsynced spec changes: ask "Apply to plan.md?" Apply only confirmed.
For uncovered edge cases: ask "Add a task?" Add only confirmed (standard format).

After decisions: print summary and "Run /speckit.implement to continue."
