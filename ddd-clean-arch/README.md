# DDD Clean Architecture Preset

Clean Architecture preset for the DDD Spec Kit. Provides templates, checks, and configuration for spec-driven development with DDD principles.

## Commands

| Command | Description |
|---------|-------------|
| `speckit.specify` | Create feature specification |
| `speckit.plan` | Generate implementation plan from spec |
| `speckit.tasks` | Break plan into executable tasks |
| `speckit.implement` | Execute tasks with TDD workflow |
| `speckit.check` | Run quality checks for current task |
| `speckit.code-review` | Phase 7 code review checklist |
| `speckit.verify` | Spec-code drift detection |
| `speckit.review` | Design quality review (5 dimensions) |
| `speckit.retrospect` | Adaptive retrospective cadence |
| `speckit.status` | Progress dashboard |
| `speckit.context` | Targeted spec loading for long sessions |
| `speckit.test` | Standalone live test and debug sessions |

## Quality Checks

21 checks (A–U, BC) applied per task type. Routing table in `preset-checks.yml`.

| ID | Name | Applies To |
|----|------|------------|
| A | Architectural Tests | backend-domain, backend-infra, backend-api |
| BC | New Tests + Regression | all |
| D | Linter | all |
| E | Dependency Vulnerability Scan | backend-domain, backend-infra, backend-api, shared |
| F | Migration Test | backend-infra |
| G | Error Handling Assertions | backend-api, frontend-data |
| H | Browser Verification | frontend-feature, e2e |
| I | Secret Scanning | all |
| J | Performance Budget | backend-api, frontend-feature |
| K | API Contract Enforcement | backend-api, shared |
| L | Anti-Hallucination Check | all |
| M | Failure Mode Coverage | all |
| N | Cross-Cutting Concern Audit | backend-api, shared |
| O | Security Hardening | backend-api, backend-infra, frontend-data, frontend-feature |
| P | Test Quality Review | all |
| Q | Resilience Testing | backend-api, backend-infra |
| R | Quantitative Pass Gate | backend-api, shared |
| S | Property-Based Test Coverage | all |
| T | Adversarial Input Testing | backend-api, shared |
| U | Session & Token Security | backend-api |
| Z | Constraint Drift Detection | all |

**Integration tasks** (cross-context boundary tests) run checks: BC, D, I, L, M, P, S, Z.

## Structure

```
ddd-clean-arch/
├── commands/           # speckit.* command templates
│   ├── checks/        # Individual check sub-files (check_[X]_[name].mdc)
│   ├── speckit.check.md
│   ├── speckit.implement.md
│   └── ...
├── templates/          # Plan, spec, and task templates
│   ├── plan-template.md
│   ├── tasks-template.md
│   └── ...
├── guides/             # Process guides (correction loop, dev server, etc.)
├── preset.yml          # Full configuration
└── preset-checks.yml   # Check routing table (subset of preset.yml)
```

## Known Gaps

No checks for: i18n, backup/restore, API versioning, CI/CD pipeline validity.
