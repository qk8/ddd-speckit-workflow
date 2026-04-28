# Implementation Backlog

One task = one speckit.implement session (max 5 files, max 1 aggregate).

# HOW TDD WORKS
# TDD is used throughout — see plan.md §13 for the full explanation.

Task order:
1. backend-domain  (aggregate root, value objects, events, repo interface — one task per aggregate)
2. backend-infra   (repo implementation, DB migration, external adapters — one task per aggregate)
3. backend-api     (controller, use case, wired together — one task per endpoint group)
4. shared          (contract types, generated code — after API contract is stable)
5. integration     (cross-context boundary tests — one task per bounded context relationship)
6. frontend-data   (data layer module — one task per bounded context)
7. frontend-feature (feature components with Playwright E2E TDD — one task per major feature)
8. e2e             (cross-feature journey tests — after all dependent features are DONE)

─────────────────────────────────────────────────────────────────────────

## TASK-[N]: [title]
Status: TODO
# Valid statuses:
#   TODO         — not started
#   IN_PROGRESS  — currently being worked on (set at task plan confirmation)
#   DONE         — all applicable checks passed, test file committed
#   ABANDONED    — interrupted; partial files listed below for recovery
#   BLOCKED      — dependency is not DONE (auto-set; unblock when dep becomes DONE)
#
# Fields added by /speckit.implement when task is completed:
# Built: [one sentence describing what was built]
# Test file: [path to the test file committed for this task]
# Spec changes applied: [list of plan.md changes confirmed during implementation | none]
# (For ABANDONED: Abandoned at: [step], Partial files: [list])
Type: backend-domain | backend-infra | backend-api | shared | integration | frontend-data | frontend-feature | e2e
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
