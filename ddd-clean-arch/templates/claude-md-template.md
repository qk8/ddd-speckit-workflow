# [PROJECT_NAME]
# CLAUDE.md — read this at the start of every session.
# Max 150 lines. Every line derived from plan.md. No invention.

## What this is
[2 sentences from plan.md §1 requirements scope and out_of_scope.
 What the system does. What it does NOT do.]

## Stack
backend:  [language] / [framework] / [database]
frontend: [language] / [framework]
monorepo: [tool]
api_testing_tool.selected: [rest-assured | playwright-api | pytest-httpx]
e2e_testing_tool.selected: playwright

## Architecture
[One paragraph. Names every module from §6. States the dependency direction:
 domain ← application ← infrastructure ← delivery.
 Names which modules are future extraction candidates.]

## Layer rules
Domain layer:
  - No imports from any other layer
  - No framework types, ORM annotations, or HTTP types
  - No I/O — pure functions where possible
  - Invalid states must be unrepresentable via the type system

Application layer:
  - One class per use case — no exceptions
  - No business logic — orchestrates domain objects only
  - Opens and commits the transaction
  - Dispatches domain events after commit
  - Enforces authorization before calling domain

Infrastructure layer:
  - Implements ports from application layer
  - Never imported by domain or application
  - All I/O, ORM mappings, external clients live here

Delivery layer:
  - Thin adapters only: validate input → call use case → map response
  - No business logic
  - Input validation lives here, not in the application layer

## Module boundaries
[One line per module from §6:
 "[ModuleName]: owns [owns field], never [does_not_own field]"]

## Ubiquitous language — exact names in code
[Key class names, event names, value object names, field names from §2 and §4.
 Any deviation from these names is a bug, not a style choice.
 Examples:
   Aggregate roots: [ClassName1], [ClassName2]
   Repository interfaces: [InterfaceName1], [InterfaceName2]
   Domain events: [EventName1], [EventName2]
   Value objects: [VOName1], [VOName2]]

## What NOT to do
[The 10 constraints from §16 verbatim — do not paraphrase.
 1. Never ...
 2. Never ...
 3. Never ...
 4. Never ...
 5. Never ...
 6. Never ...
 7. Never ...
 8. Never ...
 9. Never ...
 10. Never ...]

## Test conventions
Unit tests:   [framework] | location: [path pattern] | target: domain + application layers
Integration:  [framework + Testcontainers] | location: [path pattern] | target: infrastructure
API tests:    [rest-assured | playwright-api | pytest-httpx] | location: [path pattern]
E2E tests:    playwright | location: [path pattern] | headless in CI, visible with MCP locally
Arch tests:   [ArchUnit | dependency-cruiser] | location: [path] | runs in CI lint stage

Regression commands:
  all:      [plan.md §13 regression_command.all]
  api_only: [plan.md §13 regression_command.api_only]
  e2e_only: [plan.md §13 regression_command.e2e_only]

Local CI:   bash scripts/ci-local.sh

## Definition of done
[Criteria from §17 verbatim. A feature is complete when:]
  - [ ] Test file committed to codebase
  - [ ] All 11 checks pass: arch | new tests | regression | lint | dep scan |
          migration | observability | browser verify | secret scan |
          perf budget | contract enforce
  - [ ] [additional criteria from §17]
