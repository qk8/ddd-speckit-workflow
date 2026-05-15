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
    if echo "$line" | grep -qE '^## TASK-\[?[0-9]+\]?' ; then
      current_id=$(echo "$line" | sed 's/^## TASK-\[//;s/\]//g')
      echo "$current_id" >> "$ids_file"
      echo "${current_id}|none" >> "$deps_file"
    elif echo "$line" | grep -qE '^Depends on: ' && [ -n "${current_id:-}" ]; then
      local deps=$(echo "$line" | sed 's/^Depends on: //')
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
  if echo "$line" | grep -qE '^## TASK-\[?[0-9]+\]?' ; then
    # Strip brackets: TASK-[3] → 3, TASK-3 → 3
    current_id=$(echo "$line" | sed 's/^## TASK-\[//;s/\]//g')
    echo "$current_id" >> "$TASK_IDS_FILE"
    echo "${current_id}|none" >> "$TASK_DEPS_FILE"
  elif echo "$line" | grep -qE '^Depends on: ' && [ -n "${current_id:-}" ]; then
    deps=$(echo "$line" | sed 's/^Depends on: //')
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
  if echo "$line" | grep -qE '^## TASK-\[?[0-9]+\]?' ; then
    # Strip brackets: TASK-[3] → 3, TASK-3 → 3
    _tid=$(echo "$line" | sed 's/^## TASK-\[//;s/\]//g')
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
echo "  (I3: Enhanced — checks Scope.Creates, Scope.Modifies, and acceptance criteria)"

# Extract file paths from Scope.Creates, Scope.Modifies, and acceptance criteria for each task
TASK_FILES_FILE="$TMP_DIR/task_files.txt"
touch "$TASK_FILES_FILE"

current_id=""
IN_SCOPE=false
IN_ACCEPTANCE=false
while IFS= read -r line; do
  if echo "$line" | grep -qE '^## TASK-\[?[0-9]+\]?' ; then
    # Reset scope/acceptance tracking on new task
    current_id=$(echo "$line" | sed 's/^## TASK-\[//;s/\]//g')
    IN_SCOPE=false
    IN_ACCEPTANCE=false
  fi

  # Track scope sections
  if echo "$line" | grep -qE '^Scope:'; then
    IN_SCOPE=true
    IN_ACCEPTANCE=false
    continue
  fi
  if [ "$IN_SCOPE" = true ]; then
    if echo "$line" | grep -qE '^  Creates:'; then
      continue
    fi
    if echo "$line" | grep -qE '^  Modifies:'; then
      continue
    fi
    if echo "$line" | grep -qE '^[[:space:]]*-[[:space:]]*'; then
      # Extract file path from "- src/path/to/file.ts"
      fpath=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | xargs)
      if echo "$fpath" | grep -qE '\.(java|ts|js|py|kt|scala|go|rb|php|sql|yaml|yml|json|toml|xml|md|html|css|scss)$'; then
        echo "${current_id}|${fpath}" >> "$TASK_FILES_FILE"
      fi
    fi
    # End of scope section (next top-level field)
    if echo "$line" | grep -qE '^(Acceptance|Do NOT):'; then
      IN_SCOPE=false
    fi
    continue
  fi

  # Track acceptance criteria
  if echo "$line" | grep -qE '^Acceptance criteria:'; then
    IN_ACCEPTANCE=true
    continue
  fi
  if [ "$IN_ACCEPTANCE" = true ]; then
    if echo "$line" | grep -qE '^[[:space:]]*-[[:space:]]*\[.*\]'; then
      # Extract file paths from acceptance criterion
      echo "$line" | grep -oE '[a-zA-Z0-9_/.-]+\.(java|ts|js|py|kt|scala|go|rb|php|sql|yaml|yml|json|toml|xml|md|html|css|scss)' 2>/dev/null | while read -r fpath; do
        echo "${current_id}|${fpath}"
      done >> "$TASK_FILES_FILE" || true
    fi
    # End of acceptance section
    if echo "$line" | grep -qE '^(Do NOT):'; then
      IN_ACCEPTANCE=false
    fi
  fi
done < "$TASKS_FILE"

# Compute dependency levels (same logic as compute_batch_plan, simplified)
LEVELS_FILE="$TMP_DIR/levels_check4.txt"
touch "$LEVELS_FILE"
DEPS_FILE="$TMP_DIR/deps_check4.txt"
touch "$DEPS_FILE"

while IFS= read -r line; do
  if echo "$line" | grep -qE '^## TASK-\[?[0-9]+\]?' ; then
    tid=$(echo "$line" | sed 's/^## TASK-\[//;s/\]//g')
    echo "${tid}|0" >> "$LEVELS_FILE"
  fi
done < "$TASKS_FILE"

# Parse deps from tasks.md
current_id=""
while IFS= read -r line; do
  if echo "$line" | grep -qE '^## TASK-\[?[0-9]+\]?' ; then
    current_id=$(echo "$line" | sed 's/^## TASK-\[//;s/\]//g')
  fi
  if echo "$line" | grep -qE '^Depends on: ' && [ -n "${current_id:-}" ]; then
    echo "${current_id}|$(echo "$line" | sed 's/^Depends on: //')" >> "$DEPS_FILE"
  fi
done < "$TASKS_FILE"

# BFS to compute levels
changed=true
iterations=0
task_count=$(wc -l < "$TASKS_FILE" | xargs)
max_iter=$((task_count + 1))

while [ "$changed" = true ] && [ "$iterations" -lt "$max_iter" ]; do
  changed=false
  iterations=$((iterations + 1))
  while IFS='|' read -r task_id deps; do
    [ "$deps" = "none" ] && continue
    # Normalize deps
    clean_deps=$(echo "$deps" | sed 's/^TASK-\[//;s/\]$//;s/^TASK-//;s/, /\n/g')
    max_dep_level=0
    while IFS= read -r dep; do
      dep=$(echo "$dep" | xargs)
      dep_level=$(awk -F'|' -v id="$dep" '$1 == id {print $2; exit}' "$LEVELS_FILE")
      dep_level=${dep_level:-0}
      new_level=$((dep_level + 1))
      if [ "$new_level" -gt "$max_dep_level" ]; then
        max_dep_level=$new_level
      fi
    done <<< "$clean_deps"
    current_level=$(awk -F'|' -v id="$task_id" '$1 == id {print $2; exit}' "$LEVELS_FILE")
    current_level=${current_level:-0}
    if [ "$max_dep_level" -gt "$current_level" ]; then
      {
        awk -F'|' -v id="$task_id" '$1 != id' "$LEVELS_FILE" || true
        echo "${task_id}|${max_dep_level}"
      } > "$TMP_DIR/levels_tmp"
      mv "$TMP_DIR/levels_tmp" "$LEVELS_FILE"
      changed=true
    fi
  done < "$DEPS_FILE"
done

# Check for file overlaps ONLY within the same dependency level
# I3: Separate Scope overlaps (ERROR) from acceptance criteria overlaps (WARNING)
# Optimized: hash-based duplicate detection instead of O(n²) pairwise comparison.
# Reduces from O(n² * subprocesses) to O(n log n + m log m) where m = total file refs.

OVERLAP_FILE="$TMP_DIR/overlaps.txt"
touch "$OVERLAP_FILE"

# Files extracted from Scope.Creates/Modifies (definite conflict if overlapping)
SCOPE_FILES_FILE="$TMP_DIR/scope_files.txt"
grep -E '\|src/|\|lib/|\|app/|\|packages/|\|tests/' "$TASK_FILES_FILE" > "$SCOPE_FILES_FILE" 2>/dev/null || true

# Get unique levels
LEVELS=$(cut -d'|' -f2 "$LEVELS_FILE" | sort -un)

# Cap: prevents O(n²) explosion on large parallel batches
MAX_LEVEL_SIZE=20

for level in $LEVELS; do
  # Get tasks at this level
  LEVEL_TASKS=$(awk -F'|' -v lv="$level" '$2 == lv {print $1}' "$LEVELS_FILE")
  level_task_count=$(echo "$LEVEL_TASKS" | wc -w | xargs)

  # Skip detailed pairwise check if level is too large
  if [ "$level_task_count" -gt "$MAX_LEVEL_SIZE" ]; then
    echo "  WARNING: Level $level has $level_task_count tasks (exceeds $MAX_LEVEL_SIZE cap — skipping detailed conflict detection, recommend serializing)"
    WARNINGS=$((WARNINGS + 1))
    continue
  fi

  # ── Hash-based duplicate detection (Fix 2: O(n log n) instead of O(n²)) ──
  # Build a combined file of: filepath|task_id|conflict_type
  # Then sort by filepath and find duplicates in a single pass.
  COMBINED_FILE="$TMP_DIR/combined_files.txt"
  touch "$COMBINED_FILE"

  # Scope files (ERROR severity) — filter for current level tasks only
  if [ -s "$SCOPE_FILES_FILE" ]; then
    for tid in $LEVEL_TASKS; do
      grep "^${tid}|" "$SCOPE_FILES_FILE" 2>/dev/null | while IFS='|' read -_ _ fpath; do
        echo "${fpath}|${tid}|SCOPE"
      done >> "$COMBINED_FILE" || true
    done
  fi

  # All files (WARNING severity — includes acceptance criteria references)
  # Skip files already tagged as SCOPE to avoid double-counting.
  for tid in $LEVEL_TASKS; do
    grep "^${tid}|" "$TASK_FILES_FILE" 2>/dev/null | while IFS='|' read -_ _ fpath; do
      if ! grep -q "^${fpath}|${tid}|SCOPE" "$COMBINED_FILE" 2>/dev/null; then
        echo "${fpath}|${tid}|ACCEPTANCE"
      fi
    done >> "$COMBINED_FILE" || true
  done

  # Find duplicate filepaths (files referenced by multiple tasks at same level)
  if [ -s "$COMBINED_FILE" ]; then
    # Sort by filepath, then detect consecutive duplicates with awk
    sort -t'|' -k1,1 "$COMBINED_FILE" | awk -F'|' '
      {
        if ($1 == prev_path && prev_tid != $2) {
          # Same filepath, different task — report duplicate
          severity = ($3 == "SCOPE" || prev_type == "SCOPE") ? "ERROR" : "WARNING"
          print prev_path "|" prev_tid "|" $2 "|" severity
        }
        prev_path = $1
        prev_tid = $2
        prev_type = $3
      }
    ' > "$TMP_DIR/duplicates.txt" 2>/dev/null || true

    # Report duplicates
    if [ -s "$TMP_DIR/duplicates.txt" ]; then
      while IFS='|' read -r fpath tid_a tid_b severity; do
        if [ "$severity" = "ERROR" ]; then
          echo "  ERROR: TASK-$tid_a and TASK-$tid_b (same batch level $level) both Scope-modify: $fpath"
          echo "         Tasks in the same batch MUST NOT modify the same files."
          echo "         Serialize these tasks or split into separate batches."
          ERRORS=$((ERRORS + 1))
        else
          echo "  WARNING: TASK-$tid_a and TASK-$tid_b (same batch level $level) both reference: $fpath"
          echo "          Consider serializing these tasks to avoid merge conflicts."
          WARNINGS=$((WARNINGS + 1))
        fi
        echo "\"TASK-$tid_a <-> TASK-$tid_b ($severity): $fpath)\"" >> "$OVERLAP_FILE"
      done < "$TMP_DIR/duplicates.txt"
    fi
  fi
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
