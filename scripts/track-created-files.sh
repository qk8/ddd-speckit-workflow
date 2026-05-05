#!/usr/bin/env bash
# Track files created/modified during implementation.
# Called by speckit.implement-code after each task implementation.
#
# Usage: track-created-files.sh <feature_dir> <task_id> <file1> [file2] ...
#
# Writes: .artifacts/created-files/<task_id>.files (one path per line)

set -euo pipefail

FEATURE_DIR="${1:?Usage: track-created-files.sh <feature_dir> <task_id> [files...]}"
TASK_ID="${2:?}"
shift 2

TRACKING_DIR="$FEATURE_DIR/.artifacts/created-files"
mkdir -p "$TRACKING_DIR"

# Clear old tracking file for this task
> "$TRACKING_DIR/${TASK_ID}.files"

for f in "$@"; do
  echo "$f" >> "$TRACKING_DIR/${TASK_ID}.files"
done

echo "Tracked ${#@} files for $TASK_ID"
