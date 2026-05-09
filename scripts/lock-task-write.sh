#!/usr/bin/env bash
# Wrapper around set-task-status.sh that acquires flock before writing.
# Prevents concurrent session corruption of tasks.md.
#
# Usage:
#   bash scripts/lock-task-write.sh <tasks_file> <new_status> [task_id] [message]
#   bash scripts/lock-task-write.sh <tasks_file> <new_status> --cascade <task_id> [message]
#
# Wraps set-task-status.sh with file-lock.sh to prevent concurrent access.
#
# Exit codes:
#   0 = command succeeded
#   1 = lock acquisition failed (another process holds the lock)
#   2 = command failed

set -euo pipefail

TASKS_FILE="${1:?Usage: lock-task-write.sh <tasks_file> <new_status> [options...]}"
LOCK_FILE="$(dirname "$TASKS_FILE")/.artifacts/tasks.lock"
mkdir -p "$(dirname "$LOCK_FILE")"

exec bash scripts/file-lock.sh "$LOCK_FILE" \
  bash scripts/set-task-status.sh "$@"
