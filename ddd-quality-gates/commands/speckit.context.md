Locate the current feature:
  Scan .specify/specs/ for the first feature directory.
  The feature's tasks.md is at: .specify/specs/[feature-name]/tasks.md
  The feature's plan.md is at:  .specify/specs/[feature-name]/plan.md

Check for IN_PROGRESS tasks first:
  Scan tasks.md for any task with Status: IN_PROGRESS.
  If found:
    Print: "IN_PROGRESS task detected: TASK-[N] — [title]"
    Print: "Continuing with this task."
    Print: "Reading CLAUDE.md and relevant plan.md sections."
    Read CLAUDE.md fully.
    Read plan.md sections relevant to this task's Type (same as speckit.implement).
    Print compact context for this IN_PROGRESS task.
    Stop.
  If no IN_PROGRESS task: Find the first task in tasks.md where Status is TODO
and all Depends-on tasks are DONE.
If no such task exists: "No unblocked tasks. Run /speckit.status." and stop.

Print: Next task: TASK-[N] — [title] | Type: [type] | Scope: [files]

Read CLAUDE.md fully.
Then read ONLY these plan.md sections based on task Type:

  backend-domain  → §2, §4 (aggregate in scope only), §6 domain rules,
                    §7 validation + error taxonomy,
                    §13 unit_tests (location, framework, coverage_focus) + regression_command,
                    §16, §17
  backend-infra   → §4 (aggregate in scope), §6 infra rules,
                    §12 (table in scope), migration_strategy,
                    §13 integration_tests (location, framework) + regression_command,
                    §13 test_data_strategy,
                    §16, §17
  backend-api     → §6 app + delivery rules, §7 full, §8 (endpoint in scope, §8 correlation_id_header_name),
                    §13 api_tests + api_testing_tool + regression_command,
                    §13 test_data_strategy,
                    §16, §17
  shared          → §14 contract + change_detection, §3,
                    §13 contract_testing + regression_command,
                    §16, §17
                    + docs/spec/api-contract.yaml (full) +
                      docs/spec/backend-interfaces.[ext] +
                      docs/spec/frontend-interfaces.[ext]
  integration     → §3 (bounded contexts involved), §4 (aggregates on both sides),
                    §6 (module boundaries between contexts), §7,
                    §13 integration_tests + regression_command, §16, §17
  frontend-data   → §7, §8 (endpoints called, §8 correlation_id_header_name),
                    §11 frontend_observability,
                    §14 frontend_architecture + frontend_auth_flow,
                    §13 unit_tests + regression_command,
                    §16, §17
  frontend-feature→ §7 user-facing errors, §14 frontend_architecture.layers.ui +
                    frontend_architecture.layers.feature +
                    state_management +
                    form_validation_alignment +
                    component_library,
                    §13 e2e_tests + regression_command,
                    §13 e2e_data_setup + test_data_strategy,
                    §16, §17
  e2e             → §13 e2e_tests + regression_command,
                    §13 e2e_data_setup + test_data_strategy,
                    §8 all endpoints, §17

Do not read sections outside the list above.

Print compact context:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CONTEXT LOADED — TASK-[N]: [title] | Type: [type]

RELEVANT SPEC:
  [Only the fields directly needed — verbatim from plan.md]

KEY NAMES (§2 + §4):
  [class/event/field names for this task only]

LAYER RULES:
  [rules for this task's layer only]

CONSTRAINTS TO WATCH (§16):
  [constraints this task could plausibly violate]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Context ready. Run /speckit.implement to begin.
Do not implement from this command.
