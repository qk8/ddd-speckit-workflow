Read tasks.md from its current location (scan .specify/specs/ for the feature directory).

Find all ABANDONED tasks. For each one:
  1. Extract the task ID, title, and abandonment reason (from the "Abandoned at" or notes field)
  2. Identify which plan.md section or acceptance criterion this task was responsible for
  3. Summarize what functionality is now missing due to this abandonment

Write the summary to .artifacts/abandoned-tasks-summary.md with this format:

## Abandoned Tasks Summary

### Overview
- Total tasks: [N]
- Abandoned: [M]
- Completion rate: [X]%

### Abandoned Task Details

#### TASK-[N] — [title]
- **Reason**: [abandonment reason from tasks.md]
- **Affected area**: [plan.md section or feature area]
- **Missing functionality**: [description of what is not implemented]
- **Risk level**: [HIGH/MEDIUM/LOW — HIGH if it affects core domain logic or security]

Print: "ABANDONED TASKS SUMMARY: [M] of [N] tasks abandoned ([X]% completion)"
