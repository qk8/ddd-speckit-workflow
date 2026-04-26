#!/usr/bin/env bash
# Usage: bash scripts/set-task-status.sh <tasks_file> <new_status>
# Sets all IN_PROGRESS tasks in tasks.md to <new_status>.
#
# Used by: ddd-workflow.yml (on_restart → TODO, on_abandon → ABANDONED)

TASKS_FILE="${1:?Usage: bash scripts/set-task-status.sh <tasks_file> <new_status>}"
NEW_STATUS="${2:?Usage: bash scripts/set-task-status.sh <tasks_file> <new_status>}"

sed -i "s/^Status: IN_PROGRESS$/Status: $NEW_STATUS/" "$TASKS_FILE"
