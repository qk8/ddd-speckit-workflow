# Task Selection Protocol

When starting implementation or context gathering, select the current task using this protocol.

## Circular Dependency Detection

Before selecting a task, check for circular dependencies:

1. Build a dependency graph from tasks.md: for each TODO/IN_PROGRESS task,
   list its Depends-on tasks.
2. Run a cycle detection (DFS-based):
   - Start from each TODO/IN_PROGRESS task.
   - Follow Depends-on edges.
   - If you visit a task already in the current path: CYCLE DETECTED.
3. If a cycle is found:
   - Print: "CIRCULAR DEPENDENCY DETECTED: TASK-[A] → TASK-[B] → ... → TASK-[A]"
   - Mark all tasks in the cycle as BLOCKED with note: "circular_dependency"
   - Remove the circular Depends-on edge (keep the one with fewer dependents)
   - Re-run selection after breaking the cycle

If no cycle: proceed to normal selection.

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
