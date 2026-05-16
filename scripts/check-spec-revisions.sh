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
# Default max revisions: sourced from revision-limits.sh (default: 3).
# Spec revisions are more disruptive than task revisions — they reset completed tasks.

set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  shift
fi

FEATURE_DIR="${1:?Usage: check-spec-revisions.sh <feature_dir> [--dry-run]}"

# Source central revision limits (default: 3, overrides via env var supported)
source "$(dirname "$0")/revision-limits.sh"
# MAX_SPEC_REVISIONS now comes from revision-limits.sh

COUNT_FILE="$FEATURE_DIR/.spec_revision_count"
CASCADE_FILE="$FEATURE_DIR/.spec_revision_cascade"
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

# Cascade tracking: spec revision creates new tasks which can also be revised.
# Prevents compound infinite loops (spec revision → new tasks → more revisions).
CASCADE_COUNT=0
if [ -f "$CASCADE_FILE" ]; then
  CASCADE_COUNT=$(cat "$CASCADE_FILE" 2>/dev/null || echo 0)
  case "$CASCADE_COUNT" in ''|*[!0-9]*) CASCADE_COUNT=0 ;; esac
fi

if [ "$CASCADE_COUNT" -ge "$MAX_SPEC_REVISIONS" ]; then
  echo "SPEC_REVISION_OK=false"
  echo "SPEC_REVISION_EXHAUSTED=true"
  echo "CASCADE_EXHAUSTED=true"
  echo "Spec revision cascade limit reached ($CASCADE_COUNT rounds). No further revisions." >&2
  flock -u 200
  exit 1
fi

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

  # Cascade: increment when spec revision creates new tasks.
  # The orchestrator (05-implement.yml) should call this with CASCADE=1
  # when a spec revision adds new tasks to tasks.md.
  if [ "${CASCADE_INCREMENT:-0}" = "1" ]; then
    CASCTMP=$(mktemp)
    echo "$((CASCADE_COUNT + 1))" > "$CASCTMP"
    mv "$CASCTMP" "$CASCADE_FILE"
    echo "CASCADE_ROUND=$((CASCADE_COUNT + 1))"
  fi
else
  echo "SPEC_REVISIONS=$CURRENT"
fi

flock -u 200
exit 0
