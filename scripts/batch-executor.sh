#!/usr/bin/env bash
# batch-executor.sh — Parallel batch execution with conflict detection
#
# Usage: scripts/batch-executor.sh <feature_dir> [--batch-size N] [--single-task TASK-N]
#
# Executes tasks in dependency-order batches with parallel execution within each batch.
#
# Flow:
#   1. Validate task graph via validate-tasks.sh
#   2. Compute batch plan via validate-tasks.sh --batch-plan
#   3. Parse levels, group tasks by dependency level
#   4. For each level: launch tasks in parallel, wait, check consistency
#   5. On failure: cascade ABANDONED to dependents, break
#   6. On success: write batch summary, continue
#
# Exit code: 0 = all batches completed, 1 = failure/aborted

set -euo pipefail

FEATURE_DIR="${1:?Usage: batch-executor.sh <feature_dir> [--batch-size N] [--single-task TASK-N]}"
shift

BATCH_SIZE=""
SINGLE_TASK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --single-task) SINGLE_TASK="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TASKS_FILE="${FEATURE_DIR}/tasks.md"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
LOCK_FILE="${ARTIFACTS_DIR}/tasks.lock"
BATCH_LOG="${ARTIFACTS_DIR}/batch-execution.log"
mkdir -p "$ARTIFACTS_DIR"

TOTAL_BATCHES=0
COMPLETED_BATCHES=0
FAILED_BATCHES=0
BATCH_FAIL=false

log() {
  local msg="[$(date -u +%H:%M:%S)] $*"
  echo "$msg"
  echo "$msg" >> "$BATCH_LOG" 2>/dev/null || true
}

# ── Validate task graph ─────────────────────────────────────────
log "VALIDATING TASK GRAPH"
if ! bash "${SCRIPT_DIR}/validate-tasks.sh" "$FEATURE_DIR" 2>&1 | tee -a "$BATCH_LOG"; then
  log "FATAL: Task graph validation failed"
  exit 1
fi

# ── Compute batch plan ──────────────────────────────────────────
log "COMPUTING BATCH PLAN"
BATCH_PLAN=$(SKIP_VALIDATION=1 bash "${SCRIPT_DIR}/validate-tasks.sh" --batch-plan "$FEATURE_DIR" 2>/dev/null || echo '{"levels":[]}')

# ── Parse levels ────────────────────────────────────────────────
# Extract level names (level_0, level_1, ...) sorted numerically
LEVELS=$(echo "$BATCH_PLAN" | grep -oE '"level_[0-9]+"' | sort -t_ -k2 -n || true)

if [ -z "$LEVELS" ]; then
  log "NO TASKS: No levels found in batch plan"
  exit 0
fi

# ── Run a single task ───────────────────────────────────────────
run_single_task() {
  local task_id="$1"
  local level="$2"

  log "  BATCH [$level]: Starting $task_id"

  # Generate unified context for this task
  bash "${SCRIPT_DIR}/unified-context.sh" "$FEATURE_DIR" "$task_id" "backend-domain" >> "$BATCH_LOG" 2>/dev/null || true

  # Acquire lock, update status, release lock
  bash "${SCRIPT_DIR}/file-lock.sh" "$LOCK_FILE" \
    bash "${SCRIPT_DIR}/set-task-status.sh" "$TASKS_FILE" IN_PROGRESS "$task_id" "Batch execution level $level" >> "$BATCH_LOG" 2>/dev/null || true

  # Run the implementation (simulated — in real usage, this calls speckit.implement)
  # For now, simulate success with a small delay
  # In production: bash "${SCRIPT_DIR}/run-speckit-implement.sh" "$FEATURE_DIR" "$task_id"
  sleep 0.1

  # Update status to DONE
  bash "${SCRIPT_DIR}/file-lock.sh" "$LOCK_FILE" \
    bash "${SCRIPT_DIR}/set-task-status.sh" "$TASKS_FILE" DONE "$task_id" "Batch execution level $level completed" >> "$BATCH_LOG" 2>/dev/null || true

  # Run quality checks if check-runner.sh exists
  if [ -f "${SCRIPT_DIR}/check-runner.sh" ]; then
    bash "${SCRIPT_DIR}/check-runner.sh" "$FEATURE_DIR" "implement" >> "$BATCH_LOG" 2>/dev/null || true
  fi

  log "  BATCH [$level]: Completed $task_id"
}

# ── Process each level ──────────────────────────────────────────
for level_json in $LEVELS; do
  level_name=$(echo "$level_json" | tr -d '"')
  level_num=$(echo "$level_name" | sed 's/level_//')

  # Extract task IDs within this level
  # The JSON format is: "level_0": ["TASK-1", "TASK-2"]
  level_tasks=$(echo "$BATCH_PLAN" | awk -v lv="$level_name" '
    $0 ~ lv {
      s=$0
      sub(/.*\[/, "", s)
      sub(/\].*/, "", s)
      gsub(/"/, "", s)
      gsub(/ /, "", s)
      print s
    }
  ')

  if [ -z "$level_tasks" ]; then
    log "SKIP: Level $level_num is empty"
    continue
  fi

  # Split task IDs
  TASKS_IN_LEVEL=()
  IFS=',' read -ra TASKS_IN_LEVEL <<< "$level_tasks"

  if [ ${#TASKS_IN_LEVEL[@]} -eq 0 ]; then
    log "SKIP: No tasks in level $level_num"
    continue
  fi

  TOTAL_BATCHES=$((TOTAL_BATCHES + 1))
  log "BATCH LEVEL $level_num: ${TASKS_IN_LEVEL[*]} (${#TASKS_IN_LEVEL[@]} tasks)"

  # Write batch task list for verify-batch-consistency.sh
  printf '%s\n' "${TASKS_IN_LEVEL[@]}" > "${ARTIFACTS_DIR}/batch_tasks.txt"

  # Check dependencies are DONE
  ALL_DEPS_OK=true
  for task in "${TASKS_IN_LEVEL[@]}"; do
    if ! bash "${SCRIPT_DIR}/validate-task-deps.sh" "$TASKS_FILE" "$task" >/dev/null 2>&1; then
      log "  BLOCKED: $task has unmet dependencies"
      ALL_DEPS_OK=false
      break
    fi
  done

  if [ "$ALL_DEPS_OK" = false ]; then
    log "ABORT: Level $level_num blocked by unmet dependencies"
    FAILED_BATCHES=$((FAILED_BATCHES + 1))
    BATCH_FAIL=true
    break
  fi

  # Launch tasks in parallel
  PIDS=()
  RESULTS=()

  for task in "${TASKS_IN_LEVEL[@]}"; do
    (run_single_task "$task" "$level_num") &
    PIDS+=($!)
  done

  # Wait for all tasks in this level
  ALL_PASSED=true
  for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
      ALL_PASSED=false
    fi
  done

  # Run batch consistency check
  if [ -f "${SCRIPT_DIR}/verify-batch-consistency.sh" ]; then
    if ! bash "${SCRIPT_DIR}/verify-batch-consistency.sh" "$FEATURE_DIR" >> "$BATCH_LOG" 2>/dev/null; then
      log "  CONFLICT: Batch consistency check failed for level $level_num"
      ALL_PASSED=false
    fi
  fi

  if [ "$ALL_PASSED" = true ]; then
    COMPLETED_BATCHES=$((COMPLETED_BATCHES + 1))
    log "LEVEL $level_num: ALL PASSED"
  else
    log "LEVEL $level_num: FAILED — cascading ABANDONED to dependents"
    FAILED_BATCHES=$((FAILED_BATCHES + 1))

    # Cascade ABANDONED to dependent tasks
    for task in "${TASKS_IN_LEVEL[@]}"; do
      bash "${SCRIPT_DIR}/set-task-status.sh" "$TASKS_FILE" ABANDONED --cascade "$task" "Batch level $level_num failed" >> "$BATCH_LOG" 2>/dev/null || true
    done

    BATCH_FAIL=true
    break
  fi

  # Enforce batch size limit if specified
  if [ -n "$BATCH_SIZE" ] && [ "$COMPLETED_BATCHES" -ge "$BATCH_SIZE" ]; then
    log "BATCH SIZE LIMIT REACHED: $BATCH_SIZE batches"
    break
  fi
done

# ── Summary ─────────────────────────────────────────────────────
echo ""
log "BATCH EXECUTION SUMMARY"
log "  Total batches: $TOTAL_BATCHES"
log "  Completed: $COMPLETED_BATCHES"
log "  Failed: $FAILED_BATCHES"
if [ "$BATCH_FAIL" = true ]; then
  log "  STATUS: ABORTED — fix failures and re-run"
  exit 1
else
  log "  STATUS: ALL BATCHES COMPLETED"
  exit 0
fi
