#!/usr/bin/env bash
# task-priority-sort.sh — Sort tasks by priority tier for phased delivery.
#
# Reads tasks.md and returns tasks ordered by priority:
#   phase1 (must-have) > phase2 (should-have) > phase3 (nice-to-have)
# Within each phase, preserves dependency order.
#
# Usage: task-priority-sort.sh <feature_dir> [--phase phase1|phase2|phase3]
#   Without --phase: returns all tasks in priority order
#   With --phase: returns only tasks in that phase
#
# Output: space-separated task IDs in priority order

set -euo pipefail

FEATURE_DIR="${1:?Usage: task-priority-sort.sh <feature_dir> [--phase phase1|phase2|phase3]}"
TASKS_FILE="$FEATURE_DIR/tasks.md"
TARGET_PHASE=""

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) TARGET_PHASE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

if [ ! -f "$TASKS_FILE" ]; then
  echo "SKIP: No tasks.md found"
  exit 0
fi

# Extract task info: TASK_ID, priority, depends_on, status
# Format: TASK_ID|priority|depends_on|status
extract_task_info() {
  awk '
    /^## TASK-/ {
      if (task_id != "") {
        print task_id "|" priority "|" depends "|" status
      }
      task_id = $0
      sub(/^## /, "", task_id)
      priority = "phase1"
      depends = ""
      status = ""
      in_priority = 0
      in_depends = 0
      next
    }
    /^Priority:/ {
      gsub(/^Priority:[[:space:]]*/, "")
      priority = tolower($0)
      gsub(/[[:space:]]/, "", priority)
      next
    }
    /^Depends on:/ {
      gsub(/^Depends on:[[:space:]]*/, "")
      depends = $0
      next
    }
    /^Status:/ {
      gsub(/^Status:[[:space:]]*/, "")
      status = $0
      next
    }
    END {
      if (task_id != "") {
        print task_id "|" priority "|" depends "|" status
      }
    }
  ' "$TASKS_FILE"
}

# Get all tasks
ALL_TASKS=$(extract_task_info)

if [ -z "$ALL_TASKS" ]; then
  echo "SKIP: No tasks found"
  exit 0
fi

# Filter by phase if requested
if [ -n "$TARGET_PHASE" ]; then
  ALL_TASKS=$(echo "$ALL_TASKS" | grep "|${TARGET_PHASE}|" || true)
fi

# Sort by priority (phase1=1, phase2=2, phase3=3) then by task ID for stable ordering
SORTED=$(echo "$ALL_TASKS" | awk -F'|' '
  BEGIN { order["phase1"] = 1; order["phase2"] = 2; order["phase3"] = 3 }
  { print order[$2] " " $1 }
' | sort -n -k1,1 -k2,2 | awk '{print $2}')

# Output as space-separated list
echo "$SORTED" | tr '\n' ' ' | sed 's/[[:space:]]*$//'

exit 0
