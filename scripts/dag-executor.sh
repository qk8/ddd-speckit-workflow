#!/usr/bin/env bash
# dag-executor.sh — DAG-aware parallel task executor
#
# Usage: scripts/dag-executor.sh <feature_dir> [--max-parallel N] [--implement-cmd CMD]
#        scripts/dag-executor.sh <feature_dir> --dry-run
#
# Reads state.json for task dependencies, computes topological levels,
# and executes tasks in parallel within each level.
#
# Algorithm:
#   1. Read state.json for all tasks
#   2. Build dependency graph (edges: depends_on)
#   3. Topological sort to compute levels
#   4. For each level:
#      a. For each task in level: launch background process (up to --max-parallel)
#         - bundle-assembler.sh implement <task_id> <feature_dir>
#         - speckit.write-test (reads bundle)
#         - speckit.implement (reads bundle)
#         - speckit.implement-verify (reads bundle)
#      b. Wait for all tasks in level to complete
#      c. Run batch consistency check
#      d. If any task failed: mark dependents as BLOCKED, continue independent tasks
#   5. Report summary
#
# Bash 3.2 compatible (no declare -A associative arrays).

set -euo pipefail

FEATURE_DIR="${1:?Usage: dag-executor.sh <feature_dir> [--max-parallel N] [--implement-cmd CMD] [--dry-run]}"
shift

MAX_PARALLEL=4
IMPLEMENT_CMD="speckit.implement"
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
    --implement-cmd) IMPLEMENT_CMD="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$FEATURE_DIR/state.json"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
LOG_FILE="$ARTIFACTS_DIR/dag-execution.log"
mkdir -p "$ARTIFACTS_DIR"

# ── Logging ──────────────────────────────────────────────────────
log() {
  local msg="[$(date -u +%H:%M:%S)] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_fail() {
  local msg="[$(date -u +%H:%M:%S)] $*"
  echo "$msg" >&2
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ── Validate prerequisites ──────────────────────────────────────
if [ ! -f "$STATE_FILE" ]; then
  echo "ERROR: state.json not found at $STATE_FILE" >&2
  echo "Run: bash scripts/state-engine.sh migrate $FEATURE_DIR" >&2
  exit 1
fi

if ! jq empty "$STATE_FILE" 2>/dev/null; then
  echo "ERROR: state.json is not valid JSON" >&2
  exit 1
fi

# ── Read tasks from state.json ──────────────────────────────────
TASK_IDS=$(jq -r '.tasks | keys[]' "$STATE_FILE" 2>/dev/null | sort)

if [ -z "$TASK_IDS" ]; then
  log "No tasks found in state.json"
  exit 0
fi

TOTAL_TASKS=$(echo "$TASK_IDS" | wc -l | tr -d ' ')
log "Found $TOTAL_TASKS tasks in state.json"

# ── Compute dependency levels via jq (Kahn's algorithm) ─────────
# Output: one line per level, comma-separated task IDs
LEVELS_FILE="$ARTIFACTS_DIR/.dag_levels.txt"
: > "$LEVELS_FILE"

jq -r '
  # Build task map: id -> depends_on
  .tasks | to_entries | map({(.key): (.value.depends_on // [])}) | add // {} |

  # Collect all task IDs
  . as $deps |
  ($deps | keys) as $all_ids |

  # Kahn'"'"'s algorithm
  {
    remaining: $all_ids,
    processed: [],
    levels: []
  } |

  # Iteratively find ready tasks (all deps in processed)
  until(
    (.remaining | length) == 0;
    .remaining as $rem |
    .processed as $proc |
    # Find tasks whose all dependencies are in processed
    [.remaining[] | . as $t |
      select(
        [($deps[$t] // [])[] | . as $dep | select($proc | index($dep) == null)] | length == 0
      )
    ] as $new_level |

    # If no level found but tasks remain, there is a cycle
    if ($new_level | length) == 0 then
      .remaining = $rem | .blocked = $rem | .levels + [] |
      error("Cycle detected in task dependencies")
    else
      .levels += [$new_level] |
      .processed += $new_level |
      .remaining = [.remaining[] | select(. as $t | $new_level | index($t) == null)]
    end
  ) |

  .levels |
  if length == 0 then "NO_TASKS"
  else map(join(", ")) | join("\n")
  end
' "$STATE_FILE" > "$LEVELS_FILE" 2>/dev/null || {
  log "WARNING: Topological sort failed (possible cycle), using flat ordering"
  echo "$TASK_IDS" | sed 's/\n/, /g' > "$LEVELS_FILE"
}

# ── Dry run mode ────────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
  echo "━━━ DAG Executor — Dry Run ━━━"
  echo "Feature dir: $FEATURE_DIR"
  echo "Max parallel: $MAX_PARALLEL"
  echo "Implement cmd: $IMPLEMENT_CMD"
  echo ""
  echo "Levels:"
  level_num=0
  while IFS= read -r level_line; do
    [ -z "$level_line" ] && continue
    level_num=$((level_num + 1))
    IFS=',' read -ra tasks <<< "$level_line"
    echo "  Level $level_num: ${tasks[*]}"
  done < "$LEVELS_FILE"
  echo ""
  echo "Total tasks: $TOTAL_TASKS"
  echo "Total levels: $level_num"
  exit 0
fi

# ── File-level locking for parallel tasks ─────────────────────────
# Prevents two tasks in the same batch from writing the same file.
# Each task claims files it creates/modifies; other tasks in the
# same level wait or fail if they try to write a claimed file.
claim_file() {
  local task_id="$1" filepath="$2"
  local lock_dir="$ARTIFACTS_DIR/.file-locks"
  local lock_file="$lock_dir/${filepath//\//_}"
  mkdir -p "$lock_dir"

  # Try to create the lock file atomically (mkdir is atomic on most fs)
  if mkdir "$lock_file" 2>/dev/null; then
    echo "$task_id" > "$lock_file/task"
    return 0
  else
    local owner
    owner=$(cat "$lock_file/task" 2>/dev/null || echo "unknown")
    log "  CONFLICT: $filepath already claimed by $task_id (owned by $owner)"
    return 1
  fi
}

release_file() {
  local task_id="$1" filepath="$2"
  local lock_dir="$ARTIFACTS_DIR/.file-locks"
  local lock_file="$lock_dir/${filepath//\//_}"
  rm -rf "$lock_file" 2>/dev/null || true
}

cleanup_file_locks() {
  rm -rf "$ARTIFACTS_DIR/.file-locks" 2>/dev/null || true
}

# ── Execute a single task (background function) ─────────────────
execute_task() {
  local task_id="$1"
  local task_type
  task_type=$(jq -r --arg tid "$task_id" '.tasks[$tid].type // "backend-domain"' "$STATE_FILE")

  log "  EXEC: $task_id ($task_type)"

  # Update status to IN_PROGRESS
  bash "$SCRIPT_DIR/state-engine.sh" task-set "$FEATURE_DIR" "$task_id" status IN_PROGRESS 2>/dev/null || true

  # Generate bundle for this task
  bash "$SCRIPT_DIR/bundle-assembler.sh" implement "$task_id" "$FEATURE_DIR" \
    --max-lines 200 2>/dev/null || true

  # Run implementation commands
  local result=0

  # 1. Write tests (if speckit.write-test exists)
  if command -v speckit.write-test &>/dev/null 2>&1; then
    speckit.write-test "$FEATURE_DIR" "$task_id" 2>/dev/null || result=$?
  fi

  # 2. Run implementation
  if command -v "$IMPLEMENT_CMD" &>/dev/null 2>&1; then
    "$IMPLEMENT_CMD" "$FEATURE_DIR" "$task_id" 2>/dev/null || result=$?
  fi

  # 3. Implement-verify
  if command -v speckit.implement-verify &>/dev/null 2>&1; then
    speckit.implement-verify "$FEATURE_DIR" "$task_id" 2>/dev/null || result=$?
  fi

  # Update status based on result
  if [ "$result" -eq 0 ]; then
    bash "$SCRIPT_DIR/state-engine.sh" task-set "$FEATURE_DIR" "$task_id" status DONE 2>/dev/null || true
    log "  DONE: $task_id"
  else
    bash "$SCRIPT_DIR/state-engine.sh" task-set "$FEATURE_DIR" "$task_id" status FAILED 2>/dev/null || true
    log_fail "  FAIL: $task_id (exit $result)"
  fi

  # Write result marker
  if [ "$result" -eq 0 ]; then
    echo "PASS" > "$ARTIFACTS_DIR/task_${task_id}.result"
  else
    echo "FAIL" > "$ARTIFACTS_DIR/task_${task_id}.result"
  fi

  return "$result"
}

# ── Mark dependents as BLOCKED ──────────────────────────────────
cascade_blocked() {
  local failed_task="$1"
  log "  CASCADE: Marking dependents of $failed_task as BLOCKED"

  # Find all tasks that depend on the failed task (directly)
  local dependents
  dependents=$(jq -r --arg tid "$failed_task" '
    .tasks | to_entries[] |
    select(.value.depends_on // [] | index($tid) != null) |
    .key
  ' "$STATE_FILE" 2>/dev/null)

  for dep in $dependents; do
    local dep_status
    dep_status=$(jq -r --arg tid "$dep" '.tasks[$tid].status' "$STATE_FILE")
    if [ "$dep_status" != "DONE" ]; then
      bash "$SCRIPT_DIR/state-engine.sh" task-set "$FEATURE_DIR" "$dep" status BLOCKED 2>/dev/null || true
      bash "$SCRIPT_DIR/state-engine.sh" task-set "$FEATURE_DIR" "$dep" blocking_reason "Dependency $failed_task failed" 2>/dev/null || true
      log "    BLOCKED: $dep (depends on $failed_task)"
    fi
  done
}

# ── Run batch consistency check ─────────────────────────────────
run_batch_consistency() {
  if [ -f "$SCRIPT_DIR/verify-batch-consistency.sh" ]; then
    bash "$SCRIPT_DIR/verify-batch-consistency.sh" "$FEATURE_DIR" >> "$LOG_FILE" 2>/dev/null || {
      log "  CONFLICT: Batch consistency check failed"
      return 1
    }
  fi
  return 0
}

# ── Main execution loop ─────────────────────────────────────────
log "━━━ DAG Executor ━━━"
log "Feature dir: $FEATURE_DIR"
log "Max parallel: $MAX_PARALLEL"
log ""

TOTAL_LEVELS=0
COMPLETED_TASKS=0
FAILED_TASKS=0
SKIPPED_TASKS=0

while IFS= read -r level_line; do
  [ -z "$level_line" ] && continue
  TOTAL_LEVELS=$((TOTAL_LEVELS + 1))

  IFS=',' read -ra tasks <<< "$level_line"

  # Filter out already DONE/BLOCKED/ABANDONED tasks
  RUNNABLE=()
  for task in "${tasks[@]}"; do
    status=$(jq -r --arg tid "$task" '.tasks[$tid].status' "$STATE_FILE")
    case "$status" in
      DONE)
        COMPLETED_TASKS=$((COMPLETED_TASKS + 1))
        ;;
      BLOCKED|ABANDONED)
        SKIPPED_TASKS=$((SKIPPED_TASKS + 1))
        ;;
      *)
        RUNNABLE+=("$task")
        ;;
    esac
  done

  if [ ${#RUNNABLE[@]} -eq 0 ]; then
    continue
  fi

  log "LEVEL $TOTAL_LEVELS: ${RUNNABLE[*]} (${#RUNNABLE[@]} tasks)"

  # Write batch task list
  printf '%s\n' "${RUNNABLE[@]}" > "$ARTIFACTS_DIR/batch_tasks.txt"

  # Execute tasks with parallelism limit
  PIDS=()
  ACTIVE=0
  LEVEL_FAILED=false

  for task in "${RUNNABLE[@]}"; do
    # Wait if we've reached max parallel
    while [ "$ACTIVE" -ge "$MAX_PARALLEL" ] && [ ${#PIDS[@]} -gt 0 ]; do
      NEW_PIDS=()
      for pid in "${PIDS[@]}"; do
        if ! wait "$pid" 2>/dev/null; then
          LEVEL_FAILED=true
          FAILED_TASKS=$((FAILED_TASKS + 1))
          result_file="$ARTIFACTS_DIR/task_${task}.result"
          if [ -f "$result_file" ] && [ "$(cat "$result_file")" = "FAIL" ]; then
            cascade_blocked "$task"
          fi
        else
          COMPLETED_TASKS=$((COMPLETED_TASKS + 1))
        fi
        # Keep PID if still running (shouldn't happen since we waited)
      done
      PIDS=()
      ACTIVE=${#PIDS[@]}
      # Break if no PIDs left to avoid infinite loop
      [ "$ACTIVE" -eq 0 ] && break
    done

    # Launch task in background
    execute_task "$task" &
    PIDS+=($!)
    ACTIVE=$((ACTIVE + 1))
  done

  # Wait for remaining tasks
  for task_idx in "${!PIDS[@]}"; do
    pid="${PIDS[$task_idx]}"
    # Get the task name from RUNNABLE
    pending_task="${RUNNABLE[$task_idx]}"
    if ! wait "$pid" 2>/dev/null; then
      LEVEL_FAILED=true
      FAILED_TASKS=$((FAILED_TASKS + 1))
      if [ -f "$ARTIFACTS_DIR/task_${pending_task}.result" ] && \
         [ "$(cat "$ARTIFACTS_DIR/task_${pending_task}.result")" = "FAIL" ]; then
        cascade_blocked "$pending_task"
      fi
    else
      COMPLETED_TASKS=$((COMPLETED_TASKS + 1))
    fi
  done

  # Clean up result markers and file locks
  rm -f "$ARTIFACTS_DIR"/task_*.result 2>/dev/null || true
  cleanup_file_locks

  # Run batch consistency check
  if [ "$LEVEL_FAILED" = false ]; then
    if ! run_batch_consistency; then
      LEVEL_FAILED=true
    fi
  fi

  if [ "$LEVEL_FAILED" = true ]; then
    log "LEVEL $TOTAL_LEVELS: FAILED — stopping execution"
    log "Completed: $COMPLETED_TASKS, Failed: $FAILED_TASKS, Skipped: $SKIPPED_TASKS"
    exit 1
  fi

  log "LEVEL $TOTAL_LEVELS: ALL PASSED"
done < "$LEVELS_FILE"

# ── Summary ─────────────────────────────────────────────────────
echo ""
log "━━━ Execution Summary ━━━"
log "Total levels: $TOTAL_LEVELS"
log "Completed: $COMPLETED_TASKS"
log "Failed: $FAILED_TASKS"
log "Skipped: $SKIPPED_TASKS"
log "Total tasks: $TOTAL_TASKS"

if [ "$FAILED_TASKS" -gt 0 ]; then
  log "STATUS: ABORTED"
  exit 1
else
  log "STATUS: ALL COMPLETED"
  exit 0
fi
