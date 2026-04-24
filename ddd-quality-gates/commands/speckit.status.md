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

Status definitions:
  DONE      — all 11 checks passed, test file committed
  IN_PROGRESS   — currently being worked on (set at task confirmation)
              If IN_PROGRESS is present: a session may have been interrupted.
              Run /speckit.retrospect or check-tasks.sh for details.
  TODO      — not started, dependencies met or pending
  ABANDONED — interrupted; partial files may exist on disk
  BLOCKED   — Depends-on contains at least one task that is not DONE

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
