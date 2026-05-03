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

JSON_MODE=false
if [ "${1:-}" = "--json" ]; then
  JSON_MODE=true
fi

FEATURE_DIR="${FEATURE_DIR:-$(bash scripts/find-first-feature.sh)}"

# Handle --batch-plan early (before validation checks)
# Uses a flag to skip validation and jump to batch plan computation at the end
if [ "${1:-}" = "--batch-plan" ]; then
  if [ -z "$FEATURE_DIR" ] || [ ! -f "$FEATURE_DIR/tasks.md" ]; then
    echo '{"levels":[]}'
    exit 0
  fi
  # Set flag so validation is skipped and batch plan runs at end
  SKIP_VALIDATION=1
fi

if [ -z "$FEATURE_DIR" ] || [ ! -f "$FEATURE_DIR/tasks.md" ]; then
  if [ "$JSON_MODE" = true ]; then
    echo "{"
    echo '  "valid": true,'
    echo '  "errors": 0,'
    echo '  "warnings": 0,'
    echo '  "task_count": 0,'
    echo '  "circular_deps": [],'
    echo '  "missing_refs": [],'
    echo '  "ordering_warnings": []'
    echo "}"
  else
    echo "No tasks.md found. Nothing to validate."
  fi
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
MISSING_REFS_FILE="$TMP_DIR/missing_refs.txt"
CIRCULAR_DEPS_FILE="$TMP_DIR/circular_deps.txt"
ORDERING_WARNINGS_FILE="$TMP_DIR/ordering_warnings.txt"
touch "$TASK_IDS_FILE" "$TASK_DEPS_FILE" "$VISIT_STATE_FILE" "$ORDERED_FILE"
touch "$MISSING_REFS_FILE" "$CIRCULAR_DEPS_FILE" "$ORDERING_WARNINGS_FILE"

VISIT_UNVISITED=0
VISIT_IN_PROGRESS=1
VISIT_DONE=2

# ── Batch Plan: compute dependency levels for parallel task batching ──
# Usage: ./scripts/validate-tasks.sh --batch-plan
# Outputs JSON with dependency levels for parallel batch processing.
# Level 0 = no dependencies (or all deps DONE)
# Level 1 = depends only on level 0 tasks
# Level N = depends only on levels < N
compute_batch_plan() {
  local tasks_file="${FEATURE_DIR:-.}/tasks.md"
  if [ ! -f "$tasks_file" ]; then
    echo '{"levels":[]}'
    return
  fi

  local btmp
  btmp=$(mktemp -d)

  local ids_file="$btmp/ids.txt"
  local deps_file="$btmp/deps.txt"
  touch "$ids_file" "$deps_file"

  # Parse tasks (same logic as main script, self-contained)
  local current_id=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^##\ TASK-\[?([0-9]+)\]? ]]; then
      current_id="${BASH_REMATCH[1]}"
      echo "$current_id" >> "$ids_file"
      echo "${current_id}|none" >> "$deps_file"
    elif [[ "$line" =~ ^Depends\ on:\ (.*) ]] && [ -n "${current_id:-}" ]; then
      local deps="${BASH_REMATCH[1]}"
      local normalized=""
      IFS=',' read -ra dep_list <<< "$deps"
      for dep in "${dep_list[@]}"; do
        dep=$(echo "$dep" | xargs)
        local norm_dep=$(echo "$dep" | sed 's/^TASK-\[//;s/\]$//;s/^TASK-//')
        if [ -n "$normalized" ]; then
          normalized="$normalized, $norm_dep"
        else
          normalized="$norm_dep"
        fi
      done
      {
        awk -F'|' -v id="$current_id" '$1 != id' "$deps_file" || true
        echo "${current_id}|${normalized}"
      } > "$btmp/deps_tmp"
      mv "$btmp/deps_tmp" "$deps_file"
    fi
  done < "$tasks_file"

  local task_count
  task_count=$(wc -l < "$ids_file" | xargs)
  if [ "$task_count" -eq 0 ]; then
    echo '{"levels":[]}'
    return
  fi

  # BFS-based level computation
  local levels_file="$btmp/levels.txt"
  while IFS= read -r tid; do
    echo "${tid}|0" >> "$levels_file"
  done < "$ids_file"

  local changed=true
  local iterations=0
  local max_iterations=$((task_count + 1))

  while [ "$changed" = true ] && [ "$iterations" -lt "$max_iterations" ]; do
    changed=false
    iterations=$((iterations + 1))

    while IFS='|' read -r task_id deps; do
      if [ "$deps" = "none" ]; then
        continue
      fi
      IFS=',' read -ra dep_list <<< "$deps"
      local max_dep_level=0
      for dep in "${dep_list[@]}"; do
        dep=$(echo "$dep" | xargs)
        local dep_level
        dep_level=$(awk -F'|' -v id="$dep" '$1 == id {print $2; exit}' "$levels_file")
        dep_level=${dep_level:-0}
        if [ "$dep_level" -ge "$max_dep_level" ]; then
          max_dep_level=$((dep_level + 1))
        fi
      done
      local current_level
      current_level=$(awk -F'|' -v id="$task_id" '$1 == id {print $2; exit}' "$levels_file")
      current_level=${current_level:-0}
      if [ "$max_dep_level" -gt "$current_level" ]; then
        {
          awk -F'|' -v id="$task_id" '$1 != id' "$levels_file" || true
          echo "${task_id}|${max_dep_level}"
        } > "$btmp/levels_tmp"
        mv "$btmp/levels_tmp" "$levels_file"
        changed=true
      fi
    done < "$deps_file"
  done

  # Output JSON
  echo "{"
  echo '  "levels": ['
  local current_level=-1
  local first_level=true
  sort -t'|' -k2,2n -k1,1n "$levels_file" > "$btmp/sorted_levels.txt"

  while IFS='|' read -r tid level; do
    if [ "$level" -ne "$current_level" ]; then
      if [ "$current_level" -ge 0 ]; then
        echo ']'
      fi
      if [ "$first_level" = false ]; then
        echo '    ],'
      fi
      echo "    \"level_${level}\": ["
      first_level=false
      current_level=$level
      first_item=true
    else
      if [ "$first_item" = false ]; then
        echo ","
      fi
      printf '      "TASK-%s"' "$tid"
      first_item=false
    fi
  done < "$btmp/sorted_levels.txt"

  if [ "$current_level" -ge 0 ]; then
    echo ""
    echo '    ]'
  fi
  echo '  ]'
  echo "}"
}

# Validation runs unless --batch-plan was used (batch plan has its own parsing)
if [ "${SKIP_VALIDATION:-}" != "1" ]; then
echo "━━━ Task Dependency Graph Validation ━━━"
echo ""

# ── Parse tasks ──────────────────────────────────────────────────
# Extracts: TASK_ID, DEPENDS_ON from tasks.md
# Writes to temp files: task_ids.txt (one per line), task_deps.txt (ID|DEPS)

current_id=""
while IFS= read -r line; do
  if [[ "$line" =~ ^##\ TASK-(\[\]?[0-9]+\]?) ]]; then
    # Strip brackets: TASK-[3] → 3, TASK-3 → 3
    current_id="${BASH_REMATCH[1]}"
    current_id="${current_id#\[}"
    current_id="${current_id%\]}"
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
      awk -F'|' -v id="$current_id" '$1 != id' "$TASK_DEPS_FILE" || true
      echo "${current_id}|${normalized}"
    } > "$TMP_DIR/deps_tmp"
    mv "$TMP_DIR/deps_tmp" "$TASK_DEPS_FILE"
  fi
done < "$TASKS_FILE"

task_count=$(wc -l < "$TASK_IDS_FILE" | xargs)

if [ "$task_count" -eq 0 ]; then
  if [ "$JSON_MODE" = true ]; then
    echo "{"
    echo '  "valid": true,'
    echo '  "errors": 0,'
    echo '  "warnings": 0,'
    echo '  "task_count": 0,'
    echo '  "circular_deps": [],'
    echo '  "missing_refs": [],'
    echo '  "ordering_warnings": []'
    echo "}"
  else
    echo "No tasks found in $TASKS_FILE."
  fi
  exit 0
fi

echo "Parsed $task_count tasks."
echo ""

# ── Helper: look up deps for a task ID ──────────────────────────
get_deps() {
  awk -F'|' -v id="$1" '$1 == id {print $2; exit}' "$TASK_DEPS_FILE"
}

# ── Helper: look up visit state for a task ID ───────────────────
get_state() {
  local state
  state=$(awk -F'|' -v id="$1" '$1 == id {print $2; exit}' "$VISIT_STATE_FILE")
  echo "${state:-$VISIT_UNVISITED}"
}

# ── Helper: set visit state for a task ID ───────────────────────
set_state() {
  if grep -q "^${1}|" "$VISIT_STATE_FILE" 2>/dev/null; then
    {
      awk -F'|' -v id="$1" '$1 != id' "$VISIT_STATE_FILE" || true
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
      # Collect for JSON
      echo "\"$task_id -> $dep\"" >> "$MISSING_REFS_FILE"
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
        head -n -1 "$stack_file" > "${stack_file}.tmp" && mv "${stack_file}.tmp" "$stack_file"
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
        head -n -1 "$stack_file" > "${stack_file}.tmp" && mv "${stack_file}.tmp" "$stack_file"
        echo "${current_node}|${new_idx}" >> "$stack_file"

        local dep_state
        dep_state=$(get_state "$dep")
        if [ "$dep_state" -eq "$VISIT_IN_PROGRESS" ]; then
          echo "  ERROR: Circular dependency detected: TASK-$current_node -> TASK-$dep -> ... -> TASK-$current_node"
          ERRORS=$((ERRORS + 1))
          # Collect for JSON
          echo "\"TASK-$current_node -> TASK-$dep\"" >> "$CIRCULAR_DEPS_FILE"
        elif [ "$dep_state" -eq "$VISIT_UNVISITED" ]; then
          # Mark IN_PROGRESS before pushing (simulates recursive call entry)
          set_state "$dep" "$VISIT_IN_PROGRESS"
          echo "${dep}|0" >> "$stack_file"
        fi
      fi

      if [ "$has_more_deps" = false ]; then
        # All deps processed: mark done and pop (simulates recursive call exit)
        set_state "$current_node" "$VISIT_DONE"
        head -n -1 "$stack_file" > "${stack_file}.tmp" && mv "${stack_file}.tmp" "$stack_file"
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
  if [[ "$line" =~ ^##\ TASK-(\[\]?[0-9]+\]?) ]]; then
    # Strip brackets: TASK-[3] → 3, TASK-3 → 3
    _tid="${BASH_REMATCH[1]}"
    _tid="${_tid#\[}"
    _tid="${_tid%\]}"
    ORDERED_IDS+=("$_tid")
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
      # Collect for JSON
      echo "\"TASK-$task_id depends on TASK-$dep (ordering)\"" >> "$ORDERING_WARNINGS_FILE"
    fi
  done
done

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo "  Task ordering is correct."
fi
echo ""

# ── Check 4: Parallel batch conflict detection ──────────────────
echo "Check 4: Parallel batch conflicts"

# Extract file paths from acceptance criteria for each task
TASK_FILES_FILE="$TMP_DIR/task_files.txt"
touch "$TASK_FILES_FILE"

current_id=""
while IFS= read -r line; do
  if [[ "$line" =~ ^##\ TASK-(\[\]?[0-9]+\]?) ]]; then
    current_id="${BASH_REMATCH[1]}"
    current_id="${current_id#\[}"
    current_id="${current_id%\]}"
  fi
  if [ -n "$current_id" ] && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[.*\] ]]; then
    # Extract file paths from acceptance criterion
    echo "$line" | grep -oE '[a-zA-Z0-9_/.-]+\.(java|ts|js|py|kt|scala|go|rb|php|sql|yaml|yml|json|toml|xml|md|html|css|scss)' 2>/dev/null | while read -r fpath; do
      echo "${current_id}|${fpath}"
    done >> "$TASK_FILES_FILE" || true
  fi
done < "$TASKS_FILE"

# Compute batch levels and check for file overlaps within each level
OVERLAP_FILE="$TMP_DIR/overlaps.txt"
touch "$OVERLAP_FILE"

# For each pair of tasks at the same dependency level, check file overlap
# We use the task file list to detect potential conflicts
awk -F'|' '{print $1}' "$TASK_FILES_FILE" | sort -u | while read -r tid; do
  # Get all files for this task
  grep "^${tid}|" "$TASK_FILES_FILE" | cut -d'|' -f2 | sort -u > "$TMP_DIR/files_${tid}.txt"
done

# Check all pairs of tasks for file overlap
task_ids=()
while IFS= read -r line; do
  if [[ "$line" =~ ^##\ TASK-(\[\]?[0-9]+\]?) ]]; then
    tid="${BASH_REMATCH[1]}"
    tid="${tid#\[}"
    tid="${tid%\]}"
    task_ids+=("$tid")
  fi
done < "$TASKS_FILE"

for ((i=0; i<${#task_ids[@]}; i++)); do
  for ((j=i+1; j<${#task_ids[@]}; j++)); do
    tid_a="${task_ids[$i]}"
    tid_b="${task_ids[$j]}"
    # Check if both tasks reference the same file
    overlap=$(comm -12 \
      <(grep "^${tid_a}|" "$TASK_FILES_FILE" 2>/dev/null | cut -d'|' -f2 | sort -u) \
      <(grep "^${tid_b}|" "$TASK_FILES_FILE" 2>/dev/null | cut -d'|' -f2 | sort -u) 2>/dev/null || true)
    if [ -n "$overlap" ]; then
      echo "  WARNING: TASK-$tid_a and TASK-$tid_b both reference: $overlap"
      WARNINGS=$((WARNINGS + 1))
      echo "\"TASK-$tid_a <-> TASK-$tid_b: $overlap\"" >> "$OVERLAP_FILE"
    fi
  done
done

if [ "$WARNINGS" -eq 0 ] && [ ! -s "$OVERLAP_FILE" ]; then
  echo "  No parallel batch conflicts detected."
fi

fi  # end SKIP_VALIDATION guard

# Handle --batch-plan flag (always runs, even when SKIP_VALIDATION=1)
if [ "${1:-}" = "--batch-plan" ]; then
  compute_batch_plan
  exit 0
fi

# ── JSON output (when --json flag is used) ──────────────────────
if [ "$JSON_MODE" = true ]; then
  # Determine validity
  if [ "$ERRORS" -eq 0 ]; then
    _valid="true"
  else
    _valid="false"
  fi

  # Build arrays from temp files (bash 3.2 compatible)
  build_json_array() {
    local file="$1"
    if [ ! -s "$file" ]; then
      echo "[]"
      return
    fi
    echo -n "["
    local first=true
    while IFS= read -r line; do
      if [ "$first" = true ]; then
        echo -n "$line"
        first=false
      else
        echo -n ", $line"
      fi
    done < "$file"
    echo -n "]"
  }

  _circular=$(build_json_array "$CIRCULAR_DEPS_FILE")
  _missing=$(build_json_array "$MISSING_REFS_FILE")
  _ordering=$(build_json_array "$ORDERING_WARNINGS_FILE")

  echo "{"
  echo "  \"valid\": $_valid,"
  echo "  \"errors\": $ERRORS,"
  echo "  \"warnings\": $WARNINGS,"
  echo "  \"task_count\": $task_count,"
  echo "  \"circular_deps\": $_circular,"
  echo "  \"missing_refs\": $_missing,"
  echo "  \"ordering_warnings\": $_ordering"
  echo "}"
fi

# ── Summary ──────────────────────────────────────────────────────
source scripts/print-result.sh \
  "Issues found: $ERRORS error(s), $WARNINGS warning(s)." \
  "FIX the errors before starting implementation." \
  "$WARNINGS warning(s). Consider reordering tasks for clarity." \
  "All checks passed. $ERRORS errors, $WARNINGS warnings."
