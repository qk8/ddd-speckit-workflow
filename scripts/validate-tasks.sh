#!/usr/bin/env bash
# Usage: ./scripts/validate-tasks.sh
# Validates the task dependency graph in tasks.md before implementation starts.
# Exits 0 if valid, 1 if issues found.
#
# Checks:
#   1. Circular dependencies (topological sort)
#   2. All Depends-on references point to existing tasks
#   3. Task ordering: depends-on tasks appear before dependent tasks
#
# Bash 3.2-compatible: no associative arrays (declare -A).
# Uses temp files with delimiters instead.

set -euo pipefail

FEATURE_DIR="${FEATURE_DIR:-$(bash scripts/find-first-feature.sh)}"

if [ -z "$FEATURE_DIR" ] || [ ! -f "$FEATURE_DIR/tasks.md" ]; then
  echo "No tasks.md found. Nothing to validate."
  exit 0
fi

TASKS_FILE="$FEATURE_DIR/tasks.md"
ERRORS=0
WARNINGS=0

# Temp files for bash 3.2 compatibility (no declare -A)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
TASK_IDS_FILE="$TMP_DIR/task_ids.txt"
TASK_DEPS_FILE="$TMP_DIR/task_deps.txt"
VISIT_STATE_FILE="$TMP_DIR/visit_state.txt"
ORDERED_FILE="$TMP_DIR/ordered_ids.txt"
touch "$TASK_IDS_FILE" "$TASK_DEPS_FILE" "$VISIT_STATE_FILE" "$ORDERED_FILE"

VISIT_UNVISITED=0
VISIT_IN_PROGRESS=1
VISIT_DONE=2

echo "━━━ Task Dependency Graph Validation ━━━"
echo ""

# ── Parse tasks ──────────────────────────────────────────────────
# Extracts: TASK_ID, DEPENDS_ON from tasks.md
# Writes to temp files: task_ids.txt (one per line), task_deps.txt (ID|DEPS)

current_id=""
while IFS= read -r line; do
  if [[ "$line" =~ ^##\ TASK-\[([0-9]+)\] ]]; then
    current_id="${BASH_REMATCH[1]}"
    echo "$current_id" >> "$TASK_IDS_FILE"
    echo "${current_id}|none" >> "$TASK_DEPS_FILE"
  elif [[ "$line" =~ ^Depends\ on:\ (.*) ]] && [ -n "${current_id:-}" ]; then
    deps="${BASH_REMATCH[1]}"
    normalized=""
    IFS=',' read -ra dep_list <<< "$deps"
    for dep in "${dep_list[@]}"; do
      dep=$(echo "$dep" | xargs)  # trim
      # Convert "TASK-[3]" or "TASK-3" → "3"
      norm_dep=$(echo "$dep" | sed 's/^TASK-\[//;s/\]$//;s/^TASK-//')
      if [ -n "$normalized" ]; then
        normalized="$normalized, $norm_dep"
      else
        normalized="$norm_dep"
      fi
    done
    # Update last line in task_deps_file for current_id (portable, no sed -i)
    {
      grep -v "^${current_id}|" "$TASK_DEPS_FILE" || true
      echo "${current_id}|${normalized}"
    } > "$TMP_DIR/deps_tmp"
    mv "$TMP_DIR/deps_tmp" "$TASK_DEPS_FILE"
  fi
done < "$TASKS_FILE"

task_count=$(wc -l < "$TASK_IDS_FILE" | xargs)

if [ "$task_count" -eq 0 ]; then
  echo "No tasks found in $TASKS_FILE."
  exit 0
fi

echo "Parsed $task_count tasks."
echo ""

# ── Helper: look up deps for a task ID ──────────────────────────
get_deps() {
  grep "^${1}|" "$TASK_DEPS_FILE" | head -1 | cut -d'|' -f2-
}

# ── Helper: look up visit state for a task ID ───────────────────
get_state() {
  local state
  state=$(grep "^${1}|" "$VISIT_STATE_FILE" | head -1 | cut -d'|' -f2-)
  echo "${state:-$VISIT_UNVISITED}"
}

# ── Helper: set visit state for a task ID ───────────────────────
set_state() {
  if grep -q "^${1}|" "$VISIT_STATE_FILE" 2>/dev/null; then
    {
      grep -v "^${1}|" "$VISIT_STATE_FILE" || true
      echo "${1}|${2}"
    } > "$TMP_DIR/state_tmp"
    mv "$TMP_DIR/state_tmp" "$VISIT_STATE_FILE"
  else
    echo "${1}|${2}" >> "$VISIT_STATE_FILE"
  fi
}

# ── Helper: check if task ID exists ─────────────────────────────
task_exists() {
  grep -qx "$1" "$TASK_IDS_FILE"
}

# ── Check 1: All Depends-on references point to existing tasks ──
echo "Check 1: Dependency references"
while IFS='|' read -r task_id deps; do
  if [ "$deps" = "none" ]; then
    continue
  fi
  IFS=',' read -ra dep_list <<< "$deps"
  for dep in "${dep_list[@]}"; do
    dep=$(echo "$dep" | xargs)  # trim whitespace
    if ! task_exists "$dep"; then
      echo "  ERROR: TASK-$task_id depends on TASK-$dep, but TASK-$dep does not exist."
      ERRORS=$((ERRORS + 1))
    fi
  done
done < "$TASK_DEPS_FILE"
if [ "$ERRORS" -eq 0 ]; then
  echo "  All dependency references point to existing tasks."
fi
echo ""

# ── Check 2: Circular dependencies (DFS-based cycle detection) ──
echo "Check 2: Circular dependencies"

# Initialize all tasks as unvisited
while IFS= read -r tid; do
  set_state "$tid" "$VISIT_UNVISITED"
done < "$TASK_IDS_FILE"

# Iterative DFS cycle detection (bash 3.2 compatible, no recursion).
# Stack format: NODE|DEP_INDEX (one line per active node).
# DEP_INDEX tracks which dependency we're processing so we resume
# correctly after returning from a sub-dependency.
# Nodes are marked IN_PROGRESS when pushed, DONE when popped.
dfs_detect_cycles() {
  local stack_file="$TMP_DIR/dfs_stack.txt"

  while IFS= read -r task_id; do
    if [ "$(get_state "$task_id")" -ne "$VISIT_UNVISITED" ]; then
      continue
    fi

    # Push start node: node|0 (node, processing dependency 0)
    # Mark IN_PROGRESS as soon as we enter (simulates recursive call entry)
    set_state "$task_id" "$VISIT_IN_PROGRESS"
    echo "${task_id}|0" > "$stack_file"

    while [ -s "$stack_file" ]; do
      # Read current node and dependency index from top of stack
      local top_line current_node dep_idx
      top_line=$(tail -1 "$stack_file")
      current_node=$(echo "$top_line" | cut -d'|' -f1)
      dep_idx=$(echo "$top_line" | cut -d'|' -f2)

      # Get deps for current node
      local deps
      deps=$(get_deps "$current_node")
      if [ "$deps" = "none" ]; then
        # No deps: mark done and pop
        set_state "$current_node" "$VISIT_DONE"
        sed -i '$ d' "$stack_file"
        continue
      fi

      IFS=',' read -ra dep_list <<< "$deps"
      local has_more_deps=false

      if [ "$dep_idx" -lt "${#dep_list[@]}" ]; then
        has_more_deps=true
        local dep
        dep=$(echo "${dep_list[$dep_idx]}" | xargs)

        # Update dep_idx for current node on stack
        local new_idx=$((dep_idx + 1))
        sed -i '$ d' "$stack_file"
        echo "${current_node}|${new_idx}" >> "$stack_file"

        local dep_state
        dep_state=$(get_state "$dep")
        if [ "$dep_state" -eq "$VISIT_IN_PROGRESS" ]; then
          echo "  ERROR: Circular dependency detected: TASK-$current_node -> TASK-$dep -> ... -> TASK-$current_node"
          ERRORS=$((ERRORS + 1))
        elif [ "$dep_state" -eq "$VISIT_UNVISITED" ]; then
          # Mark IN_PROGRESS before pushing (simulates recursive call entry)
          set_state "$dep" "$VISIT_IN_PROGRESS"
          echo "${dep}|0" >> "$stack_file"
        fi
      fi

      if [ "$has_more_deps" = false ]; then
        # All deps processed: mark done and pop (simulates recursive call exit)
        set_state "$current_node" "$VISIT_DONE"
        sed -i '$ d' "$stack_file"
      fi
    done
  done < "$TASK_IDS_FILE"
}

dfs_detect_cycles

if [ "$ERRORS" -eq 0 ]; then
  echo "  No circular dependencies detected."
fi
echo ""

# ── Check 3: Task ordering (depends-on tasks must appear before dependent tasks) ──
echo "Check 3: Task ordering"

# Build ordered list of task IDs (in file order) — regular indexed array (bash 3.2 compatible)
ORDERED_IDS=()
while IFS= read -r line; do
  if [[ "$line" =~ ^##\ TASK-\[([0-9]+)\] ]]; then
    ORDERED_IDS+=("${BASH_REMATCH[1]}")
  fi
done < "$TASKS_FILE"

# For each task, check that all its dependencies appear earlier in the file
for ((i=1; i<${#ORDERED_IDS[@]}; i++)); do
  task_id="${ORDERED_IDS[$i]}"
  deps=$(get_deps "$task_id")
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
