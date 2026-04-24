Read CLAUDE.md fully.
(verify reads CLAUDE.md fully — it is short by design and contains the rules
that everything is checked against.)

Locate the current feature by scanning .specify/specs/ for the first
feature directory. All plan.md and spec file reads below use that directory:
  plan.md      → .specify/specs/[feature]/plan.md
  tasks.md     → .specify/specs/[feature]/tasks.md
  conventions  → .specify/memory/conventions.md

Ask: "What do you want to verify?"
  1. A specific aggregate
  2. A specific module
  3. A specific endpoint
  4. The full codebase

Wait for answer before loading any spec.

Based on the scope chosen, load ONLY the relevant plan.md sections:

  Scope 1 (aggregate):
    Read §2 (naming), §4 (the specific aggregate's block only), §6 (layer rules),
    docs/spec/backend-interfaces.[ext] (the aggregate's interface block only)

  Scope 2 (module):
    Read §2 (naming), §3 (the module's bounded context block), §6 (layer rules,
    module boundaries), §16 (all 10 constraints)

  Scope 3 (endpoint):
    Read §7 (error taxonomy + envelope), §8 (the specific endpoint block only),
    §8 correlation_id_header_name,
    docs/spec/api-contract.yaml (the specific endpoint only),
    docs/spec/backend-interfaces.[ext] (the aggregate interface for this endpoint),
    docs/spec/frontend-interfaces.[ext] (the function for this endpoint only)

  Scope 4 (full codebase):
    Read §2, §4 (all aggregates), §6, §7, §8 (all endpoints, §8 correlation_id_header_name), §16, §20,
    docs/spec/api-contract.yaml (full),
    docs/spec/backend-interfaces.[ext] (full),
    docs/spec/frontend-interfaces.[ext] (full)

Do not read plan.md end to end. Load only the sections listed above for the chosen scope.
This keeps context window available for the actual drift analysis.

━━ TEST SUITE ━━━━━━━━━━━━━━━━━━━━━━━━━━

Run the appropriate regression command from plan.md §13 regression_command:
  For scopes 1-3 (partial): regression_command.api_only
  For scope 4 (full):       regression_command.all

Print full output.
  TESTS: [N] total | [N] passed | [N] failed
  If any fail: list each: [test name] — [failure message]
  Do not proceed to other checks if tests are failing.
  Tests must be green before drift analysis is meaningful.

━━ LAYER COMPLIANCE ━━━━━━━━━━━━━━━━━━━━

Run arch tests from plan.md §20.
For each failure:
  VIOLATION: [rule] | File: [path:line] | Spec: plan.md §[N] — [rule text]

━━ NAMING COMPLIANCE ━━━━━━━━━━━━━━━━━━━

Compare class/method/event/field names in scope against §2 and §4.
  NAMING DRIFT: [found] vs [spec says] | File: [path] | Severity: breaking | cosmetic
  breaking = different type or structure | cosmetic = case or style only

━━ INTERFACE COMPLIANCE ━━━━━━━━━━━━━━━━

For each aggregate in scope: compare against docs/spec/backend-interfaces.[ext].
  INTERFACE DRIFT: [what differs] | Spec: [definition] | Code: [found]

For each endpoint in scope: compare against docs/spec/api-contract.yaml.
Compare frontend data-layer functions against docs/spec/frontend-interfaces.[ext].
  CONTRACT DRIFT: [what differs] | Spec: [definition] | Code: [found]

━━ SPEC LEARNING AUDIT ━━━━━━━━━━━━━━━━━

Scan DONE tasks in tasks.md for "Spec changes applied".
Cross-check: are those changes in plan.md?
  UNRECORDED: TASK-[N] recorded "[change]" not in plan.md §[section]

━━ SUMMARY ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

VERIFY REPORT — [scope]
  Layer violations: [N] | Naming drift (breaking): [N] | (cosmetic): [N]
  Interface drift: [N] | Unrecorded decisions: [N]
  Overall: CLEAN | DRIFT DETECTED

If DRIFT DETECTED: for each issue state whether to fix in code or in spec.
Wait for user decision before any changes.
