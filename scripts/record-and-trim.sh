#!/usr/bin/env bash
# Atomic trim + record: trim revision history then record new entry.
# Both operations succeed or the script fails before either completes.
# Replaces the (trim-revision.sh, record-phase-revision.sh) pair.
#
# Usage: record-and-trim.sh <step_id> <iteration> [max_entries]

set -euo pipefail

STEP_ID="${1:?Usage: record-and-trim.sh <step_id> <iteration> [max_entries]}"
ITERATION="${2:?}"
MAX="${3:-3}"

# Step 1: Trim first (fail fast if this fails)
TMPFILE=$(mktemp)
if ! bash scripts/trim-revision.sh --max "$MAX" > "$TMPFILE" 2>&1; then
  echo "ERROR: trim failed — revision history may be unbounded" >&2
  exit 1
fi
TRIM_OUTPUT=$(cat "$TMPFILE")
rm -f "$TMPFILE"

# Step 2: Record second (if trim succeeded)
bash scripts/record-phase-revision.sh "$STEP_ID" "$ITERATION"

echo "$TRIM_OUTPUT"
