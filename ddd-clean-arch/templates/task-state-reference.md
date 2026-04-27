Task states (source of truth for all speckit commands):

  TODO        — not started, dependencies met or pending
  IN_PROGRESS — currently being worked on (set at task confirmation)
              If IN_PROGRESS is present: a session may have been interrupted.
              Run /speckit.retrospect or check-tasks.sh for details.
  DONE      — all applicable checks passed, test file committed
  ABANDONED — interrupted; partial files may exist on disk
  BLOCKED   — Depends-on contains at least one task that is not DONE

Transitions:
  TODO → IN_PROGRESS (when task is selected for work)
  IN_PROGRESS → DONE (when all checks pass)
  IN_PROGRESS → ABANDONED (when user stops or session interrupted)
  TODO → BLOCKED (when a dependency becomes BLOCKED or ABANDONED)
  BLOCKED → TODO (when the blocking dependency completes)
  ABANDONED → TODO (when restarted after cleanup)
