Run a post-batch consistency check.

BATCH CONTEXT:
  This check runs after a parallel batch of tasks completed.
  Read the batch task list from .artifacts/batch_tasks.txt if available.
  If not available, derive from tasks.md: all DONE tasks whose status
  changed in this session.

STEP 1 — CONSTRAINT DRIFT (lightweight)
  Read plan.md §16 directly. Check only the 3 most common violation patterns:
  1. Layer rule violations: domain layer imports infrastructure?
     grep for imports from application/, infrastructure/, delivery/ in domain files.
  2. Correlation ID: API responses include correlation_id header/field?
     Check backend-api response handlers for correlation_id propagation.
  3. Test data isolation: test files use factory/fixture functions?
     Check test files for hand-constructed domain objects.

STEP 2 — API SURFACE CONSISTENCY
  Read all files modified by batched tasks. Check:
  1. No method signature changed from what plan.md §8 specifies.
     Check: parameter names, return types match the API contract.
  2. Domain event names are consistent (same event name used everywhere).
     Check: all references to each domain event use identical naming.
  3. Repository interface methods match their implementations.
     Check: every interface method has a corresponding implementation.

STEP 3 — REPORT
  Print:
    BATCH CONSISTENCY CHECK — Tasks: [TASK-N, TASK-M, ...]
    Constraint drift: [PASS | FAIL: list violations]
    API surface: [PASS | FAIL: list inconsistencies]
    Overall: CLEAN | ISSUES FOUND
  If ISSUES FOUND: fix the issues immediately or report them for human review.
  After fixing, remove .artifacts/batch_tasks.txt to signal completion.
