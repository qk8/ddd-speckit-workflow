Read the feature preamble from templates/preamble.md.
Read CLAUDE.md fully.

Check for IN_PROGRESS tasks first:
  Scan tasks.md for any task with Status: IN_PROGRESS.
  If found:
    Print: "IN_PROGRESS task detected: TASK-[N] — [title]"
    Print: "Continuing with this task."
    Read plan.md sections relevant to this task's Type (same as speckit.implement).
    Print compact context for this IN_PROGRESS task.
    Stop.
  If no IN_PROGRESS task: Find the first task in tasks.md where Status is TODO
and all Depends-on tasks are DONE.
If no such task exists: "No unblocked tasks. Run /speckit.status." and stop.

Print: Next task: TASK-[N] — [title] | Type: [type] | Scope: [files]
Then read ONLY the plan.md sections for this task's Type.
Read the spec-sections mapping from templates/spec-sections.md.

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

TASK SUMMARY (confirm before coding):
  What I will build: [one sentence from task title + acceptance criteria]
  Files I will create: [from Scope.Creates]
  Files I will modify: [from Scope.Modifies]
  Files I will NOT touch: [adjacent files that should remain unchanged]
  Definition of done: [checkable conditions from task]
  Assumptions I am making: [list, or "none"]

Wait for user confirmation before implementing.
Do NOT write any code until the user confirms this summary is correct.

Context ready. Run /speckit.implement to begin.
Do not implement from this command.
