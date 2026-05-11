#!/usr/bin/env bash
# Track files created/modified during implementation.
# Called by speckit.implement-code after each task implementation.
#
# Usage:
#   track-created-files.sh <feature_dir> <task_id> <file1> [file2] ...
#   track-created-files.sh -H <feature_dir> <task_id> <file1> [file2] ...  (with hashes)
#
# Writes:
#   .artifacts/created-files/<task_id>.files (one path per line)
#   .artifacts/created-files/<task_id>.files.hashes (sha256 per line, if -H flag)

set -euo pipefail

TRACK_HASHES=false
if [ "${1:-}" = "-H" ]; then
  TRACK_HASHES=true
  shift
fi

FEATURE_DIR="${1:?Usage: track-created-files.sh [-H] <feature_dir> <task_id> [files...]}"
TASK_ID="${2:?}"
shift 2

TRACKING_DIR="$FEATURE_DIR/.artifacts/created-files"
mkdir -p "$TRACKING_DIR"

# Clear old tracking file for this task
> "$TRACKING_DIR/${TASK_ID}.files"
> "$TRACKING_DIR/${TASK_ID}.files.hashes"

FILES_JSON=""
for f in "$@"; do
  echo "$f" >> "$TRACKING_DIR/${TASK_ID}.files"
  if [ "$TRACK_HASHES" = true ]; then
    if [ -f "$f" ]; then
      hash_val=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1 || echo "unreadable")
      echo "${f}:${hash_val}" >> "$TRACKING_DIR/${TASK_ID}.files.hashes"
    fi
  fi
  # Build JSON array for state.json
  if [ -n "$FILES_JSON" ]; then
    FILES_JSON="${FILES_JSON}, \"$f\""
  else
    FILES_JSON="\"$f\""
  fi
done

# ── Fast path: update state.json ──
if [ -f "$FEATURE_DIR/state.json" ]; then
  bash scripts/state-engine.sh write "$FEATURE_DIR" "tasks.$TASK_ID.files_modified" "[$FILES_JSON]" >/dev/null 2>&1 || true
fi

echo "Tracked ${#@} files for $TASK_ID"
