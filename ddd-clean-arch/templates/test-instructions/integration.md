Write an INTEGRATION TEST for cross-context boundaries.
Location: plan.md §13 integration_tests.location
Framework: plan.md §13 integration_tests.framework (with Testcontainers or equivalent)
(Same location/framework as TYPE: backend-infra)
Cover:
  - The bounded context boundary defined in §3 for the involved contexts
  - Event/command flow between contexts matches §4 domain events
  - Shared kernel types (§14 contract_sharing) are compatible on both sides
  - Failure in one context does not crash the other (resilience pattern from §11)
