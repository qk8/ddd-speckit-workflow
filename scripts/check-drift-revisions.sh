#!/usr/bin/env bash
# Track drift fix revisions per retro cycle.
# Usage: check-drift-revisions.sh <feature_dir> [--json] [--help]
#
# Outputs:
#   DRIFT_REVISIONS=N
#   MAX_DRIFT_REVISIONS_EXCEEDED=true|false
#
# Resets on each retro cycle (cleared when retro_trigger fires).

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"
source "$SCRIPTS_DIR/revision-limits.sh"

# ── Parse flags ────────────────────────────────────────────────────
JSON_MODE=false
if [ "${1:-}" = "--json" ]; then
  JSON_MODE=true
  shift
fi
if [ "${1:-}" = "--help" ]; then
  check_help "check-drift-revisions.sh" "<feature_dir> [--json] [--help]"
fi

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(check_find_feature_dir "" || true)
fi
FEATURE_DIR="${FEATURE_DIR:-}"

if [ -z "$FEATURE_DIR" ]; then
  echo "DRIFT_REVISIONS=0"
  echo "MAX_DRIFT_REVISIONS_EXCEEDED=false"
  exit 0
fi

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

# ── Write .result file ─────────────────────────────────────────────
if [ "$CURRENT" -ge "$MAX_DRIFT_REVISIONS" ]; then
  check_write_result "$FEATURE_DIR" "drift_revisions" "FAIL"
else
  check_write_result "$FEATURE_DIR" "drift_revisions" "PASS"
fi
exit 0
