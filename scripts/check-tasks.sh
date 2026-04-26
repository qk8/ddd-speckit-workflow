#!/usr/bin/env bash
# Usage: ./scripts/check-tasks.sh
# Outputs shell variables for ddd-workflow.yml:
#   has_todo, done_count, todo_count, in_progress, abandoned_count

set -euo pipefail

FEATURE_DIR=$(bash scripts/find-first-feature.sh)

# Read cadence defaults from preset.yml (single source of truth)
PRESET_FILE="ddd-clean-arch/preset.yml"
DEFAULT_RETRO_INTERVAL=10
DEFAULT_FIRST_RETRO_THRESHOLD=5
if [ -f "$PRESET_FILE" ]; then
  DEFAULT_RETRO_INTERVAL=$(awk '/^  retro_interval:/{found=1} found && /medium:/{print $2; exit}' "$PRESET_FILE" || true)
  [ -z "$DEFAULT_RETRO_INTERVAL" ] && DEFAULT_RETRO_INTERVAL=10
  DEFAULT_FIRST_RETRO_THRESHOLD=$(awk '/^  first_retro_threshold:/{print $2; exit}' "$PRESET_FILE" || true)
  [ -z "$DEFAULT_FIRST_RETRO_THRESHOLD" ] && DEFAULT_FIRST_RETRO_THRESHOLD=5
fi

if [ -z "$FEATURE_DIR" ] || [ ! -f "$FEATURE_DIR/tasks.md" ]; then
  echo "has_todo=false"; echo "done_count=0"; echo "todo_count=0"
  echo "in_progress="; echo "abandoned_count=0"; echo "total_tasks=0"
  echo "complexity=medium"; echo "retro_interval=$DEFAULT_RETRO_INTERVAL"; echo "first_retro_threshold=$DEFAULT_FIRST_RETRO_THRESHOLD"
  echo "retro_trigger=false"
  exit 0
fi

TASKS_FILE="$FEATURE_DIR/tasks.md"
DONE_COUNT=$(grep -c "^Status: DONE$" "$TASKS_FILE" || true)
TODO_COUNT=$(grep -c "^Status: TODO$" "$TASKS_FILE" || true)
IN_PROGRESS=$(grep -B1 "^Status: IN_PROGRESS$" "$TASKS_FILE" 2>/dev/null | grep "^## TASK" | head -1 | sed 's/^## //' || true)
ABANDONED_COUNT=$(grep -c "^Status: ABANDONED$" "$TASKS_FILE" || true)
TOTAL_TASKS=$(grep -c "^## TASK-" "$TASKS_FILE" || true)

if [ -n "$IN_PROGRESS" ]; then
  echo "WARNING: Status: IN_PROGRESS found — previous session interrupted." >&2
  echo "  Task: $IN_PROGRESS" >&2
  echo "  Mark it TODO to restart, or ABANDONED to discard partial work." >&2
fi

if [ "$ABANDONED_COUNT" -gt 0 ]; then
  echo "WARNING: $ABANDONED_COUNT ABANDONED task(s) — review and clean up partial files." >&2
fi

if [ "$TODO_COUNT" -gt 0 ] || [ -n "$IN_PROGRESS" ]; then
  HAS_TODO="true"
else
  HAS_TODO="false"
fi

# Adaptive retrospective cadence based on total task count and complexity
# Complexity is read from project-brief.md; defaults to "medium"
# project-brief.md format: "## Complexity" header followed by value on next line
COMPLEXITY="medium"
if [ -f "project-brief.md" ]; then
  COMPLEXITY=$(awk '/^## Complexity/{found=1; next} found && /^[^ ]/{print tolower($1); exit}' project-brief.md)
  case "$COMPLEXITY" in
    simple|medium|complex) ;; # valid
    *) COMPLEXITY="medium" ;;
  esac
fi

# Determine retrospective interval based on complexity — read from preset.yml
RETRO_INTERVAL="$DEFAULT_RETRO_INTERVAL"
case "$COMPLEXITY" in
  simple)
    PRESET_SIMPLE=$(awk '/^  retro_interval:/{found=1} found && /simple:/{print $2; exit}' "$PRESET_FILE")
    [ -n "$PRESET_SIMPLE" ] && RETRO_INTERVAL="$PRESET_SIMPLE"
    ;;
  complex)
    PRESET_COMPLEX=$(awk '/^  retro_interval:/{found=1} found && /complex:/{print $2; exit}' "$PRESET_FILE")
    [ -n "$PRESET_COMPLEX" ] && RETRO_INTERVAL="$PRESET_COMPLEX"
    ;;
esac

# First retrospective threshold — read from preset.yml
FIRST_RETRO_THRESHOLD="$DEFAULT_FIRST_RETRO_THRESHOLD"

# Determine if retrospective should trigger
# Triggers at first_retro_threshold, then every retro_interval tasks thereafter
RETRO_TRIGGER=false
if [ "$DONE_COUNT" -ge "$FIRST_RETRO_THRESHOLD" ]; then
  if [ "$DONE_COUNT" -eq "$FIRST_RETRO_THRESHOLD" ]; then
    RETRO_TRIGGER=true
  elif [ $(( DONE_COUNT % RETRO_INTERVAL )) -eq 0 ]; then
    RETRO_TRIGGER=true
  fi
fi

echo "has_todo=$HAS_TODO"
echo "done_count=$DONE_COUNT"
echo "todo_count=$TODO_COUNT"
echo "in_progress=$IN_PROGRESS"
echo "abandoned_count=$ABANDONED_COUNT"
echo "total_tasks=$TOTAL_TASKS"
echo "complexity=$COMPLEXITY"
echo "retro_interval=$RETRO_INTERVAL"
echo "first_retro_threshold=$FIRST_RETRO_THRESHOLD"
echo "retro_trigger=$RETRO_TRIGGER"
echo "feature_dir=$FEATURE_DIR"
