First run: bash scripts/wf-summary.sh <feature_dir>
Print the summary output, then continue with the detailed status below.

Read the current feature's tasks.md by scanning .specify/specs/ for the
feature directory and reading its tasks.md file.
Also read plan.md §3 and §4 from that same feature directory.
Do not implement or modify anything.

━━ TASK PROGRESS ━━━━━━━━━━━━━━━━━━━━━━━

  Type              | DONE | IN_PROGRESS | TODO | ABANDONED | BLOCKED | Total
  ──────────────────────────────────────────────────────────────────────
  backend-domain    |      |         |      |           |         |
  backend-infra     |      |         |      |           |         |
  backend-api       |      |         |      |           |         |
  shared            |      |         |      |           |         |
  integration       |      |         |      |           |         |
  frontend-data     |      |         |      |           |         |
  frontend-feature  |      |         |      |           |         |
  e2e               |      |         |      |           |         |
  ──────────────────────────────────────────────────────────────────────
  TOTAL             |      |         |      |           |         |

Status definitions: templates/task-state-reference.md (source of truth)

━━ MODULE COMPLETION ━━━━━━━━━━━━━━━━━━━

For each bounded context from §3:
  CONTEXT: [name] | Aggregates: [list]
    backend-domain: [N]/[N] | backend-infra: [N]/[N] | backend-api: [N]/[N]
    frontend-data: [N]/[N]  | frontend-feature: [N]/[N]
    Status: NOT STARTED | IN_PROGRESS ([N]%) | COMPLETE

━━ WHAT IS UNBLOCKED NOW ━━━━━━━━━━━━━━━

TASK-[N]: [title] (Type: [type])
...
If none unblocked but tasks remain: "WARNING: possible dependency cycle."

━━ SPEC HEALTH ━━━━━━━━━━━━━━━━━━━━━━━━

Spec changes in DONE tasks NOT in plan.md: [N] — list them.
If >0: "Run /speckit.verify before continuing."
If 0:  "Spec health: clean."

━━ SUMMARY ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Progress: [N]% | Next task: TASK-[N] — [title]
Estimated remaining sessions: ~[N] (1-2 tasks/session)
Last completed: TASK-[N] — [title]
