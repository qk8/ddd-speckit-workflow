# speckit.code-review

Phase 7 — Code Review Checklist Gate.

Run after all tasks are complete (before final verify). Perform a structured,
item-by-item self-review of all code written in this session. For every item
below, explicitly mark it PASS or FAIL, and for every FAIL, apply the fix
before proceeding. Do not group-check. Each item is a distinct assertion.

─────────────────────────────────────────
SECURITY
─────────────────────────────────────────
  [ ] No secrets in code or logs. No API keys, tokens, passwords, connection
      strings, or private keys appear in any file committed or printed to any log.
  [ ] All user inputs are validated and sanitized. Every value sourced from user
      input, URL parameters, headers, or external services is validated before use.
  [ ] Authentication is correctly applied. Every endpoint and UI flow that requires
      authentication rejects unauthenticated requests with the correct response.
  [ ] Authorization is correctly applied. Every operation that is restricted to
      specific roles or owners verifies the caller's permission before executing.
  [ ] No injection vulnerabilities. SQL queries use parameterized statements or ORMs.
      HTML output is escaped or uses safe rendering APIs. Shell commands do not
      interpolate user input.
  [ ] No CSRF vulnerabilities in state-changing operations exposed via browser.
  [ ] Dependencies are not pinned to known vulnerable versions.

─────────────────────────────────────────
CORRECTNESS
─────────────────────────────────────────
  [ ] All acceptance criteria from tasks.md are fully implemented. Read each
      criterion. Confirm it is satisfied by the code.
  [ ] All edge cases identified during planning are handled. Read plan.md §15
      for edge cases. Confirm each is handled.
  [ ] Error handling covers all failure paths. Every function that can fail has
      explicit error handling. No operation assumes success.
  [ ] No silent failures. No caught exceptions are swallowed without logging.
      No error return values are ignored.
  [ ] Asynchronous operations are handled correctly. Every async operation is
      awaited. Errors from async operations are caught.

─────────────────────────────────────────
PERFORMANCE
─────────────────────────────────────────
  [ ] No N+1 query patterns. Database queries inside loops are identified and
      replaced with batch or join operations.
  [ ] No unnecessary blocking operations in async contexts. CPU-intensive
      operations in async code are offloaded or chunked.
  [ ] No memory leaks. Event listeners are removed when components unmount.
      Resources are closed after use. Caches have eviction policies.

─────────────────────────────────────────
MAINTAINABILITY
─────────────────────────────────────────
  [ ] Naming is consistent with project conventions. No ad-hoc naming that
      diverges from the established patterns.
  [ ] Functions and methods have single, clear responsibilities. A function
      that does three things is three functions.
  [ ] Complex logic has explanatory comments. The why, not the what, is
      documented inline.
  [ ] No dead code or unreachable branches. Remove any code that cannot be
      reached or that is commented out.
  [ ] No code duplication that belongs in a shared utility.

─────────────────────────────────────────
ACCESSIBILITY (for all UI changes)
─────────────────────────────────────────
  [ ] All interactive elements are keyboard navigable in the correct focus order.
  [ ] All images and icons have appropriate alt text or are marked aria-hidden
      if decorative.
  [ ] Color is not the only means of conveying information. Error states,
      statuses, and highlights use icons, text, or patterns in addition to color.
  [ ] Form inputs have associated labels. No placeholder-only labeling.
  [ ] Dynamic content changes are announced to screen readers via appropriate
      ARIA attributes where applicable.

─────────────────────────────────────────
RULES
─────────────────────────────────────────
  - Every item must be marked PASS, FAIL, or N/A (accessibility only).
  - For every FAIL: fix the issue immediately. Do not proceed until all items
    are PASS or N/A.
  - Produce REVIEW_REPORT.md documenting the outcome of every item.
  - Do NOT group-check. Each item is a distinct assertion.
