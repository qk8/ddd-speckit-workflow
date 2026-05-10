# ── speckit.pre-mortem — Pre-Mortem Analysis ─────────────────────
# Run between plan review and tasks phase to proactively identify
# failure modes before implementation begins.
#
# Process:
#   1. Read plan.md and tasks.md
#   2. Analyze for common failure patterns
#   3. Document risks and mitigations
#   4. Save to .artifacts/pre-mortem.md

─────────────────────────────────────────
STEP 1 — READ PLAN AND TASKS
─────────────────────────────────────────
Read .artifacts/unified-context.json (generate if missing):
  Run: bash scripts/unified-context.sh "$(bash scripts/find-first-feature.sh)" TASK-1 backend-domain

Read plan.md in full — especially:
  - §1-3: Architecture and domain model
  - §13: Implementation plan and test strategy
  - §16: Constraints

Read tasks.md — identify:
  - Task dependencies (depends_on fields)
  - Scope boundaries (scope.creates, scope.modifies)
  - Acceptance criteria per task

─────────────────────────────────────────
STEP 2 — ANALYZE FAILURE MODES
─────────────────────────────────────────
For each task, identify potential failure modes:

ARCHITECTURAL RISKS:
  - Does any task cross layer boundaries? (e.g., infra calling domain directly)
  - Are there shared mutable state risks between tasks?
  - Is the domain model consistent with the brief?

DEPENDENCY RISKS:
  - Are there circular dependencies in task depends_on?
  - Are there tasks that depend on unimplemented interfaces?
  - Will any task modify an interface that another task already depends on?

TESTING RISKS:
  - Are there acceptance criteria without clear test paths?
  - Are there integration points not covered by any task's test?
  - Is there a regression baseline strategy?

OPERATIONAL RISKS:
  - Are there security-sensitive operations not covered?
  - Are there performance-critical paths without budgets?
  - Are there migration risks (data loss, downtime)?

SPEC-IMPLEMENTATION RISKS:
  - Are there ambiguous requirements that could be interpreted multiple ways?
  - Are there edge cases mentioned in the brief but not in tasks?
  - Are there §16 constraints that conflict with the plan?

─────────────────────────────────────────
STEP 3 — DOCUMENT RISKS AND MITIGATIONS
─────────────────────────────────────────
Write findings to .artifacts/pre-mortem.md:

```markdown
# Pre-Mortem Analysis — [feature name]
## Date: [date]

### Architectural Risks
1. [Risk]: [Description]
   Mitigation: [How to prevent]
   Task impact: [Which tasks affected]

### Dependency Risks
...

### Testing Risks
...

### Operational Risks
...

### Spec-Implementation Risks
...

### Overall Risk Assessment: [LOW/MEDIUM/HIGH]
### Recommended Actions:
1. [Action item]
2. [Action item]
```

─────────────────────────────────────────
STEP 4 — DECISION GATE
─────────────────────────────────────────
If RISK is HIGH:
  - Review mitigations with plan author
  - Consider splitting high-risk tasks
  - Add extra checks to preset.yml if needed

If RISK is MEDIUM:
  - Document mitigations
  - Proceed with tasks phase

If RISK is LOW:
  - Proceed with tasks phase

Print: "PRE-MORTEM COMPLETE — Risk: [LEVEL], [N] mitigations documented"
