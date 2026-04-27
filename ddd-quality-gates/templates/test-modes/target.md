Find test files related to the user's named feature, aggregate, or endpoint.
Derive test locations from plan.md §13 based on the target type:
  aggregate → unit_tests.location (domain invariant tests)
  endpoint  → api_tests.location (API contract tests)
  feature   → e2e_tests.location (end-to-end tests)
  module    → unit_tests.location + integration_tests.location

Run only those test files. Print output.
Then run the regression suite (api_only at minimum) to confirm no wider impact.

Summary:
  TARGETED TESTS — [scope]
    Tests run: [N] in [N] files
    Passed: [N] | Failed: [N]
    Regression check: PASS | FAIL — [details]
