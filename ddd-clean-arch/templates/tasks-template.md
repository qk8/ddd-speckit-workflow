# Implementation Backlog

One task = one speckit.implement session (max 5 files, max 1 aggregate).

# HOW TDD WORKS ACROSS TASK TYPES
# Every task starts by writing a failing test, then implements until it passes.
# The test type written in each task is different:
#
#   backend-domain   → write failing UNIT tests first, then implement domain classes
#   backend-infra    → write failing INTEGRATION tests first, then implement repository
#   backend-api      → write failing API tests first (REST Assured / Playwright API),
#                      then implement controller + use case
#   shared           → write failing contract tests first, then generate types
#   frontend-data    → write failing UNIT tests first, then implement data layer
#   frontend-feature → write failing E2E tests first (Playwright), then implement UI
#   e2e              → write failing E2E tests first for CROSS-FEATURE journeys,
#                      then fix any gaps revealed across already-built features
#
# The "e2e" task type is NOT redundant with frontend-feature TDD.
# frontend-feature tasks test one feature in isolation (e.g. "place an order").
# e2e tasks test journeys that span multiple features (e.g. "register, then place
# an order, then view order history"). These only make sense after all the individual
# features they depend on are complete — hence their position at the end.

Task order:
1. backend-domain  (aggregate root, value objects, events, repo interface — one task per aggregate)
2. backend-infra   (repo implementation, DB migration, external adapters — one task per aggregate)
3. backend-api     (controller, use case, wired together — one task per endpoint group)
4. shared          (contract types, generated code — after API contract is stable)
5. frontend-data   (data layer module — one task per bounded context)
6. frontend-feature(feature components with Playwright E2E TDD — one task per major feature)
7. e2e             (cross-feature journey tests — after all dependent features are DONE)

─────────────────────────────────────────────────────────────────────────

## TASK-[N]: [title]
Status: TODO
# Valid statuses:
#   TODO         — not started
#   IN_PROGRESS  — currently being worked on (set at task plan confirmation)
#   DONE         — all 9 checks passed, test file committed
#   ABANDONED    — interrupted; partial files listed below for recovery
#
# Fields added by /speckit.implement when task is completed:
# Built: [one sentence describing what was built]
# Test file: [path to the test file committed for this task]
# Spec changes applied: [list of plan.md changes confirmed during implementation | none]
# (For ABANDONED: Abandoned at: [step], Partial files: [list])
Type: backend-domain | backend-infra | backend-api | shared | frontend-data | frontend-feature | e2e
Depends on: TASK-[X], TASK-[Y] | none
Scope:
  Creates:
    - [exact file path]
  Modifies:
    - [exact file path] | none
Acceptance criteria:
  - [Verifiable. Names exact class/method/behavior from plan.md.
     Form: "calling [ExactClass].[method]([input]) raises/returns [exact output]"
     or "the following test passes: [test description with exact class names]"]
Do NOT:
  - [One scope-creep guard specific to this task.]

─────────────────────────────────────────────────────────────────────────
[Repeat for every task.]
