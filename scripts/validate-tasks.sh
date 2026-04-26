#!/usr/bin/env bash
# Usage: ./scripts/validate-tasks.sh
# Validates the task dependency graph in tasks.md before implementation starts.
# Exits 0 if valid, 1 if issues found.
#
# Checks:
#   1. Circular dependencies (topological sort)
#   2. All Depends-on references point to existing tasks
#   3. Task ordering: depends-on tasks appear before dependent tasks

set -euo pipefail

FEATURE_DIR=$(bash scripts/find-first-feature.sh)

if [ -z "$FEATURE_DIR" ] || [ ! -f "$FEATURE_DIR/tasks.md" ]; then
  echo "No tasks.md found. Nothing to validate."
  exit 0
fi

TASKS_FILE="$FEATURE_DIR/tasks.md"
ERRORS=0
WARNINGS=0

echo "━━━ Task Dependency Graph Validation ━━━"
echo ""

# ── Parse tasks ──────────────────────────────────────────────────
# Extracts: TASK_ID, TITLE, DEPENDS_ON from tasks.md
# Format: TASK_ID|TITLE|DEPENDS_ON (comma-separated or "none")
# Dependency format in tasks.md: "TASK-[N]" → normalized to just "N"

declare -A TASK_IDS
declare -A TASK_DEPS

normalize_dep() {
  # Convert "TASK-[3]" or "TASK-3" → "3"
  local dep="$1"
  dep=$(echo "$dep" | sed 's/^TASK-\[//;s/\]$//;s/^TASK-//')
  echo "$dep"
}

while IFS= read -r line; do
  if [[ "$line" =~ ^##\ TASK-\[([0-9]+)\] ]]; then
    current_id="${BASH_REMATCH[1]}"
    TASK_IDS["$current_id"]=1
    TASK_DEPS["$current_id"]="none"
  elif [[ "$line" =~ ^Depends\ on:\ (.*) ]] && [ -n "${current_id:-}" ]; then
    deps="${BASH_REMATCH[1]}"
    normalized=""
    IFS=',' read -ra dep_list <<< "$deps"
    for dep in "${dep_list[@]}"; do
      dep=$(echo "$dep" | xargs)  # trim
      norm_dep=$(normalize_dep "$dep")
      if [ -n "$normalized" ]; then
        normalized="$normalized, $norm_dep"
      else
        normalized="$norm_dep"
      fi
    done
    TASK_DEPS["$current_id"]="$normalized"
  fi
done < "$TASKS_FILE"

if [ ${#TASK_IDS[@]} -eq 0 ]; then
  echo "No tasks found in $TASKS_FILE."
  exit 0
fi

echo "Parsed ${#TASK_IDS[@]} tasks."
echo ""

# ── Check 1: All Depends-on references point to existing tasks ──
echo "Check 1: Dependency references"
for task_id in "${!TASK_DEPS[@]}"; do
  deps="${TASK_DEPS[$task_id]}"
  if [ "$deps" = "none" ]; then
    continue
  fi
  IFS=',' read -ra dep_list <<< "$deps"
  for dep in "${dep_list[@]}"; do
    dep=$(echo "$dep" | xargs)  # trim whitespace
    if [ -z "${TASK_IDS[$dep]+x}" ]; then
      echo "  ERROR: TASK-$task_id depends on TASK-$dep, but TASK-$dep does not exist."
      ERRORS=$((ERRORS + 1))
    fi
  done
done
if [ "$ERRORS" -eq 0 ]; then
  echo "  All dependency references point to existing tasks."
fi
echo ""

# ── Check 2: Circular dependencies (DFS-based cycle detection) ──
echo "Check 2: Circular dependencies"

declare -A VISIT_STATE
# 0 = unvisited, 1 = in progress, 2 = done

for task_id in "${!TASK_IDS[@]}"; do
  VISIT_STATE["$task_id"]=0
done

detect_cycle() {
  local node="$1"
  VISIT_STATE["$node"]=1

  local deps="${TASK_DEPS[$node]:-none}"
  if [ "$deps" != "none" ]; then
    IFS=',' read -ra dep_list <<< "$deps"
    for dep in "${dep_list[@]}"; do
      dep=$(echo "$dep" | xargs)
      local state="${VISIT_STATE[$dep]:-0}"
      if [ "$state" -eq 1 ]; then
        echo "  ERROR: Circular dependency detected: TASK-$node -> TASK-$dep -> ... -> TASK-$node"
        ERRORS=$((ERRORS + 1))
        return 1
      elif [ "$state" -eq 0 ]; then
        detect_cycle "$dep" || true
      fi
    done
  fi

  VISIT_STATE["$node"]=2
  return 0
}

for task_id in "${!TASK_IDS[@]}"; do
  if [ "${VISIT_STATE[$task_id]}" -eq 0 ]; then
    detect_cycle "$task_id" || true
  fi
done

if [ "$ERRORS" -eq 0 ]; then
  echo "  No circular dependencies detected."
fi
echo ""

# ── Check 3: Task ordering (depends-on tasks must appear before dependent tasks) ──
echo "Check 3: Task ordering"

# Build ordered list of task IDs (in file order)
ORDERED_IDS=()
while IFS= read -r line; do
  if [[ "$line" =~ ^##\ TASK-\[([0-9]+)\] ]]; then
    ORDERED_IDS+=("${BASH_REMATCH[1]}")
  fi
done < "$TASKS_FILE"

# For each task, check that all its dependencies appear earlier in the file
for ((i=1; i<${#ORDERED_IDS[@]}; i++)); do
  task_id="${ORDERED_IDS[$i]}"
  deps="${TASK_DEPS[$task_id]:-none}"
  if [ "$deps" = "none" ]; then
    continue
  fi
  IFS=',' read -ra dep_list <<< "$deps"
  for dep in "${dep_list[@]}"; do
    dep=$(echo "$dep" | xargs)
    # Check if dep appears before task_id in the ordered list
    found_before=false
    for ((j=0; j<i; j++)); do
      if [ "${ORDERED_IDS[$j]}" = "$dep" ]; then
        found_before=true
        break
      fi
    done
    if [ "$found_before" = false ]; then
      echo "  WARNING: TASK-$dep should appear before TASK-$task_id in tasks.md."
      echo "           TASK-$task_id depends on TASK-$dep but it appears later in the file."
      WARNINGS=$((WARNINGS + 1))
    fi
  done
done

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo "  Task ordering is correct."
fi
# ── Summary ──────────────────────────────────────────────────────
source scripts/print-result.sh \
  "Issues found: $ERRORS error(s), $WARNINGS warning(s)." \
  "FIX the errors before starting implementation." \
  "$WARNINGS warning(s). Consider reordering tasks for clarity." \
  "All checks passed. $ERRORS errors, $WARNINGS warnings."
