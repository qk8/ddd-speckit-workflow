Write a UNIT TEST for the data layer module.
Framework: plan.md §13 unit_tests.framework
Cover:
  - Happy path: successful API response → correct typed return value
  - Each of the four error types from §7: correct discriminated union tag
  - Correlation ID: included in infrastructure_error and unexpected_error objects
  - Network failure (simulated): returns typed infrastructure_error, never throws
  - All functions return Result<T,E> — none of them throw under any condition
