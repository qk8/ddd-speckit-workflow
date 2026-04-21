# Project Constitution

## Architecture pattern
Modular monolith + Clean Architecture + Domain-Driven Design.
Dependencies point inward only: domain ← application ← infrastructure ← delivery.

## Layer rules (non-negotiable)

Domain layer:
  - Zero imports from application, infrastructure, or delivery layers
  - No framework types, no ORM annotations, no HTTP types
  - No I/O of any kind
  - Pure functions where possible (functional core)
  - Invalid states must be unrepresentable via the type system

Application layer:
  - One class per use case
  - No business logic — orchestrates domain objects only
  - Owns the transaction boundary (opens and commits)
  - Dispatches domain events after transaction commits
  - Enforces authorization before calling domain

Infrastructure layer:
  - Implements ports defined in application layer
  - Never imported by domain or application layers
  - Contains all I/O, ORM mappings, external clients

Delivery layer:
  - HTTP controllers, CLI handlers, background job runners
  - Thin adapters: validate input → call use case → map response
  - No business logic. Input validation lives here.

## Naming
[Filled in during the plan phase from §2 ubiquitous language and §4 aggregate definitions.]

## Architectural constraints
[Filled in during the plan phase from §16.
These 10 rules become the "What NOT to do" section and are enforced by architectural tests.]

## Definition of done
[Filled in during the plan phase from §17.]
