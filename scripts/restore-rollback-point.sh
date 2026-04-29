#!/usr/bin/env bash
# Restore a rollback point (undo implementation changes).
# Pops the stash saved by save-rollback-point.sh.
# Usage: bash scripts/restore-rollback-point.sh <stash_ref>
set -euo pipefail

STASH_REF="${1:?Usage: bash scripts/restore-rollback-point.sh <stash_ref>}"

if [ "$STASH_REF" = "none" ]; then
  echo "ROLLBACK_DONE=none (no stash to restore)"
  exit 0
fi

# Apply and drop the stash (restores files + removes stash entry)
if git stash pop "$STASH_REF" 2>/dev/null; then
  echo "ROLLBACK_DONE=true"
  echo "ROLLBACK_STASHED_FILES=$(git stash show --name-only "$STASH_REF" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "various")"
else
  echo "ROLLBACK_DONE=fail (stash may have conflicts or already popped)"
  # Try pop without auto-merge
  git stash pop --index "$STASH_REF" 2>/dev/null || true
fi
