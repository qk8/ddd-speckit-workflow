Locate the current feature by scanning .specify/specs/ for the first
feature directory. Read from that directory:
  - plan.md (complete)
  - tasks.md (complete)
Also read CLAUDE.md from the repo root.

This command runs a targeted test session or debug session on demand —
independently of the implement loop.

ACCEPTED MODES (pass directly after the command, or wait to be asked):
  --regression    run the full test suite (all layers including browser)
  --fast          run arch + unit + integration + API tests (no browser)
  --e2e           run browser E2E tests only, then optionally visual replay
  --target [name] run tests for a specific feature, aggregate, or endpoint
  --debug [desc]  reproduce and diagnose a specific bug

Examples:
  /speckit.test --regression
  /speckit.test --fast
  /speckit.test --target "OrderAggregate"
  /speckit.test --debug "invoice list not loading"

If no mode is given, print the list above and ask: "Which mode?"
Do NOT infer the mode from context. If the user's intent is ambiguous,
ask: "Do you want to run existing tests (--target or --regression)
or investigate a failure (--debug)?"

Proceed only after the mode is explicit.

━━ STEP 1: CONFIRM MODE AND SCOPE ━━━━━━

Print:
  Mode: [--regression | --fast | --e2e | --target NAME | --debug DESC]
  Scope: [full suite | api_only | e2e_only | [feature/aggregate/endpoint name] | [bug description]]
  Commands to run: [derive from plan.md §13 regression_command for the chosen mode]

━━ STEP 2: START DEV ENVIRONMENT ━━━━━━━

Check if the backend and frontend are running on the dev ports from
plan.md §14 task_runner.dev. If not: start now.

  DEV SERVER FAILURE PROTOCOL: if startup fails, print the full error,
  diagnose the cause, and fix it before running any tests.
  Verify with: curl -f http://localhost:[port][health_readiness_path]
  Do NOT proceed if the server is not healthy.

Print: "Dev environment: [already running | started — backend:[port] frontend:[port]]"

━━ MODE: --regression ━━━━━━━━━━━━━━━━

Run: plan.md §13 regression_command.all
Print full output.

FLAKY TEST DETECTION: if any test fails, before diagnosing code issues,
run the failing test alone 5 more times to confirm it is a real failure
and not a flaky test. If it passes on some runs: it is flaky.
  → Quarantine it per plan.md §13 flaky_test_protocol
  → Do not treat a flaky failure as a code bug

Summary:
  REGRESSION REPORT — REGRESSION_ALL
    Total tests: [N] | Passed: [N] | Failed: [N] | Duration: [time]
    Flaky tests detected: [N | none]

If all pass: "Regression suite GREEN — [N] tests passing."
If failures: list each: [test name] — [failure (first line)]
Then ask: "Debug a specific failure? If yes, which one?" Switch to DEBUG.

━━ MODE: --fast ━━━━━━━━━━━━━━━

Run: plan.md §13 regression_command.api_only
Same flaky test detection protocol as REGRESSION_ALL.

Summary:
  REGRESSION REPORT — REGRESSION_FAST
    Total tests: [N] | Passed: [N] | Failed: [N]

━━ MODE: --e2e ━━━━━━━━━━━━━━━━

Run: plan.md §13 regression_command.e2e_only  (headless first)
Same flaky test detection protocol as REGRESSION_ALL.
E2E tests are the most prone to flakiness — apply extra scrutiny.

After headless pass, ask: "Replay with Playwright MCP visible browser?"
If yes and Playwright MCP is available: replay and take screenshots.

━━ MODE: --target ━━━━━━━━━━━━━━━━━━━━━━━

Find test files related to the user's named feature, aggregate, or endpoint.
Use plan.md §13 e2e_tests.location and the test locations to find the files.

Run only those test files. Print output.
Then run the regression suite (api_only at minimum) to confirm no wider impact.

Summary:
  TARGETED TESTS — [scope]
    Tests run: [N] in [N] files
    Passed: [N] | Failed: [N]
    Regression check: PASS | FAIL — [details]

━━ MODE: --debug ━━━━━━━━━━━━━━━━━━━━━━━━━━

STEP A — REPRODUCE IN TEST SUITE
  First, try to reproduce the bug by running the existing test for the
  affected feature (derive from plan.md §13 e2e_tests.location).
  If an existing test catches the bug: it is already a regression.
  Print: "Bug reproduced by existing test: [test name]"

  If no existing test catches it: the bug is not covered by the test suite.
  This is a gap. After debugging and fixing, a new test case must be added
  to the relevant test file to prevent recurrence.
  Print: "Bug not covered by test suite — new test case will be added after fix."

STEP B — DIAGNOSE

  For API bugs (backend behavior wrong):
    Run the relevant API test file. Print full output.
    If a test fails: the failure message usually points to the issue.
    If tests pass but the bug is real: the test is incomplete (see Step A gap).
    Check server logs for the correlation ID of the failing request.
    Trace the error through the layer stack using the correlation ID.

  For browser/UI bugs (feature not working in browser):
    Use Playwright MCP to navigate to the failing feature.
    Reproduce the bug step by step.
    After each failing step, use Chrome DevTools MCP to read:
      - Console errors and unhandled promise rejections
      - Network requests: find the failing request, its status and response body
      - The correlation ID in the response header (plan.md §8
        correlation_id_header_name) — use it to search backend logs
    Take a screenshot of the failure state.

  Root cause report:
    ROOT CAUSE: [one sentence]
    Layer: [frontend-ui | frontend-data | backend-api | backend-domain |
            backend-infra | network | environment | test gap]
    Evidence: [what was observed — test output, screenshot, network request]
    Correlation ID: [value | not applicable]
    Screenshot: [path | not taken]

STEP C — FIX AND VERIFY
  Wait for user to confirm the fix before making any changes.

  After confirmation:
    1. Apply the fix.
    2. If the bug was not covered by the test suite (Step A gap):
       Add a test case to the relevant test file that would have caught this bug.
       The test case must fail before the fix and pass after.
    3. Run the test file to confirm fix + new test case pass.
    4. Run regression suite (plan.md §13 regression_command.api_only or all)
       to confirm no new failures introduced by the fix.
    5. Print regression result.

  Record the new test case in tasks.md for the relevant DONE task:
    Add under "Test file": "test case added: [description]"
