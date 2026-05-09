# ── Issue E: --max-lines flag to prevent context window overflow ──
# Usage: speckit.context --max-lines 50
# Hard truncation: the context output will never exceed N lines.
# If plan.md sections are larger than N, prioritize:
#   1. Task acceptance criteria (verbatim)
#   2. Relevant §2 ubiquitous language terms
#   3. Relevant §4 aggregate definitions (invariants, value objects)
#   4. Layer rules for this task's type
#   5. Applicable §16 constraints
# Everything else is elided with "[truncated — see plan.md for full details]"

Read CLAUDE.md fully.
Read the feature preamble from templates/preamble.md.

Check for IN_PROGRESS tasks first:
  Follow the task selection protocol: guides/task-selection.md
  If IN_PROGRESS task found:
    Read plan.md sections relevant to this task's Type (same as speckit.implement).
    Print compact context for this IN_PROGRESS task.
    Stop.
If no such task exists: "No unblocked tasks. Run /speckit.status." and stop.

Print: Next task: TASK-[N] — [title] | Type: [type] | Scope: [files]
Then read ONLY the plan.md sections for this task's Type.
Read the spec-sections mapping from templates/spec-sections.md.

# ── Apply --max-lines truncation (Issue E) ──────────────────────
# If --max-lines N was specified:
#   Count the total lines of the context output.
#   If lines > N, remove the least critical sections first:
#     1. Remove CONSTRAINTS TO WATCH (keep only most relevant 1-2)
#     2. Trim KEY NAMES to only the 3-5 most relevant terms
#     3. Compress RELEVANT SPEC to bullet points (no verbatim)
#   If still over N: truncate RELEVANT SPEC to first N/3 lines.
#   Append: "[Output truncated to --max-lines N. Full details in plan.md]"

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
