# Spec Section Mapping — Task Type → plan.md Sections

Read only the plan.md sections relevant to the current task's Type.
All types implicitly include: regression_command, §16, §17

## Priority System (Fix 9: context window overflow)
Each section is tagged with a priority level:
- **priority: high** — always included, never truncated
- **priority: medium** — included normally; truncated to 200 lines when context is tight
- **priority: low** — only included when context budget allows; elided with "[truncated]" when tight

  backend-domain  → §2 (high), §4 aggregate in scope (high), §6 domain rules (medium),
                    §7 validation + error taxonomy (high), §13 unit_tests (medium)
  backend-infra   → §4 aggregate in scope (high), §6 infra rules (medium),
                    §12 table in scope (high), migration_strategy (high),
                    §13 integration_tests (medium)
  backend-api     → §6 app + delivery rules (medium), §7 full (high), §8 endpoint in scope (high),
                    §8 correlation_id_header_name (high),
                    §13 api_tests (medium)
                    + docs/spec/api-contract.yaml for endpoint(s) in scope (high)
  shared          → §14 contract_sharing + change_detection (medium), §3 (high),
                    §13 contract_testing (medium)
                    + docs/spec/api-contract.yaml full (high)
                    + docs/spec/backend-interfaces.[ext] and frontend-interfaces.[ext] (high)
  integration     → §3 bounded contexts involved (high), §4 aggregates on both sides (high),
                    §6 module boundaries between contexts (medium), §7 (high),
                    §13 integration_tests (medium)
  frontend-data   → §7 error taxonomy (high), §8 endpoints this module calls (high),
                    §8 correlation_id_header_name (high),
                    §11 frontend_observability (medium),
                    §14 frontend_architecture + frontend_auth_flow (medium),
                    §13 unit_tests (medium)
                    + docs/spec/frontend-interfaces.[ext] for relevant context (high)
  frontend-feature→ §7 user-facing error behavior (high),
                    §14 frontend_architecture.layers.ui (medium),
                    frontend_architecture.layers.feature (medium),
                    §14 state_management (medium) +
                    §14 form_validation_alignment (medium) +
                    §14 component_library (medium),
                    §13 e2e_tests (medium)
  e2e             → §13 e2e_tests (high),
                    §8 all endpoints (high)
