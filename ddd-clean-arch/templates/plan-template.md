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
  - dependency: [name]
    threshold: [e.g., 5 failures / 10s]
    fallback: [e.g., cached response, default value]

structured_logging:
  format: JSON
  request_correlation: [mechanism — must match §8]
  pii_fields_excluded: [field names]

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
  backend_port: [port number]
  liveness:
    path: /healthz
    checks: [internal only]
  readiness:
    path: /readyz
    checks: [database, required external deps]

frontend_observability:
  error_tracking_tool: [Sentry | other]
  cross_stack_correlation: correlation ID from §8 attached to error reports

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
# See: guides/flaky-test-protocol.md for flaky test handling.
# No task is DONE without a persistent test file committed to the codebase.
# After every task, the full regression suite runs — zero new failures allowed.

# ── TOOL SELECTION ─────────────────────────────────────────────
# Derived from backend language in project-brief.md.
# See: guides/api-testing-tool-guide.md for full tool comparison.

api_testing_tool:
  # See: guides/api-testing-tool-guide.md for tool comparison.
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
  # Defined here once and referenced by speckit.implement check [BC] and [H],
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

# ── COVERAGE THRESHOLDS ──────────────────────────────────────
# Quantitative pass gate — thresholds are layer-specific, not flat.
# Derived from the zero-defect engineering standard.

coverage_thresholds:
  # Layer-specific minimums. Each layer has its own line/branch/function targets.
  # If a layer's coverage falls below its threshold, check [R] blocks the task.
  layers:
    business_logic:        # domain entities, use cases, domain services
      line: 95
      branch: 90
      function: 95
      path_pattern: [src/domain/**, src/application/**]
    api_route_handlers:    # controllers, route handlers, middleware
      line: 90
      branch: 85
      function: 90
      path_pattern: [src/presentation/**, src/delivery/**]
    ui_components:         # React/Vue/Svelte components
      line: 80
      branch: 75
      function: 80
      path_pattern: [src/components/**, src/features/**]
    auth_middleware:       # auth guards, token services, permission checks
      line: 95
      branch: 90
      function: 95
      path_pattern: [src/auth/**, src/security/**]
    repository_data_layer: # repository implementations, data adapters
      line: 90
      branch: 85
      function: 90
      path_pattern: [src/infrastructure/**/repository/**, src/infrastructure/**/data/**]
    shared_modules:        # utilities, value objects, helpers
      line: 85
      branch: 80
      function: 85
      path_pattern: [src/shared/**, src/common/**]
  # E2E critical paths: 100% coverage (all critical user journeys have test specs)
  e2e_critical_paths: 100

  # Global fallback: if a file doesn't match any layer pattern, use these.
  fallback:
    line: 90
    branch: 85
    function: 90

  # These are hard minimums. If any threshold is not met, write tests for uncovered paths or remove dead code.

# ── TYPE CHECKING ────────────────────────────────────────────
# Zero errors required. Strict mode must be enabled.

type_check_command:  # e.g. "tsc --noEmit" | "gradle typecheck" | "pyright src/"
  required_errors: 0

# ── LINTING ──────────────────────────────────────────────────
# Zero errors required. Warnings are logged but do not block.

lint_command:       # e.g. "pnpm lint" | "eslint src/ --max-warnings 0"
  required_errors: 0

# ── BUILD VERIFICATION ───────────────────────────────────────
# Clean compilation required.

build_command:       # e.g. "npm run build" | "gradle build" | "cargo build"
  required_errors: 0

# ── PROPERTY-BASED TESTS ─────────────────────────────────────
# Property-based tests assert invariants that hold for ANY valid input.
# These catch edge cases that example-based tests miss.

property_based_tests:
  tool:   # [fast-check | quickcheck | hypothesis | custom]
  invariants:
    # Define invariants derived from plan.md §2 (ubiquitous language) and §4 (aggregate rules).
    # Each invariant must be testable with 100+ random generations.
    # Examples:
    #   - User.create(email).email == email.toLowerCase()
    #   - PasswordHash(password) != password
    #   - JWT.sign(payload).JWT.verify(token) == payload
    #   - Pagination(total=N, size=P) returns exactly N unique records
  min_generations: 100

# ── TEST PYRAMID ───────────────────────────────────────────────

unit_tests:
  target_layers: [domain, application]
  infrastructure_dependencies: none
  max_acceptable_duration_ms: 10
  framework:    # [JUnit 5 | Vitest | pytest]
  location: [path pattern, e.g. src/test/java/**/unit/]
  coverage_focus: [invariants, use case orchestration, all error paths]

integration_tests:
  target_layers: [infrastructure]
  uses_real_infrastructure: yes
  framework:    # [JUnit 5 + Testcontainers | Vitest | pytest]
  location: [path pattern]
  coverage_focus: [repository implementations, external adapters]

api_tests:
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

# ── TEST DATA ISOLATION ─────────────────────────────────────────
# See: guides/test-data-strategy.md for full strategy guide.

test_data_strategy:
  approach: [test_containers_per_test | shared_db_with_cleanup | factory_functions]
  factory_location: [path — e.g. src/test/java/fixtures/ or tests/fixtures/]
  e2e_data_setup:
    strategy: [api_seeding | db_seeding | before_each_hook]
    cleanup: [after_each | after_all | none_if_isolated_db]
    isolation_guarantee: [each_test_independent | run_in_isolation_only]
  forbidden:
    - Tests must never share state through static variables or module-level singletons
    - Tests must never read data written by a different test
    - Tests must never depend on test execution order
    - E2E tests must never reuse user accounts created by other tests

# ── FLAKY TEST PROTOCOL ──────────────────────────────────────────
# See: guides/flaky-test-protocol.md for full SOP (definition, fix approach, forbidden).
flaky_test_protocol:
  quarantine_location: [path — e.g. tests/quarantine/ or src/test/java/quarantine/]
  quarantine_suite_runs: [nightly | manual — NOT on every PR]
  ticket_required: yes
  max_time_in_quarantine: [e.g. 2 weeks]

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
# See: scripts/ci-local.sh — the canonical stage order and execution engine.
# The stages defined above in ci_execution_order must match ci-local.sh.
ci_execution_order:

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
  layers: [ui → feature → data → shared_core]
  data_layer: sole consumer of api-contract.yaml (§8)
  state_rule: if it can be local, it must be local

state_management:
  server_state_tool: [tanstack-query | swr | other]
  client_state_tool: [zustand | jotai | none]
  cache_invalidation: consistent with cache-control in §8

form_validation_alignment: generated_from_schema | shared_library

frontend_auth_flow: consistent with token_delivery in §8
  token_storage: httpOnly cookie | localStorage (if no XSS risk)

component_library: third_party | headless_primitives | custom

local_dev_setup:
  new_engineer_target_minutes: 15
  steps:
    - [step]

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
#
# Each constraint must be specific enough that an LLM agent can
# enforce it mechanically. Vague constraints like "Never write bad code"
# are not acceptable. Every constraint must name a concrete action
# and a concrete consequence.

  1. Never let the domain layer import from infrastructure, application, or delivery modules because it breaks dependency inversion and makes domain logic untestable without mocks.
  2. Never return raw database entities or ORM proxies to the delivery layer because it leaks implementation details and prevents enforcement of the error envelope from §7.
  3. Never use string literals for HTTP status codes in API responses because it prevents compile-time validation and makes search-and-replace refactoring error-prone.
  4. Never store secrets, tokens, or credentials in environment variables readable by all processes on the host because it violates the principle of least privilege.
  5. Never allow a single task to modify files in more than two module boundaries because it creates hidden coupling between bounded contexts.
  6. Never dispatch domain events before the transaction commits because it creates phantom state observable by other concurrent transactions.
  7. Never accept unbounded collections as API input parameters because it enables denial-of-service through memory exhaustion.
  8. Never use shared mutable state (static variables, module-level singletons) between request handlers because it creates non-deterministic race conditions.
  9. Never log request bodies, query parameters, or headers without explicit allowlisting because it may capture PII or credentials.
  10. Never implement a use case without an idempotency mechanism when the operation has side effects because client retries will produce duplicate results.

─────────────────────────────────
§17 DEFINITION OF DONE
─────────────────────────────────

A feature is complete when:
  - [ ] [concrete verifiable criterion]
  - [ ] All new tests pass (check [BC])
  - [ ] Zero regression failures (check [BC])
  - [ ] Coverage ≥ [line]%/[branch]%/[function]% (plan.md §13 coverage_thresholds)
  - [ ] 0 TypeScript/type errors (plan.md §13 type_check_command)
  - [ ] 0 lint errors (plan.md §13 lint_command)
  - [ ] Clean build (plan.md §13 build_command)
  - [ ] All domain invariants have property-based tests (plan.md §13 property_based_tests)

─────────────────────────────────
§18 SELF-CRITIQUE
─────────────────────────────────

# 3 weakest points. Do not soften.

WEAK_POINT: [name]
  problem: [one line]
  if_load_20x: [impact]
  if_second_team: [impact]

─────────────────────────────────
§19 ADR LOG
─────────────────────────────────

# High-level architectural decisions. For living log see DECISION_LOG.md.

ADR-[N]: [title]
  decision: [one line]
  consequences: easier: [yes] / harder: [yes]

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
