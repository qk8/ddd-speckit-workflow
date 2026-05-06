#!/usr/bin/env bash
# Creates a timestamped backup of tasks.md for recovery.
# Usage: backup-tasks.sh <feature_dir> [label]
# Backups stored at: .artifacts/tasks-backups/<label>-tasks.md.bak

set -euo pipefail

FEATURE_DIR="${1:?}"
LABEL="${2:-default}"
TASKS_FILE="$FEATURE_DIR/tasks.md"
BACKUP_DIR="$FEATURE_DIR/.artifacts/tasks-backups"

if [ ! -f "$TASKS_FILE" ]; then
  echo "SKIP: tasks.md not found"
  exit 0
fi

mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M" 2>/dev/null || date +"%Y%m%dT%H%M")
BACKUP_FILE="$BACKUP_DIR/${LABEL}-${TIMESTAMP}-tasks.md.bak"
cp "$TASKS_FILE" "$BACKUP_FILE"
echo "BACKUP_CREATED=$BACKUP_FILE"
