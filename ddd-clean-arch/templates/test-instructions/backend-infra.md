Write an INTEGRATION TEST for the repository.
Location: plan.md §13 integration_tests.location
Framework: plan.md §13 integration_tests.framework (with Testcontainers or equivalent)
Cover:
  - save() then findById() returns an identical aggregate
  - Any query methods implied by §8 endpoints return correct results
  - Optimistic lock conflict (if concurrency.strategy is optimistic_version):
    concurrent save raises the correct conflict error
  - Soft delete (if soft_delete: yes in §12): deleted records are excluded from queries
