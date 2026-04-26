# Spec Section Mapping — Task Type → plan.md Sections

Read only the plan.md sections relevant to the current task's Type.

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
