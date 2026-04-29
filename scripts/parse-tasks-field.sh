#!/usr/bin/env bash
# Usage: bash scripts/parse-tasks-field.sh <tasks_file> <field_name>
# Extracts lines matching "field_name:" from DONE tasks in tasks.md.
# Output: "## TASK-N | field_name: value" per match.
#
# Used by: speckit.retrospect.md (Perf warning, Rollback note)

TASKS_FILE="${1:?Usage: bash scripts/parse-tasks-field.sh <tasks_file> <field_name>}"
FIELD="${2:?Usage: bash scripts/parse-tasks-field.sh <tasks_file> <field_name>}"

awk -v field="$FIELD" '
  BEGIN {
    # Escape regex metacharacters in field name
    # Order matters: backslash first, then others
    escaped = field
    gsub(/\\/, "\\\\", escaped)   # backslash first
    gsub(/\./, "\\.", escaped)    # dot
    gsub(/\*/, "\\*", escaped)    # star
    gsub(/\+/, "\\+", escaped)    # plus
    gsub(/\?/, "\\?", escaped)    # question
    gsub(/\(/, "\\(", escaped)    # open paren
    gsub(/\)/, "\\)", escaped)    # close paren
    gsub(/\{/, "\\{", escaped)    # open brace
    gsub(/\}/, "\\}", escaped)    # close brace
    gsub(/\^/, "\\^", escaped)    # caret
    gsub(/\$/, "\\$", escaped)    # dollar
    gsub(/\[/, "\\[", escaped)    # open bracket
    gsub(/\]/, "\\]", escaped)    # close bracket
  }
  /^## TASK-/ { task_header = $0; header = 1; found = 0 }
  /^Status: DONE/ { found = 1 }
  header && found && $0 ~ "^"escaped":" {
    val = $0; sub(/^[^:]*: */, "", val)
    print task_header " | " field ": " val
  }
  /^###/ { header = 0 }
' "$TASKS_FILE"
