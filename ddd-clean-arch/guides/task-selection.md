# Task Selection Protocol

When starting implementation or context gathering, select the current task using this protocol.

## IN_PROGRESS Task First

Scan tasks.md for any task with Status: IN_PROGRESS.
If found:
  Print: "IN_PROGRESS task detected: TASK-[N] — [title]"
  Print: "This task was left active from a previous session."
  Print: "Continuing with this task."
  Keep Status as IN_PROGRESS (do not change it).
  Continue with this task.

If no IN_PROGRESS task: Find the first task in tasks.md where Status is TODO
and all Depends-on tasks are DONE.
Skip tasks whose Depends-on includes any task that is not DONE (these are BLOCKED).
