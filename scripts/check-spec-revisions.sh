#!/usr/bin/env bash
# Track spec revision attempts.
# Prevents infinite spec-revise loops during the implement loop.
#
# Usage:
#   check-spec-revisions.sh <feature_dir> [--dry-run]
#
# Outputs:
#   SPEC_REVISIONS=N
#   SPEC_REVISION_OK=true|false
#   SPEC_REVISION_EXHAUSTED=true|false
#
# Creates: .spec_revision_count (atomic writes via flock)
#
# Default max revisions: 2 (more conservative than task revisions' max of 3,
# since spec revisions are more disruptive — they reset completed tasks).

set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  shift
fi

FEATURE_DIR="${1:?Usage: check-spec-revisions.sh <feature_dir> [--dry-run]}"
MAX_SPEC_REVISIONS=2

COUNT_FILE="$FEATURE_DIR/.spec_revision_count"
LOCK_FILE="$COUNT_FILE.lock"
mkdir -p "$FEATURE_DIR"

# Use flock for mutual exclusion around the counter cycle
exec 200>"$LOCK_FILE"
flock -x 200

# Read current count (default 0)
CURRENT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
case "$CURRENT" in
  ''|*[!0-9]*) CURRENT=0 ;;
esac

# Output current state
echo "SPEC_REVISIONS=$CURRENT"
echo "SPEC_REVISION_OK=true"
echo "SPEC_REVISION_EXHAUSTED=false"

# Check if limit is reached
if [ "$CURRENT" -ge "$MAX_SPEC_REVISIONS" ]; then
  echo "SPEC_REVISION_OK=false"
  echo "SPEC_REVISION_EXHAUSTED=true"
  echo "Spec has been revised $CURRENT times (max $MAX_SPEC_REVISIONS). Aborting revision loop." >&2
  flock -u 200
  exit 1
fi

# Increment atomically: write to count file (skip in dry-run mode)
if [ "$DRY_RUN" = false ]; then
  TMPFILE=$(mktemp)
  echo "$((CURRENT + 1))" > "$TMPFILE"
  mv "$TMPFILE" "$COUNT_FILE"
  echo "SPEC_REVISIONS=$((CURRENT + 1))"
else
  echo "SPEC_REVISIONS=$CURRENT"
fi

flock -u 200
exit 0
