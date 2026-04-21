Locate the current feature by scanning .specify/specs/ for the first
feature directory. Read from that directory:
  - plan.md (complete)
  - tasks.md (complete)
Also read CLAUDE.md from the repo root.

Run every 10 DONE tasks. Does not implement or fix anything.
Reports alignment and waits for decisions.

━━ SECTION 1: PROGRESS ━━━━━━━━━━━━━━━━━

DONE: [N] | TODO: [N] | Total: [N] | Progress: [N]%

List all spec changes from DONE tasks ("Spec changes applied" lines).
Cross-check: are all in plan.md?
  UNSYNCED: TASK-[N] recorded "[change]" but plan.md §[section] still old value.

━━ SECTION 2: PERFORMANCE BUDGET ━━━━━━

plan.md §10: end_to_end=[N]ms, backend_p95=[N]ms, frontend=[N]ms

Check [J] results from all DONE tasks:
  backend-api tasks with perf warnings: list each endpoint, measured p95, budget.
  frontend-feature tasks with perf warnings: list each page, measured LCP, budget.

If any Check [J] warning exists:
  WARNING: [N] task(s) exceeded performance budget.
  List: TASK-[N] — [endpoint/page] measured=[N]ms budget=[N]ms

Budget plausible: yes | uncertain | likely violated
Basis: [measured data from Check [J] | no data yet]
Recommendation: [none | run a load test | revisit budget]

━━ SECTION 3: EDGE CASE COVERAGE ━━━━━━

For each FAILURE in plan.md §15:
  FAILURE: [name] | Addressed: yes | no | partially
  Evidence: [file:line | not yet implemented] | Risk: [consequence]

Covered: [N] / [total]
Uncovered high-risk: [name — consequence]

━━ SECTION 4: SELF-CRITIQUE REALITY CHECK

For each WEAK_POINT in plan.md §18:
  Status: not_manifested | early_signs | actively_problematic
  Evidence: [found | none] | Action: none | monitor | address now

  20x load: DONE tasks that would need rework? List.
  Second team: module boundaries that make handoff difficult? Be specific.
  Key dep lost: any external dependency NOT behind a port?
    VIOLATION: [dependency] not behind a port — replacement expensive.

━━ SECTION 5: TEST SUITE HEALTH ━━━━━━━━

Run arch tests from §20. PASS = layer rules are mechanically enforced.
Also run: plan.md §13 regression_command.all
Print: total tests, passed, failed, duration.
If any test fails that was passing before: latent regression.
  State which test fails and which recent task likely introduced it.

FLAKY TEST AUDIT: scan tasks/backlog.md DONE entries and
.specify/memory/conventions.md decision log for any mention of
"flaky", "quarantine", "retry", or "sleep".
  For each quarantined test: is it still in quarantine? Is the ticket still open?
  If a test has been in quarantine longer than plan.md §13 flaky_test_protocol.max_time_in_quarantine:
    OVERDUE: [test name] — quarantined since TASK-[N], deadline exceeded
    Action required: fix or delete with documented justification.

SECRET SCANNING AUDIT:
  Run: gitleaks detect --source . --redact -q
  Required: no secrets detected.
  If found: SECURITY: secret found in [file] — rotate the credential immediately.
  Also verify: are all .env files in .gitignore?
               does .env.example exist with placeholder values only?

Near-violations in DONE task Spec Learnings related to constraints? List any.

━━ SECTION 6: RECOMMENDATIONS ━━━━━━━━

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
