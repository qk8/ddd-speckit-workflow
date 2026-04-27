Write an E2E TEST using Playwright.
Location: plan.md §13 e2e_tests.location
Naming: plan.md §13 e2e_tests.naming_convention
For the feature implemented in this task, write test cases for:
  - Happy path of every acceptance criterion:
    navigate to the route → interact → verify expected content/state
  - One error state: trigger a validation error or failed request;
    verify the correct user-facing error message appears (from §7)
  - If the error message should show a correlation ID (from §11): assert it is visible
Use Playwright's accessibility tree for element selection, not CSS selectors.
Tests must run headlessly in CI without Playwright MCP.
