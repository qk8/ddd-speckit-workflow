#!/usr/bin/env bash
# Save a rollback point before implementing a task.
# Creates a git stash of uncommitted changes and records the stash ref.
# Usage: bash scripts/save-rollback-point.sh
# Output: ROLLBACK_STASH=<stash_ref> or ROLLBACK_STASH=none
set -euo pipefail

# Only stash if there are uncommitted changes (tracked or untracked)
HAS_CHANGES=$(git status --porcelain 2>/dev/null || true)
if [ -z "$HAS_CHANGES" ]; then
  echo "ROLLBACK_STASH=none"
  echo "ROLLBACK_NOTE=No uncommitted changes to save"
  exit 0
fi

# Create a stash with a descriptive message
STASH_MSG="rollback-point-$(date +%s)"
STASH_REF=$(git stash push --include-untracked -m "$STASH_MSG" 2>/dev/null && echo "stash@{0}" || echo "")

if [ -n "$STASH_REF" ]; then
  # List what was stashed
  STASHED_FILES=$(git stash show --name-only "$STASH_REF" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "various")
  echo "ROLLBACK_STASH=$STASH_REF"
  echo "ROLLBACK_NOTE=Stashed: $STASHED_FILES"
else
  echo "ROLLBACK_STASH=none"
  echo "ROLLBACK_NOTE=Stash failed — changes may already be committed"
fi
