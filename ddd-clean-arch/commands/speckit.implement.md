Read CLAUDE.md fully.

Determine the current feature: scan .specify/specs/ and find the feature
whose tasks.md contains the first TODO task.
Read its plan.md and tasks.md.

PARALLEL MODE (batch independent tasks):
  The workflow YAML passes this instruction via input.args. When you see this
  section, process tasks in batches instead of one at a time:
  1. Find ALL TODO tasks whose Depends-on tasks are all DONE.
  2. Group them by dependency level:
     Level 0: tasks with no depends-on (or only DONE dependencies)
     Level 1: tasks whose only depends-on are Level 0 tasks
     Level 2+: tasks whose depends-on are all at lower levels
  3. Process each level as a batch. Within a batch, process tasks sequentially.
  4. After all tasks in a batch complete, print: "Batch complete: [N] tasks done."
  5. Continue to the next level. Stop when no more TODO tasks with all dependencies met.
  6. In batch mode, the completion report covers the entire batch.

Use targeted spec loading — read only the plan.md sections relevant to
the next task's Type. Do not read plan.md end to end:

  backend-domain  → §2, §4 (aggregate in scope only), §6 domain rules,
                    §7 validation + error taxonomy, §13 unit_tests + regression_command, §16, §17
  backend-infra   → §4 (aggregate in scope), §6 infra rules,
                    §12 (table in scope), migration_strategy,
                    §13 integration_tests + regression_command, §16, §17
  backend-api     → §6 app + delivery rules, §7 full, §8 (endpoint in scope, §8 correlation_id_header_name),
                    §13 api_tests + regression_command, §16, §17
                    + docs/spec/api-contract.yaml for the endpoint(s) in scope
  shared          → §14 contract_sharing + change_detection, §3,
                    §13 contract_testing + regression_command, §16, §17
                    + docs/spec/api-contract.yaml full
                    + docs/spec/backend-interfaces.[ext] and frontend-interfaces.[ext]
  integration     → §3 (bounded contexts involved), §4 (aggregates on both sides),
                    §6 (module boundaries between contexts), §7,
                    §13 integration_tests + regression_command, §16, §17
  frontend-data   → §7 error taxonomy, §8 (endpoints this module calls),
                    §8 correlation_id_header_name,
                    §11 frontend_observability,
                    §14 frontend_architecture + frontend_auth_flow,
                    §13 unit_tests + regression_command, §16, §17
                    + docs/spec/frontend-interfaces.[ext] for the relevant context
  frontend-feature→ §7 user-facing error behavior,
                    §14 frontend_architecture.layers.ui +
                    frontend_architecture.layers.feature,
                    §14 state_management +
                    §14 form_validation_alignment +
                    §14 component_library,
                    §13 e2e_tests + regression_command, §16, §17
  e2e             → §13 e2e_tests + regression_command,
                    §8 all endpoints, §17

Check for IN_PROGRESS tasks first:
  Scan tasks.md for any task with Status: IN_PROGRESS.
  If found:
    Print: "IN_PROGRESS task detected: TASK-[N] — [title]"
    Print: "This task was left active from a previous session."
    Print: "Continuing with this task."
    Keep Status as IN_PROGRESS (do not change it).
    Continue to TASK PLAN below with this task.
  If no IN_PROGRESS task: Find the first task in tasks.md where Status is TODO.

Check all Depends-on tasks. If any is not DONE:
  Print: BLOCKED: TASK-[N] — incomplete dependencies: [list]
  Print: Run /speckit.status to see what is unblocked.
  Stop.

━━ TASK PLAN ━━━━━━━━━━━━━━━━━━━━━━━━━━━
Task: TASK-[N] — [title]
Type: [type]
Test file to create: [derived from §13 for this type — path and tool]
Impl files to create: [from Scope.Creates]
Files to modify: [from Scope.Modifies]
Acceptance criteria: [numbered, verbatim from task]
Do NOT: [verbatim from task]
Layer rules for this type: [from CLAUDE.md]
§16 constraints that apply: [relevant ones]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Print the plan and wait for the user to confirm before proceeding.

If the user confirms, immediately update tasks.md:
  Change Status from TODO to IN_PROGRESS for TASK-[N].
  This marks the session as active. If this session is interrupted before
  completion, check-tasks.sh will detect IN_PROGRESS and warn the next session.

If at any point the user asks to stop or the session is interrupted:
  Update tasks.md for TASK-[N]:
    Status: ABANDONED
    Abandoned at: [which step was in progress — Step 1 / Step 2 / Step 3 check [X]]
    Partial files: [list any files that were created or modified before interruption]
  Print: "Task marked ABANDONED. On next session, review partial files before restarting."
  The partial files may need manual cleanup before the task is restarted as TODO.

─────────────────────────────────────────
STEP 1 — WRITE FAILING TESTS (TDD, outside-in)
─────────────────────────────────────────
Start from the outermost test that proves the acceptance criteria.
Work inward to unit tests. Write ALL test files before any implementation.

Read plan.md §13 to determine the test type, location, and naming convention.
The test file is permanent — it will be committed alongside the implementation
and will run in regression for every future task.

  TYPE: backend-domain
    Write a UNIT TEST for the domain layer.
    Location: plan.md §13 unit_tests.location
    Framework: plan.md §13 unit_tests.framework
    Cover:
      - Each invariant from §4: attempting to violate it raises the correct error
      - Each domain event: the aggregate raises it under the correct condition
      - Each state transition: the aggregate reaches the correct state
      - Value objects: equality by value, immutable, invalid construction rejected

  TYPE: backend-infra
    Write an INTEGRATION TEST for the repository.
    Location: plan.md §13 integration_tests.location
    Framework: plan.md §13 integration_tests.framework (with Testcontainers or equivalent)
    Cover:
      - save() then findById() returns an identical aggregate
      - Any query methods implied by §8 endpoints return correct results
      - Optimistic lock conflict (if concurrency.strategy is optimistic_version):
        concurrent save raises the correct conflict error
      - Soft delete (if soft_delete: yes in §12): deleted records are excluded from queries

  TYPE: backend-api
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

  TYPE: shared
    Write a UNIT TEST validating the generated type contract.
    Cover: generated types match the api-contract.yaml schema;
    breaking changes in the schema fail the test.

  TYPE: integration
    Write an INTEGRATION TEST for cross-context boundaries.
    Location: plan.md §13 integration_tests.location
    Framework: plan.md §13 integration_tests.framework (with Testcontainers or equivalent)
    Cover:
      - The bounded context boundary defined in §3 for the involved contexts
      - Event/command flow between contexts matches §4 domain events
      - Shared kernel types (§14 contract_sharing) are compatible on both sides
      - Failure in one context does not crash the other (resilience pattern from §11)

  TYPE: frontend-data
    Write a UNIT TEST for the data layer module.
    Framework: plan.md §13 unit_tests.framework
    Cover:
      - Happy path: successful API response → correct typed return value
      - Each of the four error types from §7: correct discriminated union tag
      - Correlation ID: included in infrastructure_error and unexpected_error objects
      - Network failure (simulated): returns typed infrastructure_error, never throws
      - All functions return Result<T,E> — none of them throw under any condition

  TYPE: frontend-feature
    Write an E2E TEST using Playwright.
    Location: plan.md §13 e2e_tests.location
    Naming: plan.md §13 e2e_tests.naming_convention
    For the feature implemented in this task, write test cases for:
      - Happy path of every acceptance criterion:
        navigate to the route → interact → verify expected content/state
      - One error state: trigger a validation error or failed request;
        verify the correct user-facing error message appears (from §7)
      - If the error message should show a correlation ID (from §11): assert it is visible
    Use Playwright's accessibility tree for element selection, not CSS selectors.
    Tests must run headlessly in CI without Playwright MCP.

  TYPE: e2e
    Write an E2E TEST covering the full cross-feature journey.
    Location: plan.md §13 e2e_tests.location
    Cover the complete user journey from start to final state.
    Include an error trigger midway through to verify correlation ID is visible.
    The test must be completely independent: it sets up its own test data.

START THE DEV ENVIRONMENT if not running (plan.md §14 task_runner.dev).
Wait until ready. API tests and E2E tests need it to fail meaningfully.

  DEV SERVER FAILURE PROTOCOL:
  If the dev server fails to start:
    1. Print the full startup error output.
    2. Do NOT proceed to run tests — they will produce misleading results.
    3. Do NOT mark any check as PASS.
    4. Diagnose: is it a port conflict, missing environment variable,
       database not running, or compilation error?
    5. Fix the startup issue first.
    6. Only proceed once the dev server responds to a health check:
       curl -f http://localhost:[backend_port]/[§11 health_checks.readiness.path]
       (e.g. /health/ready, /health, /actuator/health — from plan.md §11)
    Print: "Dev server started and healthy — proceeding."

TEST DATA ISOLATION — enforce before writing test code:
  Read plan.md §13 test_data_strategy.
  Every test you write must follow these rules:
    - Unit and integration tests: use factory functions from
      plan.md §13 test_data_strategy.factory_location
      Never construct domain objects by hand in test code.
    - API tests: each test creates its own data via the API or test helpers
      and cleans up in teardown. Never depend on data from another test.
    - E2E tests: use the approach from plan.md §13 e2e_data_setup.strategy.
      Each test creates its own user / entity and is independent.
      Tests must pass when run in any order and in parallel.
  If the factory location does not exist yet: create it as part of this task.

RUN THE TESTS. Expected: FAIL (implementation does not exist yet).
Print full output.
  - Unit tests: fail with "class not found" or assertion errors — correct.
  - API tests: fail with connection refused or 404 — both are correct.
  - E2E tests: fail with "element not found" or navigation error — correct.

If any test passes at this stage: STOP.
A test that passes before implementation exists is testing nothing.
Rewrite it to fail, then continue.

Confirm: "Test file: [path] — [N] test cases, all failing. Proceeding."

─────────────────────────────────────────
STEP 2 — IMPLEMENT
─────────────────────────────────────────
Write the implementation until the tests from Step 1 pass.

Rules (non-negotiable):
- Exact names from plan.md — any deviation is a bug, not a style choice.
- Never violate a layer rule or §16 constraint. Redesign instead.
- Never ask permission to violate a rule.
- Only touch: Scope.Creates, Scope.Modifies, and the test file from Step 1.
- Never implement any part of another task speculatively.
- Spec conflict found → stop and report. Never resolve unilaterally.

If tests fail after implementation:
  1. Run /speckit.correction to triage (T/I/E/R) and attempt fixes.
  2. Maximum 3 correction attempts. If all fail: FAILURE_REPORT.md generated.
  3. Do NOT weaken tests to make them pass.

─────────────────────────────────────────
STEP 3 — RUN QUALITY CHECKS
─────────────────────────────────────────
Run /speckit.check to execute all applicable quality checks for this task.
The check command reads the task type from tasks.md, determines which checks
apply via the routing table, and runs them in order.

After /speckit.check completes, review the results.
A task cannot be marked DONE until every applicable check passes.

Routing reference (full routing table is in /speckit.check):
  backend-domain    → [A] [B] [C] [D] [M] [P]
  backend-infra     → [A] [B] [C] [D] [E] [F] [M] [O] [Q]
  backend-api       → [A] [B] [C] [D] [E] [G] [I] [J] [K] [L] [M] [N] [O] [Q]
  shared            → [A] [B] [C] [D] [E] [K] [L] [M] [N] [O]
  frontend-data     → [B] [C] [D] [G] [L] [O] [P]
  frontend-feature  → [B] [C] [D] [G] [H] [L] [O] [P]
  e2e               → [B] [C] [D] [H] [P]
─────────────────────────────────────────
All types           → [B] [C] [D] [I] [M] [P]
─────────────────────────────────────────

─────────────────────────────────────────
STEP 4 — COMPLETION REPORT
─────────────────────────────────────────

Print:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COMPLETION REPORT — TASK-[N]

Test file: [path] ([N] test cases committed)

Acceptance criteria:
  [1] [criterion] → SATISFIED — [test name that proves it]
  ...

Do NOT constraint: [restate] → RESPECTED — [how]

Checks:
  [A] Arch tests:      PASS
  [B] New tests:       PASS ([N] cases, stability-checked) | FLAKY — [fix applied]
  [C] Regression:      PASS ([total N] tests, 0 new failures)
  [D] Linter:          PASS
  [E] Dep scan:        PASS | BLOCKED — [details]
  [F] Migration:       PASS | N/A
  [G] Error handling:  PASS | N/A
  [H] Browser verify:  PASS (screenshot: [path]) | headless only | N/A
  [I] Secret scan:     PASS | WARNING — gitleaks not installed | BLOCKED — [details]
  [J] Perf budget:     PASS | WARNING — [details] | N/A
  [K] Contract:        PASS | DRIFT — [details] | N/A
  [L] Anti-hallucination: PASS | FAILED — [details]
  [M] Failure modes:   PASS | PARTIAL — [N] missed | MISSING — [details]
  [N] Cross-cutting:   PASS | GAP — [details] | N/A
  [O] Security:        PASS | FAIL — [details] | N/A
  [P] Test quality:    PASS | [N] issues — [details] | N/A
  [Q] Resilience:      PASS | [N] scenarios tested | [N] added

Test data isolation: [confirmed — factory/fixture used | N/A for unit tests]

ROLLBACK FILES: [list of files restored/removed | none]
ROLLBACK NOTE: [rollback note from tasks.md | none]

━━ SPEC LEARNINGS ━━━━━━━━━━━━━━━━━━━━━━
  A) Spec decision wrong/impractical?    [yes — description | none]
  B) Gap requiring a decision?           [yes — description | none]
  C) CLAUDE.md rule ambiguous?           [yes — description | none]
  D) Assumption invalidated by library?  [yes — description | none]

For each finding: propose a change to plan.md [section.field → new value].
Do NOT apply until user confirms. List all and wait for confirmation.
After confirmation: update plan.md and record in tasks.md.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Update tasks.md for TASK-[N]:
  Status: DONE
  Built: [one sentence]
  Test file: [path]
  Spec changes applied: [list | none]
  Perf warning: [Check [J] warning text | none]
    (Record any performance budget warnings here so retrospect can read them.)
  Rollback note: [regression note | none]
    (If this task was rolled back and retried, record the reason.)

# Recovery note for the next session if this task was previously ABANDONED:
# If the task was previously ABANDONED and this is a restart, verify that
# partial files from the previous attempt are consistent with what was just built.
# Remove any stale partial artifacts before marking DONE.

Count total DONE tasks. The workflow (check-tasks.sh) handles adaptive retrospective
cadence based on project complexity. Print a completion notice:
  "[N] tasks completed."
