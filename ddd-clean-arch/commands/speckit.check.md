# speckit.check

Run non-deterministic quality checks for the current task.

IMPORTANT: Deterministic checks (A, BC, D, E, F, I, K, L, R, Z, AS, OW, US)
are already executed by the check-runner.sh script in the workflow.
DO NOT re-run them. Only run the non-deterministic checks listed below.

This command:
1. Reads the current task from tasks.md
2. Derives the task type (e.g., backend-domain, backend-api)
3. For each NON-DETERMINISTIC applicable check [X]:
   - Deterministic checks (A, BC, D, E, F, I, K, L, R, Z, AS, OW, US): SKIP.
     These were already run by check-runner.sh. Do NOT re-execute them.
   - Non-deterministic checks (G, H, J, M, N, O, P, Q, S, T, U):
     a. Verify the sub-check file exists at commands/checks/check_[X]_[name].mdc
     b. If missing: report "CHECK [X] SKIPPED — sub-check file not found" and continue
     c. If found but empty or malformed: report "CHECK [X] SKIPPED — file empty" and continue
     d. Read the sub-check file and execute the check instructions
     e. Record PASS/FAIL result
4. Prints results summary: "CHECK [X] NAME: PASS | FAIL — details"

Non-deterministic checks to run (based on task type routing):
  [G] Error Handling Assertions          - backend-api, frontend-data
  [H] Browser Verification               - frontend-feature, e2e
  [J] Performance Budget                 - backend-api, frontend-feature
  [N] Cross-Cutting Concern Audit        - backend-api, shared
  [O] Security Hardening                 - backend-api, backend-infra, frontend-data, frontend-feature (includes session/token security)
  [P] Test Quality Review                - all
  [Q] Resilience Testing                 - backend-api, backend-infra
  [S] Property-Based Test Coverage       - all
  [T] Adversarial Input Testing          - backend-api, shared
  [Z] Constraint Drift & Failure Mode Coverage - all

Run only the non-deterministic checks applicable to the current task type.
Do not run checks outside the applicable set.
