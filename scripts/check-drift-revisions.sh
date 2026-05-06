#!/usr/bin/env bash
# Track drift fix revisions per retro cycle.
# Usage: check-drift-revisions.sh <feature_dir>
#
# Outputs:
#   DRIFT_REVISIONS=N
#   MAX_DRIFT_REVISIONS_EXCEEDED=true|false
#
# Resets on each retro cycle (cleared when retro_trigger fires).

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-drift-revisions.sh <feature_dir>}"
MAX_DRIFT_REVISIONS=2

STATE_FILE="$FEATURE_DIR/.drift_revisions"
LOCK_FILE="$STATE_FILE.lock"
mkdir -p "$FEATURE_DIR"

# Use flock for mutual exclusion around read-modify-write cycle
exec 200>"$LOCK_FILE"
flock -x 200

# Read current count
CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
case "$CURRENT" in
  ''|*[!0-9]*) CURRENT=0 ;;
esac

echo "DRIFT_REVISIONS=$CURRENT"
if [ "$CURRENT" -ge "$MAX_DRIFT_REVISIONS" ]; then
  echo "MAX_DRIFT_REVISIONS_EXCEEDED=true"
else
  echo "MAX_DRIFT_REVISIONS_EXCEEDED=false"
fi

# Increment
TMPFILE=$(mktemp)
echo "$((CURRENT + 1))" > "$TMPFILE"
mv "$TMPFILE" "$STATE_FILE"

flock -u 200
