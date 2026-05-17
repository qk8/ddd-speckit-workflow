# ── speckit.select-task — Task Selection & Partial File Detection ─
# Selects the current task per guides/task-selection.md.
# Detects partial files from interrupted runs.
#
# Usage: Called from speckit.implement as STEP 0.

─────────────────────────────────────────
STEP 1 — TASK SELECTION (per guides/task-selection.md)
─────────────────────────────────────────

Follow the task selection protocol:

1. Scan tasks.md for any task with Status: IN_PROGRESS.
   If found:
     Print: "IN_PROGRESS task detected: TASK-[N] — [title]"
     Print: "This task was left active from a previous session."
     Continue with this task.

2. If no IN_PROGRESS task: find the first TODO task where all Depends-on tasks are DONE.

3. Skip tasks whose Depends-on includes any non-DONE task (these are BLOCKED).

4. Among eligible TODO tasks, prefer:
   backend-domain > backend-infra > backend-api > shared > integration >
   frontend-data > frontend-feature > e2e.

Print: "Selected TASK-[N] — [title] (Type: [type])"

─────────────────────────────────────────
STEP 2 — PARTIAL FILE DETECTION
─────────────────────────────────────────

(Fix 10: mid-task failure recovery)
Check if any files from a previous interrupted run exist on disk:
  FEATURE_DIR="$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")"
  if [ -f "$FEATURE_DIR/.artifacts/skip-rollback" ]; then
    echo "ROLLBACK_SKIPPED: previous session chose to skip rollback"
  elif [ -f "$FEATURE_DIR/.artifacts/checkpoint.json" ]; then
    echo "CHECKPOINT_FOUND: partial files may exist from interrupted session"
    # Check if any Scope.Creates files already exist on disk
    for f in [list of Scope.Creates files from unified-context]; do
      if [ -f "$FEATURE_DIR/$f" ]; then
        echo "PARTIAL_FILE: $f exists — may be from interrupted run"
      fi
    done
  fi

If partial files are found:
  1. Print: "PARTIAL FILES DETECTED — consider /speckit.rollback to restore clean state"
  2. DO NOT proceed with implementation until the user confirms:
     "Proceed with partial files" or "Rollback first"
  3. If user chooses to proceed: continue with implementation, but note
     which files are partial and may need review.
