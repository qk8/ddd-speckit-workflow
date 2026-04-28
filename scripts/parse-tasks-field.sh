#!/usr/bin/env bash
# Usage: bash scripts/parse-tasks-field.sh <tasks_file> <field_name>
# Extracts lines matching "field_name:" from DONE tasks in tasks.md.
# Output: "## TASK-N | field_name: value" per match.
#
# Used by: speckit.retrospect.md (Perf warning, Rollback note)

TASKS_FILE="${1:?Usage: bash scripts/parse-tasks-field.sh <tasks_file> <field_name>}"
FIELD="${2:?Usage: bash scripts/parse-tasks-field.sh <tasks_file> <field_name>}"

awk -v field="$FIELD" '
  /^## TASK-/ { task_header = $0; header = 1; found = 0 }
  /^Status: DONE/ { found = 1 }
  header && found && $0 ~ "^"field":" {
    val = $0; sub(/^[^:]*: */, "", val)
    print task_header " | " field ": " val
  }
  /^###/ { header = 0 }
' "$TASKS_FILE"
