# ── speckit.impact — Cross-Task Impact Analysis ──────────────────
# Analyzes file-level dependencies across all tasks to detect
# silent cascading bugs where one task modifies a file that
# other tasks depend on.
#
# Process:
#   1. Run impact analysis script
#   2. Review cross-task file overlaps
#   3. Flag HIGH risk files

Read CLAUDE.md fully.
Read the feature preamble from templates/preamble.md.

─────────────────────────────────────────
STEP 1 — IDENTIFY CURRENT TASK
─────────────────────────────────────────
Read tasks.md to determine the current task (first IN_PROGRESS or first TODO).
Extract: task_id, task_type, scope (creates/modifies).

─────────────────────────────────────────
STEP 2 — RUN IMPACT ANALYSIS
─────────────────────────────────────────
Run: bash scripts/impact-analysis.sh "$(bash scripts/find-first-feature.sh)" <task_id> <task_type> --show-tests
Read the output showing:
  - Files being modified by this task
  - Past tasks that also touched these files
  - Future tasks that will touch these files
  - Risk level (LOW/MEDIUM/HIGH)
  - Test file coverage

─────────────────────────────────────────
STEP 3 — HANDLE HIGH RISK
─────────────────────────────────────────
If any HIGH risk files are reported:
  1. Print: "HIGH RISK: <file> — <N> overlapping tasks"
  2. Review the specific overlap:
     - Which past task created/modified the file?
     - Which future task will also touch it?
  3. Before implementing:
     - Read the past task's implementation to understand the current shape
     - Check if future tasks' scope includes this file
     - Consider if the change is interface-breaking
  4. If the change is interface-breaking:
     - Note which future tasks need updates
     - Print: "INTERFACE CHANGE WARNING: <file> — future tasks <list> may need updates"
  5. Continue implementation with awareness of the risk

If no HIGH risk: proceed normally with awareness of MEDIUM risk files.

─────────────────────────────────────────
STEP 4 — RECORD FILE TRACKING
─────────────────────────────────────────
After implementation, run:
  bash scripts/track-created-files.sh "$(bash scripts/find-first-feature.sh)" <task_id> <file1> [file2] ...
This records which files this task created/modified for future impact analysis.
