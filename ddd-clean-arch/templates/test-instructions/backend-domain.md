 TYPE: backend-domain
    Write a UNIT TEST for the domain layer.
    Location: plan.md §13 unit_tests.location
    Framework: plan.md §13 unit_tests.framework
    Cover:
      - Each invariant from §4: attempting to violate it raises the correct error
      - Each domain event: the aggregate raises it under the correct condition
      - Each state transition: the aggregate reaches the correct state
      - Value objects: equality by value, immutable, invalid construction rejected
