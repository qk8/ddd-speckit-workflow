# Plan Template — DDD + Clean Architecture

When speckit.plan runs, produce plan.md following this structure exactly.
Every section is required. Structured data only — no prose paragraphs.

The plan is produced in two passes to avoid context window overflow:
  Pass A (§1–§10): domain model, architecture, API design, security, performance
  Pass B (§11–§20): reliability, data design, testing, devex, edge cases, constraints, ADRs
                    + all companion files

Companion files produced alongside plan.md:
  docs/spec/api-contract.yaml          ← from §8
  docs/spec/data-model.sql             ← from §12
  docs/spec/backend-interfaces.[ext]   ← from §4
  docs/spec/frontend-interfaces.[ext]  ← from §8, §7, §14
  .specify/memory/conventions.md       ← from §2, §4, stack
  Architectural enforcement test files ← from §20
  CLAUDE.md updated                    ← use ddd-clean-arch/templates/claude-md-template.md
                                         fill every [PLACEHOLDER] from plan.md sections
                                         max 150 lines; §16 constraints verbatim

─────────────────────────────────
§1 REQUIREMENTS
─────────────────────────────────

functional_requirements:
  - [explicit requirement from project-brief.md]
  - [implicit requirement derived from the brief]

non_functional_requirements:
  availability_sla:
  p95_latency_target_ms:
  security_posture: [low | medium | high | critical]
  compliance: [GDPR | HIPAA | PCI-DSS | none | list]

assumptions:
  - [assumption made where the brief is silent]

out_of_scope:
  - [what this system explicitly does not do]

─────────────────────────────────
§2 UBIQUITOUS LANGUAGE
─────────────────────────────────

[Term]: [precise one-sentence definition]
# Every class name, method name, event name, and field name derives from this list.
# Flag any overloaded or ambiguous term.

─────────────────────────────────
§3 BOUNDED CONTEXTS
─────────────────────────────────

CONTEXT: [Name]
  responsibility: [one sentence]
  does_not_own: [explicit exclusions]
  internal_language_notes: [terms that differ from global ubiquitous language]
  integrates_with:
    - context: [OtherContext]
      pattern: shared_kernel | acl | open_host
      direction: [which side is upstream]
      translation_interface: [interface name, if ACL or open_host]

─────────────────────────────────
§4 AGGREGATES
─────────────────────────────────

AGGREGATE: [Name]
  context: [bounded context name]
  root_entity_class: [ExactClassName]
  identity_field: [fieldName]: [Type]

  invariants:
    - [business rule — specific and verifiable]

  value_objects:
    - [ValueObjectName]: { [field]: [Type] }

  domain_events:
    - [EventName]: { [field]: [Type] }

  repository_interface: [ExactInterfaceName]

  concurrency:
    strategy: optimistic_version | pessimistic | none
    version_field: [fieldName]        # only if optimistic_version
    pessimistic_scope: [description]  # only if pessimistic
    deadlock_mitigation: [approach]   # only if pessimistic
    conflict_user_experience: [what the caller sees on conflict]
    retry_automatically: yes | no

  background_worker_access: yes | no
  worker_exclusivity_mechanism: [db_advisory_lock | queue_exclusivity | distributed_lock | n/a]
  worker_race_condition_prevention: [specific mechanism]

  idempotent_operations:
    - use_case: [UseCaseClassName]
      mechanism: idempotency_key | dedup_table | conditional_upsert | natural_unique_constraint
      on_duplicate: silent_ignore | return_original | raise_error

─────────────────────────────────
§5 DOMAIN SERVICES
─────────────────────────────────

DOMAIN_SERVICE: [ServiceName]
  reason: [why this cannot live in any aggregate]
  inputs: [types]
  output: [type]
  side_effects: none | [list]

─────────────────────────────────
§6 ARCHITECTURE
─────────────────────────────────

pattern: modular_monolith + clean_architecture + DDD

modules:
  [ModuleName]:
    context: [bounded context]
    owns: [one sentence]
    does_not_own: [explicit exclusion]
    depends_on: [other module names | none]

dependency_graph: |
  [ASCII or adjacency list. Inward-only. Flag cycle risks.]

layer_rules:
  domain:
    - Zero imports from application, infrastructure, or delivery layers
    - No framework types, no ORM annotations, no HTTP types
    - No I/O of any kind
    - Pure functions where possible (functional core)
    - Invalid states must be unrepresentable via the type system
  application:
    - One class per use case
    - No business logic — orchestrates domain objects only
    - Owns the transaction boundary (opens and commits)
    - Dispatches domain events after transaction commits
    - Enforces authorization before calling domain
    - Depends only on domain layer and port interfaces
  infrastructure:
    - Implements ports defined in application layer
    - Never imported by domain or application layers
    - Contains all I/O, ORM mappings, external clients
  delivery:
    - HTTP controllers, CLI handlers, background job runners
    - Thin adapters: validate input → call use case → map response
    - No business logic
    - Input validation lives here (before application layer)

future_extraction_candidates:
  - module: [ModuleName]
    reason: [why it might need to become a separate service]
    extraction_cost: low | medium | high

─────────────────────────────────
§7 CROSS-CUTTING CONCERNS
─────────────────────────────────

validation:
  input_validation_layer: delivery
  domain_validation_layer: domain (aggregates and value objects)
  rule: nothing reaches the domain in an invalid state

error_taxonomy:
  domain_error:
    definition: business rule violation raised intentionally by domain layer
    http_status: [e.g. 422]
    logged: yes | no
    log_level: [level]
    exposes_internals: never
    includes_machine_code: yes
  validation_error:
    definition: malformed or missing input caught at delivery layer
    http_status: [e.g. 400]
    includes_field_level_detail: yes
    field_array_name: [e.g. "fields"]
  infrastructure_error:
    definition: external dependency failure
    http_status: [e.g. 503]
    logged: yes
    log_level: error
    exposes_internals: never
    may_be_transient: yes
  unexpected_error:
    definition: anything outside the above three categories
    http_status: [e.g. 500]
    logged: yes
    log_level: error
    caller_receives: generic message + correlation_id only

  error_envelope:
    fields:
      - type: string         # always present — one of the four type names
      - message: string      # always present
      - correlation_id: string  # always present
      - code: string         # domain_error only — machine-readable
      - fields: array        # validation_error only — field-level detail

transaction_boundary:
  owner: application_layer_use_case
  domain_events_dispatched: after_commit
  rationale:

authorization:
  enforcement_layer: application_layer
  mechanism: [RBAC | ABAC | custom]
  rationale:
  privilege_escalation_prevention:

logging:
  never_log: [PII fields, secrets, raw passwords, tokens]
  always_log_per_request: [correlation_id, user_id if authenticated, http_method, path, status_code, duration_ms]
  domain_layer_logging: forbidden
  format: structured_json
  correlation_propagation: [how correlation ID moves through layers]

─────────────────────────────────
§8 API DESIGN
─────────────────────────────────

style: REST | GraphQL
versioning_strategy: [URL path | header | none]

token_delivery: httponly_cookie | response_body
token_delivery_rationale:
token_lifetime_minutes:
refresh_strategy: [sliding | fixed | none]
revocation_strategy: [blocklist | short_expiry | none]

cors:
  allowed_origins:
  credentials: true | false
  allowed_headers:
  exposed_headers:  # include correlation ID header name
  rationale:

correlation_id_header_name: [e.g. X-Correlation-Id] # used in: CORS exposed_headers, backend logs, frontend error reports

endpoints:
  ENDPOINT: [METHOD] [/path]
    auth_required: yes | no
    use_case_class: [ExactClassName]
    idempotent: yes | no
    idempotency_mechanism:
    request_body:
      - [fieldName]: [Type] [required | optional]
    response_success:
      status:
      body:
        - [fieldName]: [Type]
    cacheable: yes | no
    cache_control:
    etag: yes | no
    errors: [domain_error | validation_error | infrastructure_error | unexpected_error]

─────────────────────────────────
§9 SECURITY
─────────────────────────────────

threat_model:
  - threat:
    mitigation:
  # minimum 5 threats

input_validation:
  injection_prevention: [parameterized queries | ORM | prepared statements]
  upload_handling:
  additional_measures:

rate_limiting:
  unauthenticated_endpoints:
  authenticated_endpoints:
  implementation:

audit_logging:
  events_logged:
    - [event type]
  log_destination:
  tamper_protection:
  retention:

secrets_management:
  approach: [environment variables | vault | cloud secret manager]
  no_hardcoded_secrets: enforced by CI lint rule + pre-commit gitleaks hook

secret_scanning:
  tool: gitleaks
  pre_commit_hook: yes  # blocks commits containing secrets locally
  ci_gate: yes          # also runs in CI before build stage
  config_file: .gitleaks.toml
  # .env files must be in .gitignore — only .env.example is committed

dependency_security:
  scanning_tool:
  frequency:
  policy_on_critical_cve:

frontend_security:
  csp:
    # Must be consistent with CORS and token delivery above.
    # If token_delivery is httponly_cookie: cookie domain consistent
    #   with frame-ancestors and script-src.
    # If API on different origin: that origin must be in connect-src.
    directives:
      default-src:
      script-src:
      style-src:
      connect-src:   # must include API origin
      frame-ancestors:
  xss_prevention:
  csrf_protection:   # required if httponly_cookie token delivery
  sensitive_data_never_in_client_storage:
    - [field or data type]

─────────────────────────────────
§10 PERFORMANCE & SCALABILITY
─────────────────────────────────

end_to_end_budget_ms:
budget_allocation:
  network: [ms]
  backend_p95: [ms]     # backend p95 derived from this
  frontend_render: [ms] # frontend budget = remainder

load_profile:
  baseline_rps:
  peak_rps:
  growth_scenario_3x_response:
  growth_scenario_10x_response:

likely_bottlenecks:
  - bottleneck:
    preemption:

caching:
  # Frontend cache invalidation must align with cache-control and ETag below.
  - layer: [in-process | distributed | CDN | browser]
    what:
    ttl:
    invalidation_trigger:

database_query_strategy:
  n_plus_1_prevention:
  pagination: [cursor | offset]
  bulk_operation_pattern:

async_processing:
  - operation:
    reason_for_decoupling:
    mechanism:

─────────────────────────────────
§11 RELIABILITY & OBSERVABILITY
─────────────────────────────────

error_philosophy: fail_fast | graceful_degradation | mixed
circuit_breakers:
  - dependency:
    threshold:
    fallback:

structured_logging:
  format: JSON
  levels_used:
  request_correlation:
  pii_fields_excluded:

metrics:
  healthy_system_definition:
    - [metric]: [threshold]
  core_dashboards:
    - [name]: [what it shows]

alerting:
  wake_up_at_3am:
    - [condition]
  wait_until_morning:
    - [condition]

health_checks:
  liveness:
    path:
    checks:  # must not check external deps
  readiness:
    path:
    checks:  # database, required external deps

graceful_shutdown:
  in_flight_requests:
  background_jobs:
  connection_draining:

frontend_observability:
  error_tracking_tool:
  metadata_attached_to_errors:
    - [field — no PII]
  performance_monitoring:
  cross_stack_correlation:
    mechanism: correlation ID from §8 read from API response header
      and attached to every frontend error report
    implementation_layer: frontend data layer

─────────────────────────────────
§12 DATA DESIGN
─────────────────────────────────

TABLE: [table_name]
  aggregate: [AggregateName]
  context: [bounded context]
  columns:
    - [column_name]: [SQL_TYPE] [NOT NULL | NULL] [DEFAULT if any]
  primary_key:
  foreign_keys:
    - [column] references [table]([col]) on_delete: [CASCADE | RESTRICT | SET_NULL]
  indexes:
    - columns:
      type: [btree | hash | unique]
      supports: [use case name]
  soft_delete: yes | no
  rationale:

migration_strategy:
  tool:
  numbering:
  production_run:
  zero_downtime_approach:
  rollback_approach:

orm_leak_prevention:
  rule: domain classes must not extend ORM base classes
  rule: domain classes must not carry ORM annotations
  mapping_approach:

─────────────────────────────────
§13 TESTING STRATEGY
─────────────────────────────────

# TDD APPROACH (outside-in)
# Every task starts by writing a failing test, then implements until it passes.
# The test type per task type:
#   backend-domain   → failing unit test first, then implement domain classes
#   backend-infra    → failing integration test first, then implement repository
#   backend-api      → failing API test first (full stack), then implement controller + use case
#   shared           → failing contract test first, then generate types
#   frontend-data    → failing unit test first, then implement data layer
#   frontend-feature → failing Playwright E2E test first (single feature), then implement UI
#   e2e              → failing Playwright E2E test first (cross-feature journey),
#                      then fix any gaps across already-built features
#
# Why e2e tasks come last is NOT a TDD violation:
#   frontend-feature tasks use TDD for individual features.
#   e2e tasks test journeys across multiple already-built features.
#   These cross-feature tests cannot be written until all dependent features exist.
#   Writing them last is the correct outside-in sequence.
#
# No task is DONE without a persistent test file committed to the codebase.
# After every task, the full regression suite runs — zero new failures allowed.

# ── TOOL SELECTION ─────────────────────────────────────────────
# Derived from backend language in project-brief.md.
# Do not change this decision after the first task is implemented.

api_testing_tool:
  # IF backend_language is Java:
  #   tool: REST Assured
  #   reason: JUnit 5 ecosystem fit, expressive DSL, Spring Boot Test integration,
  #           runs as part of the existing Maven/Gradle test task
  #   runner: same as unit tests (mvn test / gradle test)
  #   location: [backend-module]/src/test/java/api/
  #
  # IF backend_language is TypeScript / JavaScript (Node.js):
  #   tool: Playwright (request API)
  #   reason: single tool for both API and E2E, no additional dependency
  #   runner: npx playwright test --project=api
  #   location: [backend-module]/tests/api/
  #
  # IF backend_language is Python:
  #   tool: pytest + httpx
  #   reason: async-native, integrates with pytest fixtures
  #   runner: pytest tests/api/
  #   location: [backend-module]/tests/api/
  #
  # Fill in the selected tool below:
  selected:      # [rest-assured | playwright-api | pytest-httpx]
  runner:        # [mvn test | gradle test | npx playwright test --project=api | pytest tests/api/]
  location:      # [path to API test files]
  runs_against:  local_dev_server  # tests run against the running local server, not mocks

e2e_testing_tool:
  selected: playwright
  location: [frontend-module]/tests/e2e/
  browsers: [chromium]  # add firefox and webkit only if cross-browser coverage is required
  headless_in_ci: yes
  visible_in_dev: yes  # Playwright MCP shows real browser window during development

regression_command:
  # Commands that run subsets of the test suite.
  # Defined here once and referenced by speckit.implement check [C] and [H],
  # speckit.verify, speckit.retrospect, and speckit.test.
  # Derive from the monorepo tool in §14.
  all:       # runs everything: arch + unit + integration + API + contract + E2E
             # e.g. "pnpm test" | "gradle test" | "npm run test:all"
  api_only:  # faster: arch + unit + integration + API tests only, no browser
             # e.g. "pnpm test:api" | "gradle test -x e2e" | "npm run test:backend"
  e2e_only:  # browser tests only — used by check [H] and speckit.test --e2e
             # e.g. "npx playwright test --project=e2e" | "npm run test:e2e"
  contract_only:  # contract tests only — used when API contract changes
                 # e.g. "pnpm test:contract" | "gradle test --tests '*ContractTest*'"

# ── TEST PYRAMID ───────────────────────────────────────────────

unit_tests:
  target_layers: [domain, application]
  infrastructure_dependencies: none
  max_acceptable_duration_ms: 10
  framework:    # [JUnit 5 | Vitest | pytest]
  location: [path pattern, e.g. src/test/java/**/unit/]
  coverage_focus: [invariants, use case orchestration, all error paths]
  # A use case that cannot be tested without a database is an architecture violation.

integration_tests:
  target_layers: [infrastructure]
  uses_real_infrastructure: yes
  framework:    # [JUnit 5 + Testcontainers | Vitest | pytest]
  location: [path pattern]
  coverage_focus: [repository implementations, external adapters]
  # Testcontainers (or equivalent) provides a real database.
  # Never use an in-memory database for integration tests — it hides real SQL issues.

api_tests:
  # These tests call the RUNNING local server via HTTP.
  # They test the full backend stack: delivery → application → domain → infrastructure.
  # They are the primary regression suite for the backend API contract.
  scope: all endpoints in docs/spec/api-contract.yaml
  per_endpoint_coverage:
    - happy_path: yes       # correct input → expected status + response shape
    - auth_required: yes    # unauthenticated request → 401
    - validation_errors: yes # malformed input → validation_error envelope from §7
    - domain_errors: yes    # business rule violations → domain_error envelope from §7
    - idempotency: yes      # if endpoint is idempotent (from §8): duplicate request → same result
  location: [from api_testing_tool.location above]
  naming_convention:
    # e.g. [EndpointName]ApiTest.java (Java) | [endpoint-name].api.spec.ts (TS)
  run_order: after_unit_and_integration  # API tests run after unit and integration pass

e2e_tests:
  # These tests run in a real browser against the full running stack.
  # They verify critical user journeys from the user's perspective.
  # They are the primary regression suite for frontend features.
  scope:
    # List every critical user journey. These are used by check [G] and /speckit.test.
    # Form: "[Journey name]: As a [user], I [action sequence] and verify [outcome]"
    - [journey name]: [description]
  per_journey_coverage:
    - happy_path: yes
    - error_state: yes      # trigger one error per journey, verify user-facing error message
    - correlation_id_visible: yes  # error messages surface the correlation ID for support
  location: [from e2e_testing_tool.location above]
  naming_convention:
    # e.g. [feature-name].e2e.spec.ts
  run_order: last  # E2E runs after all other tests pass

# ── TEST FILE OWNERSHIP ─────────────────────────────────────────
# Every backlog task owns one or more test files. These are created during
# the task and committed to the codebase. They never disappear.
# task_type → test_file_type:
#   backend-domain   → unit test (domain layer, no infrastructure)
#   backend-infra    → integration test (repository, real DB via Testcontainers)
#   backend-api      → API test (REST Assured or Playwright API, full stack)
#   shared           → unit test (type contracts, generated code validation)
#   frontend-data    → unit test (data layer functions, typed error returns)
#   frontend-feature → E2E test (Playwright, browser, full journey)
#   e2e              → E2E test (Playwright, critical cross-feature journey)

# ── TEST DATA ISOLATION ─────────────────────────────────────────
# Every test must set up its own data and clean up after itself.
# Tests must never depend on data created by other tests.
# Tests must be runnable in any order and in parallel.

test_data_strategy:
  approach: [test_containers_per_test | shared_db_with_cleanup | factory_functions]
  # test_containers_per_test: cleanest isolation, slowest startup — use for integration tests
  # shared_db_with_cleanup:  single test DB, each test cleans up in @AfterEach/@afterEach
  # factory_functions:       helper functions that create valid domain objects for tests
  #
  # Recommended: test_containers_per_test for integration tests
  #              shared_db_with_cleanup for API tests (faster)
  #              factory_functions for unit tests (no DB)

  factory_location: [path — e.g. src/test/java/fixtures/ or tests/fixtures/]
  # Factory functions / builder classes create valid aggregates for test use.
  # They use the exact class names and invariants from plan.md §4.
  # No test should construct domain objects by hand — use the factory.

  e2e_data_setup:
    strategy: [api_seeding | db_seeding | before_each_hook]
    # api_seeding: E2E tests call the API to create their own test data before running
    #              (most realistic, tests the full stack including auth)
    # db_seeding:  direct DB insert via a test helper endpoint or migration-style script
    #              (faster, but bypasses application logic)
    # before_each_hook: Playwright beforeEach creates data, afterEach cleans up
    cleanup: [after_each | after_all | none_if_isolated_db]
    isolation_guarantee: [each_test_independent | run_in_isolation_only]
    # each_test_independent = tests can run in any order and in parallel
    # run_in_isolation_only = tests must run sequentially (document why this is acceptable)

  forbidden:
    - Tests must never share state through static variables or module-level singletons
    - Tests must never read data written by a different test
    - Tests must never depend on test execution order
    - E2E tests must never reuse user accounts created by other tests

# ── FLAKY TEST PROTOCOL ──────────────────────────────────────────
# A flaky test is one that fails intermittently without a code change.
# Flaky tests erode trust in the test suite. Left unaddressed, teams
# start ignoring failures — at which point the suite provides no safety net.

flaky_test_protocol:
  definition: a test that fails at least once without any code change in 20 runs
  detection: [CI failure rate tracking | manual observation | flaky test detector tool]

  on_detection:
    immediate_action: quarantine  # move to quarantine suite, do NOT delete
    quarantine_location: [path — e.g. tests/quarantine/ or src/test/java/quarantine/]
    quarantine_suite_runs: [nightly | manual — NOT on every PR]
    ticket_required: yes  # every quarantined test needs a tracking issue
    max_time_in_quarantine: [e.g. 2 weeks — after this, fix or delete with justification]

  fix_approach:
    step_1: reproduce the flakiness locally (run the test 20 times in a loop)
    step_2: identify root cause category:
      - timing: test doesn't wait for async operation to complete
              → fix: explicit wait conditions, not fixed sleep()
      - shared_state: test depends on data from another test
              → fix: test data isolation (see test_data_strategy above)
      - race_condition: concurrent operations produce non-deterministic result
              → fix: deterministic test setup or mock the concurrency
      - environment: test depends on network, clock, or OS-specific behavior
              → fix: mock the external dependency or use test-stable values
    step_3: fix the root cause (not the symptom — do not add retry logic)
    step_4: run fixed test 50 times to confirm stability before removing from quarantine

  forbidden:
    - Never add retry logic to a test to hide flakiness
    - Never skip a flaky test without a quarantine ticket
    - Never keep a test in quarantine longer than max_time_in_quarantine without action
    - Never use fixed sleep() / Thread.sleep() — use explicit wait conditions

# ── HIGHEST RISK PATHS ─────────────────────────────────────────
highest_risk_paths:
  - [class or module]: [why it is high risk and how it is covered]

# ── COMPONENT AND VISUAL TESTS ─────────────────────────────────
frontend_component_tests:
  tool:   # [Testing Library | Storybook + Chromatic]
  required_states: [loading, error all four types, empty, populated]
  location: [path pattern, e.g. src/**/*.test.tsx]

visual_regression:
  applies: yes | no
  rationale: [if no, justify — if yes, which components and tool]

contract_testing:
  # Verifies that the frontend's API client matches the backend's api-contract.yaml.
  # This is a CI gate: incompatible changes block the merge.
  mechanism: [generated type diffing | consumer-driven contract tests | schema linting]
  ci_gate: yes
  pipeline_stage: [where in CI]
  failure_action: [blocks merge]

# ── CI TEST EXECUTION ORDER ─────────────────────────────────────
ci_execution_order:
  # Fast feedback first, expensive tests last.
  # Each stage only runs if the previous stage passes.
  1: secret scan (gitleaks)  # seconds — blocks merge if credentials found
  2: lint + arch tests        # seconds — blocks if layer rules violated
  3: unit tests               # seconds
  4: integration tests        # ~1-2 minutes (Testcontainers startup)
  5: api tests                # ~1-5 minutes (real server required)
  6: contract tests           # ~seconds
  7: e2e tests                # ~5-20 minutes (browser, headless)

─────────────────────────────────
§14 MONOREPO & DEVELOPER EXPERIENCE
─────────────────────────────────

monorepo_tool:

task_runner:
  lint:
  test:
  dev:  # starts both backend and frontend

contract_sharing:
  strategy: openapi_codegen | graphql_sdl_codegen | manual | duplicated
  rationale:
  generation_trigger:

contract_change_detection:
  mechanism:
  ci_gate: yes
  pipeline_stage:
  failure_action:

frontend_architecture:
  layers:
    ui:
      allowed: [pure presentational components, typed props]
      forbidden: [data fetching, global state access, business logic]
      violation_detection:
    feature:
      allowed: [compose UI components, local state, call data layer]
      forbidden: [direct API calls, business logic]
      violation_detection:
    data:
      allowed: [all API communication, caching, data synchronization]
      forbidden: [rendering, local UI state]
      is_sole_consumer_of_api_contract: yes
    shared_core:
      allowed: [design system components, utilities, constants, cross-feature types]
      forbidden: [feature-specific logic]

state_management:
  server_state_tool:
  server_state_rationale:
  client_state_tool:
  client_state_rule: if it can be local, it must be local
  cache_invalidation_alignment:
    rule: frontend cache invalidation must be consistent with
      cache-control and ETag values in §8
    mechanism:

form_validation_alignment:
  strategy: generated_from_schema | shared_library | separate_with_review
  rationale:
  drift_detection:

frontend_auth_flow:
  # Must be consistent with token_delivery in §8
  token_storage:
  auth_state_contents:
  refresh_mechanism:
  revocation_trigger:

component_library:
  choice: third_party | headless_primitives | custom
  name:
  rationale:

local_dev_setup:
  new_engineer_target_minutes: 15
  steps:
    - [step]
  environment_variables:
    committed: .env.example with all keys, no values
    gitignored: .env.local

ci_local_script: scripts/ci-local.sh
# Path to the CI-local script. Populated in Phase 3C.
# Commands are filled in from plan.md §13 and §14 values.

─────────────────────────────────
§15 EDGE CASES & FAILURE MODES
─────────────────────────────────

# Minimum 10. Do not include concurrency conflicts (covered in §4).

FAILURE: [name]
  category: [partial_failure | malformed_input | upstream_failure |
    clock_skew | large_payload | invariant_violation | domain_specific]
  detection:
  response:
  recovery:

─────────────────────────────────
§16 ARCHITECTURAL CONSTRAINTS
─────────────────────────────────

# Exactly 10. Become CLAUDE.md "What NOT to do" verbatim.
# Form: "Never [specific action] because [specific consequence]."

  1.
  2.
  3.
  4.
  5.
  6.
  7.
  8.
  9.
  10.

─────────────────────────────────
§17 DEFINITION OF DONE
─────────────────────────────────

A feature is complete when:
  - [ ] [concrete verifiable criterion]

─────────────────────────────────
§18 SELF-CRITIQUE
─────────────────────────────────

# The 3 weakest points. Do not soften.

WEAK_POINT: [name]
  problem:
  reason_accepted:
  if_load_20x:
  if_second_team:
  if_key_dependency_lost:
  early_warning_signs:

─────────────────────────────────
§19 ADR LOG
─────────────────────────────────

# NOTE: For a living decision log (logged during implementation),
# see DECISION_LOG.md. This section is for high-level architectural
# decisions from the planning phase.

# Only for: aggregate boundaries, locking strategies, tech stack,
# bounded context patterns, token delivery, CORS, rendering strategy,
# contract sharing, any irreversible decision.

ADR-[N]: [title]
  context:
  decision:
  rejected:
    - option:
      reason:
  consequences:
    easier:
    harder:
    irreversible: yes | no
    reversal_cost:

─────────────────────────────────
§20 ARCHITECTURAL TEST INVENTORY
─────────────────────────────────

# Populated after generating arch test files.
backend_arch_test_file:
backend_arch_tool: [ArchUnit | dependency-cruiser | other]
frontend_arch_test_file:
frontend_arch_tool: dependency-cruiser
ci_stage: lint
failure_action: blocks merge
