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
    4. Run regression suite:
       - For backend/domain/API fixes: plan.md §13 regression_command.api_only
       - For frontend/E2E fixes: plan.md §13 regression_command.all
       to confirm no new failures introduced by the fix.
    5. Print regression result.

  Record the new test case in tasks.md for the relevant DONE task:
    Add under "Test file": "test case added: [description]"
