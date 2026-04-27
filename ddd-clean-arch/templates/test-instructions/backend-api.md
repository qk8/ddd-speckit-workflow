Write an API TEST using the tool from plan.md §13 api_testing_tool.selected.
Location: plan.md §13 api_tests.location
Naming: plan.md §13 api_tests.naming_convention
For each endpoint implemented in this task, write test cases for:
  - Happy path: correct request → expected status code + response shape from §8
  - Auth required: unauthenticated request → 401 with correct envelope
  - Each validation error: malformed input → 400 with field-level detail in §7 envelope
  - Each domain error: business rule violation → correct status + domain_error envelope
  - Idempotency (if §8 says idempotent: yes): duplicate request → same result, not error
  - Correlation ID: response contains the header from §8 correlation_id_header_name
  - Error envelope shape: all four error types use the §7 envelope structure exactly
ALSO write unit tests for the use case class and controller:
  - Use case: correct orchestration of domain objects without business logic
  - Controller: input validation rejects malformed requests before use case is called
