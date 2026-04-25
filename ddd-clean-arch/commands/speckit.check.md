# speckit.check

Run all quality checks for the current task.

This command:
1. Reads the current task from tasks.md
2. Determines applicable checks via the routing table
3. Reads plan.md for the sections each check needs
4. Runs each applicable check in order
5. Prints results: "CHECK [X] NAME: PASS | FAIL — details"

─────────────────────────────────────────
ROUTING TABLE
─────────────────────────────────────────
  backend-domain    → [A] [B] [C] [D] [M] [P]
  backend-infra     → [A] [B] [C] [D] [E] [F] [M] [O] [Q]
  backend-api       → [A] [B] [C] [D] [E] [G] [I] [J] [K] [L] [M] [N] [O] [Q]
  shared            → [A] [B] [C] [D] [E] [K] [L] [M] [N] [O]
  frontend-data     → [B] [C] [D] [G] [L] [O] [P]
  frontend-feature  → [B] [C] [D] [G] [H] [L] [O] [P]
  e2e               → [B] [C] [D] [H] [P]
─────────────────────────────────────────
All types           → [C] [D] [I]
─────────────────────────────────────────

Run only the checks in the applicable set. Do not run checks outside the set.

─────────────────────────────────────────
CHECKS
─────────────────────────────────────────

[A] ARCHITECTURAL TESTS
  Run arch test command from plan.md §20.
  Required: PASS. If fail: fix the layer violation. Do not skip.

[B] NEW TESTS PASS
  Run only the test file created in Step 1.
  Required: all pass.
  If any fail: fix the implementation. Do not weaken the tests to make them pass.

  FLAKY TEST WATCH: if a test passes on the first run but you suspect it
  might be timing-dependent or state-dependent, run it 5 times consecutively:
    [test runner command] --repeat=5  (or equivalent for the framework)
  If it fails on any of those runs, it is already flaky.
  Fix the root cause (explicit wait conditions, better test isolation)
  before marking the task DONE. Do not mask flakiness with retries.

[C] REGRESSION SUITE — zero new failures allowed
  Run the full test suite (all tests, not just the new ones):
    For backend-domain tasks:   plan.md §13 regression_command.api_only
    For backend-infra tasks:    plan.md §13 regression_command.api_only
    For backend-api tasks:      plan.md §13 regression_command.api_only
    For shared tasks:           plan.md §13 regression_command.api_only
    For integration tasks:      plan.md §13 regression_command.api_only
    For frontend-data tasks:    plan.md §13 regression_command.api_only
    For frontend-feature tasks: plan.md §13 regression_command.all
    For e2e tasks:              plan.md §13 regression_command.all
  Required: ZERO new test failures.
  If a previously passing test now fails:
    This task introduced a regression. Do not mark DONE.
    Identify exactly which change broke the existing test.
    Fix the regression, then re-run the full regression suite.
    Print: "REGRESSION FOUND AND FIXED — [test name]: [root cause and fix]"

  If the regression cannot be fixed (conflicting requirements, unresolvable
  architecture clash):
    1. Mark the task ABANDONED in tasks.md with a note explaining the clash.
    2. Print: "REGRESSION UNFIXABLE — ABANDONING task. See rollback note."
    3. Do NOT mark the task DONE.
    4. Do NOT weaken existing tests to make them pass.

  Print: "REGRESSION SUITE: [total N] tests, 0 new failures"

[D] LINTER
  Run lint command from plan.md §14 task_runner.lint. Required: no errors.

  If errors/warnings found:
    1. Do NOT suppress them with @ts-ignore, eslint-disable, or equivalent.
    2. Analyze the ROOT CAUSE — is it a type mismatch, a missing import, a
       logic error, or an outdated interface?
    3. Fix the underlying logic. If the linter flags a type that no longer
       exists because of a recent refactor, update the type definition, not
       the usage.
    4. If the project uses an autofix command (e.g., tsc --noEmit, biome --fix,
       eslint --fix), run it first before manual fixes.
    5. Re-run the linter. Repeat until clean.

  If the linter has no autofix: try the most common autofix flag first
  (e.g., --fix, --auto-fix, format --write), fall back to manual fixes.

[E] DEPENDENCY VULNERABILITY SCAN
  Run scanning tool from plan.md §9 dependency_security.scanning_tool.
  Required: no CRITICAL or HIGH CVEs in direct dependencies.
  If found:
    Print: SECURITY BLOCK — [CVE ID]: [package] [severity]
    Do not mark DONE. User must update the dependency or document an accepted
    risk in plan.md §9 with justification and remediation deadline.
  If tool not installed: install it now. Add to CI. Document in plan.md §9.

[F] MIGRATION TEST — backend-infra tasks only
  If Type is backend-infra and a migration file was created:
    Apply migration to test database (tool from plan.md §12 migration_strategy.tool).
    Verify every table, column type, nullability, and index from §12 TABLE definitions exists.
    Print schema diff. Required: matches §12 TABLE definitions exactly.
    If mismatch: fix migration and re-run. Do not mark DONE.

[G] ERROR HANDLING ASSERTIONS — backend-api and frontend-data tasks only
  Verify that the test file from Step 1 already asserts error handling.
  If any assertion is missing: add it to the test file now (not optional).

  If Type is backend-api, verify the API test asserts:
    1. Correlation ID header (exact name from §8) present in HTTP response
    2. Error envelope shape matches §7 exactly for each error type tested
    (Structured log assertion is not automated — note in completion report
     that log output was manually verified during implementation)

  If Type is frontend-data, verify the unit test asserts:
    1. Correlation ID attached to infrastructure_error and unexpected_error objects
    2. All four error types return the correct discriminated union tag
    3. No function throws -- all errors are returned as typed values

[H] BROWSER VERIFICATION — frontend-feature and e2e tasks only
  Run the E2E test file headlessly first:
    Command: plan.md §13 regression_command.e2e_only
    Required: all tests pass headlessly.
    This proves the feature works without a visible browser and will pass in CI.

  If Playwright MCP is available (local Claude Code):
    Replay the E2E test scenario using Playwright MCP visible browser.
    This adds human-visible confirmation that the UI looks correct.
    Take a screenshot at the final state of the happy path.
    Save to: docs/test-results/[YYYY-MM-DD]-TASK-[N]-[feature].png
    Read browser console output -- flag any errors or unhandled rejections.

    If the headless test passes but the visible browser reveals a visual bug
    not caught by the test assertions (broken layout, wrong color, overlapping
    elements): note it in the completion report. It is not a blocker unless
    it prevents the user from completing the action.

    If the headless test fails:
      DEBUG PROTOCOL:
      1. Take a screenshot of the failure state.
      2. Use Chrome DevTools MCP to read console errors and network requests.
      3. Find the correlation ID in any failed API response.
         Use it to locate the corresponding backend log entry.
      4. Trace the root cause to its source layer.
      5. Fix. Re-run headless E2E only. Then re-run check [C] regression suite.

  If Playwright MCP is not available (web sandbox):
    Headless only. Print warning: "Playwright MCP not available -- visual
    verification skipped. All headless E2E tests pass."

[I] SECRET SCANNING — all tasks
  Run gitleaks on the entire working tree:
    gitleaks detect --source . --redact -q
  Required: no secrets detected.
  If gitleaks is not installed: print a warning and remind the user to run
    bash scripts/setup-hooks.sh
  to install it. Do not block on this if the tool is missing, but note it.
  If a secret is detected:
    Print: SECRET FOUND -- [file:line] [description, redacted]
    Do NOT commit. The user must:
      1. Remove the secret from the file
      2. If already in git history: rotate the credential immediately,
         then use git-filter-repo or BFG to remove it from history
      3. Add a false-positive allowance to .gitleaks.toml if it is not
         a real secret, with a comment explaining why

[J] PERFORMANCE BUDGET — backend-api and frontend-feature tasks only
  For backend-api:
    Run a quick load test with plan.md §10 backend_p95 budget:
      ab -n 100 -c 10 [API endpoint from §8]
    Compare LCP against backend budget from §10.
    If p95 exceeds budget: print WARNING — "p95=[N]ms exceeds budget [budget]ms"
    Note in completion report for retrospect review.

  For frontend-feature:
    Run the E2E test headlessly, measure LCP via Playwright MCP:
      Evaluate: () => document.querySelector('body')?.getBoundingClientRect()
    Compare LCP against frontend budget from §10.
    If LCP exceeds budget: print WARNING — "LCP=[N]ms exceeds budget [budget]ms"
    Note in completion report for retrospect review.

[K] API CONTRACT ENFORCEMENT — backend-api and shared tasks only
  Run: bash scripts/validate-api-contract.sh
  Required: PASS. If DRIFT DETECTED:
    Print: "CONTRACT DRIFT: [details]"
    Fix the endpoint to match the contract. Do not weaken the contract
    to match incorrect implementation.
    If the contract is genuinely wrong: record in Spec learnings.
    Do NOT mark DONE until contract matches or learnings are recorded.

[M] FAILURE MODE COVERAGE
  Read plan.md §15 EDGE CASES & FAILURE MODES. For each FAILURE entry:

  1. Search the codebase for handlers/validators related to this failure.
     Look in:
     - Domain classes (invariants that prevent this failure)
     - API layer (input validation that catches this failure)
     - Frontend (input guards that prevent this failure)
     - Error handling (§7 error taxonomy)

  2. If the failure is addressed in tests: print "COVERED: [name] — test file"
  3. If the failure is addressed in code but not tested: print "PARTIALLY: [name] — code exists, add test"
  4. If the failure is NOT addressed: print "MISSING: [name] — implement now"

  For each MISSING failure: implement the handling now. Do not proceed
  until all failures are either COVERED or PARTIALLY covered.

  Print: "§15 FAILURE MODES: [N] covered, [N] partially, [N] missed"

[L] ANTI-HALLUCINATION CHECK
  Before committing, verify every external library import and API call:

  1. For every import from a third-party library:
     - Confirm the package exists in the project's dependencies
     - Confirm the imported symbol (function/class/constant) actually
       exists in that package at the version specified in package.json
       (or equivalent)
     - If unsure: stop, write the exact import statement, and verify
       against the official documentation URL

  2. For every method call on a third-party library:
     - Confirm the method signature matches the package's documented
       API (parameter types, return type)
     - Do NOT assume a method exists because a similar one does

  3. For every HTTP API call:
     - Confirm the endpoint path matches the api-contract.yaml
     - Confirm the request/response shapes match the contract schema

  4. For every database query:
     - Confirm table/column names match §12 TABLE definitions
     - Confirm parameterized queries are used (no string concatenation)

  If ANY verification fails: fix the code. Do NOT use @ts-ignore,
  eslint-disable, or equivalent to suppress errors.

  After verification, print: "ANTI-HALLUCINATION: all imports verified"
  or list the specific imports that failed verification.

[N] CROSS-CUTTING CONCERN AUDIT — backend-api and shared tasks only
  If this task creates or modifies any endpoint, audit ALL endpoints
  in the codebase for consistency:

  1. Auth: Is every endpoint covered by auth middleware — or explicitly
     opted out with a comment explaining why?
  2. Logging: Is every endpoint covered by request logging?
  3. Error handling: Is every error propagated to a single error handler,
     or are there silent catch blocks?
  4. Response format: Is there a consistent error response shape across
     all endpoints per §7 error taxonomy?
  5. Transactions: Are DB transactions used consistently for endpoints
     that perform more than one write?

  For each gap: state the file, the gap, and the fix.
  Fix all gaps. Do not proceed until consistent.

[O] SECURITY HARDENING — backend-api, frontend-data, frontend-feature tasks
  If this task touches any user-facing code, verify every security
  requirement from plan.md §9 is implemented:

  1. Input validation: Is every user-supplied input validated at the
     system boundary? (HTTP request body, query params, headers,
     cookies, file uploads)
  2. Output escaping: Is all user data escaped before rendering in HTML?
  3. SQL injection: Are all database queries parameterized?
     (No string concatenation in SQL)
  4. CSRF: Are state-changing endpoints protected against CSRF?
  5. Rate limiting: Are auth endpoints (login, register, password reset)
     rate-limited?
  6. HTTP security headers: Are Content-Security-Policy, X-Frame-Options,
     X-Content-Type-Options set?
  7. Sensitive data: Is PII not logged? Are secrets not in source code?
     Are tokens not stored in localStorage?
  8. Error messages: Do error messages NOT reveal internal paths,
     library names, or stack traces to clients?

  For each item: PASS, FAIL, or N-A.
  If any FAIL: fix it. Do not proceed until all PASS or N-A.

[P] TEST QUALITY REVIEW — all tasks
  Review each test in the test file from Step 1:

  1. Behavior vs implementation: Does each test assert on observable
     behavior (HTTP status, response shape, database state, UI text)
     rather than internal details (mock call counts, private method
     invocation order, internal variable values)?
  2. False confidence: Would this test still pass if the implementation
     was wrong? (e.g., testing a helper function that is not the
     system under test)
  3. Mock strategy:
     - NEVER mocks the system under test
     - NEVER mocks standard library functions (unless testing
       time-dependent behavior)
     - ALWAYS mocks external HTTP calls
     - ALWAYS uses a real test database for integration tests
  4. Determinism: No Math.random(), no fixed sleep(), no time-dependent
     assertions without fake timers

  For each failing check: fix the test. Do not weaken the test to
  make it pass.

  Print: "TEST QUALITY: [N] tests, all behavior-focused"

[Q] RESILIENCE TESTING — backend-api and backend-infra tasks only
  If this task creates or modifies any endpoint or infrastructure
  component, verify the system degrades gracefully under these
  failure scenarios:

  1. Database connection drops mid-request — returns proper error,
     not a 500 crash
  2. External API returns 503 — returns proper error to client
  3. External API times out — does not hang indefinitely
  4. Request body is malformed JSON — returns 400 with clear message
  5. Request body exceeds size limit — returns 413
  6. Concurrent duplicate submissions — handled by idempotency
  7. Auth token is valid but user was deleted mid-session — returns
     401, not a 500

  For each scenario: verify the correct error response is returned
  (not a 500 crash), the error is logged with correct severity,
  and the system remains available for other requests.

  If any scenario is not tested: add the test now.
