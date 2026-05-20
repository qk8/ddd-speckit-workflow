# ── Issue J: Spec Revision Task State ────────────────────────────
# When the implement loop discovers that the spec itself is wrong
# (not just code drift), this command handles spec corrections.
#
# The workflow assumes plan.md is the source of truth. But sometimes
# the spec is wrong — the adversarial audit catches this, but the
# recovery path was unclear. This command provides the path.
#
# Usage: speckit.spec-revise
#
# Process:
#   1. Read spec learnings from pending-learnings.md
#   2. Identify which plan.md sections need correction
#   3. Create a spec_revision task in tasks.md
#   4. Update spec.md and plan.md
#   5. Re-enter the implement loop with fresh context

Read CLAUDE.md fully.
Read the feature preamble from templates/preamble.md.

─────────────────────────────────────────
STEP 1 — READ PENDING LEARNINGS
─────────────────────────────────────────
Read .artifacts/pending-learnings.md (if it exists).
Read tasks.md to find any tasks with "Spec changes applied" that were not applied.
Read plan.md sections referenced by pending learnings.

─────────────────────────────────────────
STEP 1.5 — SPEC CHANGE IMPACT ANALYSIS
─────────────────────────────────────────
Before applying spec corrections, analyze which completed tasks will be affected:

If you have the old and new spec content:
  Run: bash scripts/spec-impact.sh "$(bash scripts/find-first-feature.sh)" <old_spec_path> <new_spec_path>
  Read the cascade report showing affected tasks grouped by severity.

If no separate old/new files (editing in place):
  1. Note which sections you are about to change
  2. Read tasks.md for all DONE tasks
  3. Read templates/spec-sections.md to map sections to task types
  4. Manually identify which tasks are affected
  5. Print: "AFFECTED TASKS: [list by severity]"

─────────────────────────────────────────
STEP 2 — IDENTIFY SPEC CORRECTIONS
─────────────────────────────────────────
For each pending learning that proposes a change to plan.md:
  1. Determine if the change is:
     - A: Spec is wrong (impossible to implement as specified)
     - B: Spec is incomplete (missing requirements discovered during implementation)
     - C: Spec is overly complex (simplification that preserves requirements)
     - D: Stack assumption is wrong (library/framework behaves differently than expected)

  2. For each correction, assess impact:
     - Which tasks are affected?
     - Does it require re-implementation of completed tasks?
     - Does it change the architecture or just the details?

─────────────────────────────────────────
STEP 3 — CREATE SPEC_REVISION TASK
─────────────────────────────────────────
For each significant spec correction (type A or B):
  1. Add a new task to tasks.md with Status: TODO
     Type: spec_revision
     Depends on: [tasks that discovered the issue]
     Scope:
       Creates:
         - Updated plan.md sections (list which sections)
         - Updated spec.md (list which sections)
       Modifies:
         - tasks.md (reset affected tasks to TODO if re-implementation needed)
     Acceptance criteria:
       - [Specific, verifiable criteria for the spec correction]
     Do NOT:
       - [Scope-creep guard for the spec revision]

  2. If affected tasks need re-implementation:
     - Reset their status from DONE back to TODO
     - Add "Re-implemented due to spec revision: [reason]" note

─────────────────────────────────────────
STEP 4 — PROPOSE SPEC CHANGES
─────────────────────────────────────────
For each approved spec correction:
  - Note the exact section.field being changed
  - Record the old value and new value
  - Print the proposed diff for each file
  - DO NOT modify plan.md or spec.md yet

─────────────────────────────────────────
STEP 5 — USER CONFIRMATION
─────────────────────────────────────────
Print:
  "SPEC REVISION: [N] proposed change(s) to plan.md and spec.md"
  "Affected tasks reset to TODO: [list]"
  "Approve to apply changes. Revise to adjust. Abort to skip."

Wait for user confirmation.
If user approves: apply all proposed changes to plan.md and spec.md.
  For each change:
    - Apply the modification
    - Add a comment: "# Spec revision [date]: [reason]"
  Print: "SPEC REVISION: [N] correction(s) applied to plan.md"
If user revises: go back to STEP 2 with feedback.
If user aborts: print "SPEC REVISION aborted" and proceed to next task.

Do NOT re-enter the implement loop until confirmed.
