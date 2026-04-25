---
feature_name: ""
phase: ""
branch: ""
ticket_ref: ""
created_at: ""
---

===========================================================================
FEATURE IMPLEMENTATION BRIEF
===========================================================================

---------------------------------------------------------------------------
SCOPE
---------------------------------------------------------------------------

What this feature DOES:
  [3–5 sentences. What does the user experience? What does the system do?]

What this feature explicitly DOES NOT do (out of scope):
  - [Item 1]
  - [Item 2]
  - [Item 3]

External dependencies introduced:
  - [Package/API/Service]: [why needed, audit status]

---------------------------------------------------------------------------
ACCEPTANCE CRITERIA
---------------------------------------------------------------------------

AC-01: [Criterion]
  → Test file: [path]
  → Test type: [Unit / Integration / E2E]

AC-02: [Criterion]
  → Test file: [path]
  → Test type: [Unit / Integration / E2E]

[Add as many ACs as needed. Every AC must become a test.]

---------------------------------------------------------------------------
EDGE CASES
---------------------------------------------------------------------------

EC-01: [Edge case — e.g., "Concurrent requests with same input"]
EC-02: [Edge case — e.g., "Input at exact boundary values"]
EC-03: [Edge case — e.g., "External service returns 503"]
EC-04: [Edge case — e.g., "Null/undefined for every required parameter"]
EC-05: [Edge case — e.g., "Token expired mid-session"]

[Minimum 5 edge cases. Each becomes a test.]

---------------------------------------------------------------------------
DEPENDENCY MAPPING
---------------------------------------------------------------------------

Modules this feature MODIFIES:
  - [file path]: [what changes]

Modules this feature READS FROM:
  - [file path]: [data contract unchanged]

Database tables/collections READ OR WRITES:
  - [table]: [operations: INSERT/UPDATE/DELETE/SELECT]

What could this feature BREAK in existing tests?
  - [Affected test suites and why]

---------------------------------------------------------------------------
SIGN-OFF CHECKLIST
---------------------------------------------------------------------------

  [ ] All AC tests written BEFORE implementation
  [ ] All AC tests passing GREEN
  [ ] All EC (edge case) tests written and passing GREEN
  [ ] Full regression suite passes (all pre-existing tests GREEN)
  [ ] Coverage thresholds met for all affected layers (plan.md §13)
  [ ] 0 type errors (plan.md §13 type_check_command)
  [ ] 0 lint errors (plan.md §13 lint_command)
  [ ] Clean build (plan.md §13 build_command)
  [ ] No new any types introduced
  [ ] No raw new Error("string") — all errors are typed instances
  [ ] No secrets, tokens, or PII in source code or logs
  [ ] OpenAPI spec updated if new routes added
  [ ] Commit with Conventional Commits format
