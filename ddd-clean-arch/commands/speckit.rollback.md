# ── speckit.rollback — Checkpoint Restore ────────────────────────
# Provides a safe rollback mechanism to restore files and reset tasks
# to a previous checkpoint state.
#
# Process:
#   1. List available checkpoints
#   2. Show diff of what would change
#   3. Confirm and perform restore
#   4. Reset task states
#   5. Log rollback in error-memory.json

Read CLAUDE.md fully.
Read the feature preamble from templates/preamble.md.

─────────────────────────────────────────
STEP 1 — LIST AVAILABLE CHECKPOINTS
─────────────────────────────────────────
Run: bash scripts/restore-checkpoint.sh "$(bash scripts/find-first-feature.sh)" --list
Read the output to see available checkpoints.
Note the checkpoint_id (snapshot filename) of the checkpoint to restore to.

─────────────────────────────────────────
STEP 2 — PREVIEW CHANGES (DRY RUN)
─────────────────────────────────────────
Run: bash scripts/restore-checkpoint.sh "$(bash scripts/find-first-feature.sh)" <checkpoint_id> --dry-run
Read the diff output showing:
  - MODIFIED files (hash changed since checkpoint)
  - DELETED files (existed in checkpoint, now gone)
  - NEW files (created since checkpoint)
  - Summary counts

Print: "DRY RUN — $N modified, $N deleted, $N new files"

─────────────────────────────────────────
STEP 3 — PERFORM ROLLBACK
─────────────────────────────────────────
Ask user to confirm before proceeding.
If confirmed, run: bash scripts/restore-checkpoint.sh "$(bash scripts/find-first-feature.sh)" <checkpoint_id> --confirm

Read the output showing:
  - Files restored via git checkout
  - Files backed up to .artifacts/rollback-backup/
  - Tasks reset to TODO
  - Rollback logged in error-memory.json

─────────────────────────────────────────
STEP 4 — VERIFY POST-ROLLBACK STATE
─────────────────────────────────────────
Run: bash scripts/health-dashboard.sh "$(bash scripts/find-first-feature.sh)"
Read the health dashboard to verify the project state after rollback.

Run: bash scripts/prompt-context.sh "$(bash scripts/find-first-feature.sh)"
Read the current task state to confirm which tasks need re-implementation.

Print:
  "ROLLBACK COMPLETE: <checkpoint_id>"
  "Tasks need re-implementation: [list]"
  "Run /speckit.context to load context for the next task."
