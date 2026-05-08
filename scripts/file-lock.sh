#!/usr/bin/env bash
# file-lock.sh — flock-based file locking utility
#
# Usage:
#   bash scripts/file-lock.sh <lock_file> <command...>
#
# Wraps a command in flock to prevent concurrent access to shared files.
# This is used to prevent tasks.md corruption when multiple Claude Code
# instances run against the same project simultaneously.
#
# Issue G: Prevents concurrent session corruption of tasks.md and other
# shared workflow state files.
#
# Example:
#   bash scripts/file-lock.sh .artifacts/tasks.lock \
#     bash scripts/set-task-status.sh tasks.md IN_PROGRESS TASK-3 "message"
#
# Exit codes:
#   0 = command succeeded
#   1 = lock acquisition failed (another process holds the lock)
#   2 = command failed

set -euo pipefail

LOCK_FILE="${1:?Usage: file-lock.sh <lock_file> <command...>}"
shift

# Create lock directory if needed
LOCK_DIR=$(dirname "$LOCK_FILE")
mkdir -p "$LOCK_DIR"

# Create the lock file
touch "$LOCK_FILE"

# Use flock with file descriptor 200
# Timeout after 60 seconds to avoid infinite waits
exec 200>"$LOCK_FILE"
if ! flock -w 60 200; then
  echo "LOCK: Could not acquire lock $(basename "$LOCK_FILE") within 60s" >&2
  echo "Another process may be holding the lock." >&2
  exit 1
fi

# Lock acquired — run the command
# The lock is released when the script exits (fd 200 is closed)
set -e
"$@"
EXIT_CODE=$?

# Release lock (automatic on exit, but explicit for clarity)
flock -u 200

exit $EXIT_CODE
