#!/usr/bin/env bash
# recovery-engine.sh — Unified recovery engine for DDD + Spec Kit workflow
#
# Replaces: check-point.sh, restore-checkpoint.sh, save-pause-state.sh,
#           resume-workflow.sh, cleanup-abandoned-state.sh, cleanup-abandoned.sh,
#           post-verify-checkpoint.sh, post-gate-checkpoint.sh, reset-stagnation.sh
#
# Usage:
#   recovery-engine.sh checkpoint   <feature_dir> --phase <phase> [--task <task_id>] [--root-dir <dir>]
#   recovery-engine.sh restore      <feature_dir> <checkpoint_id> [--soft|--hard]
#   recovery-engine.sh list         <feature_dir>
#   recovery-engine.sh cleanup      <feature_dir> [--older-than N|--keep N]
#   recovery-engine.sh pause        <feature_dir> <step_name>
#   recovery-engine.sh resume       <feature_dir>
#   recovery-engine.sh abort        <feature_dir> [phase]
#   recovery-engine.sh abandoned    <feature_dir>
#   recovery-engine.sh reset-stagnation <feature_dir>
#   recovery-engine.sh fix-cycles-reset <feature_dir>
#   recovery-engine.sh post-verify <feature_dir>
#   recovery-engine.sh post-gate  <feature_dir>
#
# Checkpoints stored at: <feature_dir>/.artifacts/checkpoints/v<epoch_ms>/
#   - state.json (snapshot of state-engine state)
#   - files.json (file hashes, same format as old snapshots)
#   - git-diff.txt / git-diff.patch (if root-dir provided)
#   - metadata.json (phase, task_id, timestamp)

set -euo pipefail

# ── Prerequisites ────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

MODE="${1:?Usage: recovery-engine.sh <checkpoint|restore|list|cleanup|pause|resume|abort|abandoned|reset-stagnation|fix-cycles-reset|post-verify|post-gate> <feature_dir> [args...]}"
FEATURE_DIR="${2:?Feature directory required}"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
CHECKPOINT_DIR="${ARTIFACTS_DIR}/checkpoints"
STATE_FILE="${FEATURE_DIR}/state.json"
TASKS_FILE="${FEATURE_DIR}/tasks.md"

mkdir -p "$ARTIFACTS_DIR" "$CHECKPOINT_DIR"

NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
EPOCH_MS=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))

# ── Helpers ──────────────────────────────────────────────────────
maybe_file() {
  [ -f "$1" ] && cat "$1" || echo "  (not found: $1)"
}

# Build a file snapshot JSON (same format as old check-point.sh snapshot)
# Captures both git-tracked and untracked project files. No artificial cap.
build_file_snapshot() {
  local root_dir="$1"
  local file_list="" file_count=0

  if [ ! -d "$root_dir" ]; then
    printf '{"files":{},"file_count":0}'
    return
  fi

  # Collect files: git-tracked + untracked project files.
  # Skip noise directories but include everything under common project dirs.
  while IFS= read -r filepath; do
    local rel_path="${filepath#${root_dir}/}"
    case "$rel_path" in
      .git/*|.artifacts/*|node_modules/*|.next/*|dist/*|build/*|.specify/*|.claude/.agents/*|.claude/skills/*) continue ;;
    esac
    local hash_val="binary"
    if file "$filepath" 2>/dev/null | grep -q 'text'; then
      hash_val=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1 || echo "unreadable")
    fi
    [ -n "$file_list" ] && file_list="${file_list},"
    file_list="${file_list}\"${rel_path}\":\"${hash_val}\""
    file_count=$((file_count + 1))
  done < <(
    # Git-tracked files first (highest priority for restore)
    { git -C "$root_dir" ls-files 2>/dev/null || true; } | while IFS= read -r f; do echo "$root_dir/$f"; done
    # Then untracked project files (src/, lib/, app/, packages/, etc.)
    { git -C "$root_dir" ls-files --others --exclude-standard 2>/dev/null || true; } | while IFS= read -r f; do
      # Only include untracked files that look like project source (not build artifacts)
      case "$f" in
        *.o|*.pyc|*.pyo|*.class|*.jar|*.war|*.ear|*.zip|*.tar|*.gz|*.log|*.tmp|*.swp|*.swo|*~) continue ;;
        *) echo "$root_dir/$f" ;;
      esac
    done
  )

  printf '{"files":{%s},"file_count":%d}' "$file_list" "$file_count"
}

# ── Checkpoint ───────────────────────────────────────────────────
do_checkpoint() {
  local phase="" task_id="" root_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase) phase="$2"; shift ;;
      --task) task_id="$2"; shift ;;
      --root-dir) root_dir="$2"; shift ;;
    esac
    shift
  done

  [ -z "$phase" ] && { echo "ERROR: --phase required" >&2; exit 1; }

  local cp_id="v${EPOCH_MS}"
  local cp_dir="${CHECKPOINT_DIR}/${cp_id}"
  mkdir -p "$cp_dir"

  # Save state.json snapshot
  if [ -f "$STATE_FILE" ]; then
    cp "$STATE_FILE" "${cp_dir}/state.json"
  fi

  # Save file snapshot if root_dir provided
  if [ -n "$root_dir" ]; then
    build_file_snapshot "$root_dir" > "${cp_dir}/files.json"

    # Check disk space before writing (warn if < 1GB free)
    local disk_free_kb
    disk_free_kb=$(df -k "$CHECKPOINT_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo 0)
    if [ "$disk_free_kb" -lt 1048576 ] 2>/dev/null; then
      echo "WARNING: Low disk space (${disk_free_kb}KB free). Checkpoint may fail." >&2
    fi

    # Git diff
    if [ -d "$root_dir/.git" ]; then
      (cd "$root_dir" && git diff --stat 2>/dev/null || true) > "${cp_dir}/git-diff.txt"
      (cd "$root_dir" && git diff 2>/dev/null || true) > "${cp_dir}/git-diff.patch"
    fi
  fi

  # Save metadata
  cat > "${cp_dir}/metadata.json" <<EOF
{
  "phase": "${phase}",
  "task_id": "${task_id:-none}",
  "created_at": "${NOW}",
  "checkpoint_id": "${cp_id}"
}
EOF

  # Update state.json history
  if [ -f "$STATE_FILE" ]; then
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq --arg phase "$phase" --arg task "$task_id" --arg ts "$NOW" \
      '.history += [{"phase":"recovery","checkpoint":"'"$cp_id"'","checkpoint_phase":$phase,"task":$task,"timestamp":$ts}] | .metadata.updated_at = $ts' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi

  echo "CHECKPOINT: ${cp_id} (phase=${phase}, task=${task_id:-none}) → ${cp_dir}"
  echo "$cp_id"
}

# ── Restore ──────────────────────────────────────────────────────
do_restore() {
  local checkpoint_id="$1"
  shift
  local mode="hard"

  while [ $# -gt 0 ]; do
    case "$1" in
      --soft) mode="soft" ;;
      --hard) mode="hard" ;;
    esac
    shift
  done

  local cp_dir="${CHECKPOINT_DIR}/${checkpoint_id}"
  if [ ! -d "$cp_dir" ]; then
    echo "ERROR: Checkpoint not found: ${checkpoint_id}"
    echo "  Run 'recovery-engine.sh list <feature_dir>' to see available checkpoints."
    exit 1
  fi

  # Backup current state
  local backup_dir="${ARTIFACTS_DIR}/rollback-backup/${checkpoint_id}"
  mkdir -p "$backup_dir"

  if [ -f "$STATE_FILE" ]; then
    cp "$STATE_FILE" "${backup_dir}/state.json"
  fi
  if [ -f "$TASKS_FILE" ]; then
    cp "$TASKS_FILE" "${backup_dir}/tasks.md"
  fi

  if [ "$mode" = "hard" ] && [ -f "${cp_dir}/state.json" ]; then
    cp "${cp_dir}/state.json" "$STATE_FILE"
    echo "RESTORE (hard): state.json restored from ${checkpoint_id}"
  fi

  if [ -f "${cp_dir}/files.json" ] && [ -n "${ROOT_DIR:-}" ]; then
    # Restore files via git checkout
    local file_count
    file_count=$(jq '.file_count // 0' "${cp_dir}/files.json")
    if [ "$file_count" -gt 0 ]; then
      local restored=0
      while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        local full_path="${ROOT_DIR}/${rel_path}"
        if [ -f "$full_path" ]; then
          local expected_hash current_hash
          expected_hash=$(jq -r --arg f "$rel_path" '.files[$f] // ""' "${cp_dir}/files.json")
          if [ "$expected_hash" != "binary" ] && [ "$expected_hash" != "" ]; then
            current_hash=$(sha256sum "$full_path" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
            if [ "$current_hash" != "$expected_hash" ]; then
              if git -C "$ROOT_DIR" checkout HEAD -- "$full_path" 2>/dev/null; then
                restored=$((restored + 1))
              fi
            fi
          fi
        fi
      done < <(jq -r '.files | keys[]' "${cp_dir}/files.json")
      echo "RESTORE: ${restored} file(s) restored via git checkout"
    fi
  fi

  echo "RESTORE COMPLETE: ${checkpoint_id} (mode=${mode})"
}

# ── List ─────────────────────────────────────────────────────────
do_list() {
  echo "Available checkpoints:"
  if [ ! -d "$CHECKPOINT_DIR" ]; then
    echo "  (none)"
    exit 0
  fi

  for cp_dir in "$CHECKPOINT_DIR"/v*; do
    [ -d "$cp_dir" ] || continue
    local cp_id
    cp_id=$(basename "$cp_dir")
    if [ -f "${cp_dir}/metadata.json" ]; then
      local phase task created
      phase=$(jq -r '.phase // "unknown"' "${cp_dir}/metadata.json")
      task=$(jq -r '.task_id // "none"' "${cp_dir}/metadata.json")
      created=$(jq -r '.created_at // "unknown"' "${cp_dir}/metadata.json")
      local file_count=0
      [ -f "${cp_dir}/files.json" ] && file_count=$(jq '.file_count // 0' "${cp_dir}/files.json")
      echo "  ${cp_id} | phase: ${phase} | task: ${task} | created: ${created} | files: ${file_count}"
    else
      echo "  ${cp_id} | (no metadata)"
    fi
  done
}

# ── Cleanup ──────────────────────────────────────────────────────
do_cleanup() {
  local older_than="" keep=5

  while [ $# -gt 0 ]; do
    case "$1" in
      --older-than) older_than="$2"; shift ;;
      --keep) keep="$2"; shift ;;
    esac
    shift
  done

  local removed=0
  local cp_dirs=("$CHECKPOINT_DIR"/v*)

  if [ ${#cp_dirs[@]} -eq 0 ] || [ ! -e "${cp_dirs[0]}" ]; then
    echo "CLEANUP: No checkpoints to clean."
    return
  fi

  # Sort by name (v-prefixed = chronological), keep last N
  local total=${#cp_dirs[@]}
  if [ "$total" -le "$keep" ]; then
    echo "CLEANUP: ${total} checkpoints, keeping all (keep=${keep})."
    return
  fi

  local to_remove=$((total - keep))
  for ((i=0; i<to_remove; i++)); do
    rm -rf "${cp_dirs[$i]}"
    removed=$((removed + 1))
  done

  echo "CLEANUP: Removed ${removed} checkpoint(s), keeping ${keep} (total was ${total})."
}

# ── Pause ────────────────────────────────────────────────────────
do_pause() {
  local step_name="$1"
  mkdir -p "$FEATURE_DIR"
  cat > "${FEATURE_DIR}/workflow_state.json" <<EOF
{"step": "${step_name}", "paused_at": "${NOW}"}
EOF
  echo "Workflow paused at ${step_name}. Run 'recovery-engine.sh resume <feature_dir>' to continue."
}

# ── Resume ───────────────────────────────────────────────────────
do_resume() {
  local state_file="${FEATURE_DIR}/workflow_state.json"
  if [ ! -f "$state_file" ]; then
    echo "No paused workflow found. Nothing to resume."
    exit 0
  fi

  local paused_step paused_at
  paused_step=$(jq -r '.step // "unknown"' "$state_file")
  paused_at=$(jq -r '.paused_at // "unknown"' "$state_file")
  echo "Workflow was paused. Resuming..."
  echo "  Paused at step: ${paused_step}"
  echo "  Paused at: ${paused_at}"

  # Reset single IN_PROGRESS task
  if [ -f "$TASKS_FILE" ]; then
    local in_progress_count
    in_progress_count=$(grep -c "Status: IN_PROGRESS" "$TASKS_FILE" 2>/dev/null || echo 0)
    if [ "$in_progress_count" -eq 1 ]; then
      local tmp
      tmp=$(mktemp "${TASKS_FILE}.XXXXXX")
      sed 's/^Status: IN_PROGRESS$/Status: TODO/' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
      echo "Reset IN_PROGRESS task to TODO."
    elif [ "$in_progress_count" -gt 1 ]; then
      echo "WARNING: ${in_progress_count} IN_PROGRESS tasks — not auto-resetting."
    fi
  fi

  rm -f "$state_file"
}

# ── Abort ────────────────────────────────────────────────────────
do_abort() {
  local phase="${2:-unknown}"
  local abort_report="${ARTIFACTS_DIR}/abort-report.md"
  mkdir -p "$ARTIFACTS_DIR"

  {
    echo "# Workflow Abort Report"
    echo ""
    echo "- **Aborted at**: ${NOW}"
    echo "- **Phase**: ${phase}"
    echo "- **Feature dir**: ${FEATURE_DIR}"
    echo ""
  } > "$abort_report"

  # Reset IN_PROGRESS tasks
  if [ -f "$TASKS_FILE" ]; then
    local in_progress_tasks
    in_progress_tasks=$(awk '/^## TASK/{header=$0} /^Status: IN_PROGRESS$/{gsub(/^## /,"",header); print header}' "$TASKS_FILE" 2>/dev/null || true)

    if [ -n "$in_progress_tasks" ]; then
      {
        echo "## Reset IN_PROGRESS tasks"
        echo ""
        echo "$in_progress_tasks" | while read -r tid; do echo "- ${tid} → reset to TODO"; done
        echo ""
      } >> "$abort_report"

      while IFS= read -r tid; do
        [ -z "$tid" ] && continue
        local tmp
        tmp=$(mktemp "${TASKS_FILE}.XXXXXX")
        awk -v target="$tid" '
          /^## TASK-/ { header = $0; in_target = 0 }
          header ~ ("TASK-" target) { in_target = 1 }
          in_target && /^Status: IN_PROGRESS$/ { sub(/Status: IN_PROGRESS/, "Status: TODO"); in_target = 0 }
          { print }
        ' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
      done <<< "$in_progress_tasks"
    else
      echo "## Reset IN_PROGRESS tasks" >> "$abort_report"
      echo "- No IN_PROGRESS tasks found." >> "$abort_report"
      echo "" >> "$abort_report"
    fi
  fi

  # Reset stagnation counters via state-engine
  if [ -f "$STATE_FILE" ]; then
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq '
      .stagnation.consecutive_no_progress = 0 |
      .stagnation.consecutive_continues = 0 |
      .stagnation.drift_violations = 0 |
      .metadata.updated_at = "'"${NOW}"'"
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    echo "- Stagnation counters reset." >> "$abort_report"
  fi

  # Clean partial check results
  if [ -d "${ARTIFACTS_DIR}/check-results" ]; then
    rm -f "${ARTIFACTS_DIR}/check-results/"*.result 2>/dev/null || true
    echo "- Partial check results cleaned." >> "$abort_report"
  fi

  # Reset revision counters for abandoned tasks
  if [ -f "$TASKS_FILE" ] && [ -d "${ARTIFACTS_DIR}/task-revisions" ]; then
    local abandoned_tasks
    abandoned_tasks=$(awk '/^## TASK/{header=$0} /^Status: ABANDONED$/{gsub(/^## /,"",header); print header}' "$TASKS_FILE" 2>/dev/null || true)
    if [ -n "$abandoned_tasks" ]; then
      while IFS= read -r tid; do
        [ -z "$tid" ] && continue
        rm -f "${ARTIFACTS_DIR}/task-revisions/${tid}.count" 2>/dev/null || true
      done <<< "$abandoned_tasks"
      echo "- Revision counters reset for abandoned tasks." >> "$abort_report"
    fi
  fi

  echo "- Abort report written to: ${abort_report}"
}

# ── Abandoned (file cleanup) ─────────────────────────────────────
do_abandoned() {
  if [ ! -d "$FEATURE_DIR" ]; then
    echo "CLEANUP_COMPLETE=true"
    echo "FILES_REMOVED=0"
    echo "FILES_FLAGGED=0"
    exit 0
  fi

  local report_file="${ARTIFACTS_DIR}/cleanup-report.md"
  local removed=0 flagged=0

  {
    echo "# ABANDONED TASK CLEANUP REPORT"
    echo ""
    echo "Generated: ${NOW}"
    echo ""
  } > "$report_file"

  # Find abandoned tasks
  local abandoned_tasks=""
  if [ -f "$TASKS_FILE" ]; then
    abandoned_tasks=$(awk '/^## TASK/{header=$0} /^Status: ABANDONED$/{gsub(/^## /,"",header); print header}' "$TASKS_FILE" 2>/dev/null || true)
  fi

  if [ -z "$abandoned_tasks" ]; then
    {
      echo "## Result"
      echo "No ABANDONED tasks found. Nothing to clean up."
    } >> "$report_file"
    echo "CLEANUP_COMPLETE=true"
    echo "FILES_REMOVED=0"
    echo "FILES_FLAGGED=0"
    exit 0
  fi

  echo "Found ABANDONED tasks: $(echo "$abandoned_tasks" | tr '\n' ' ')"

  # Remove prompt artifacts
  for task_id in $abandoned_tasks; do
    local prompt_dir="${ARTIFACTS_DIR}/prompts/${task_id}"
    if [ -d "$prompt_dir" ]; then
      rm -rf "$prompt_dir"
      removed=$((removed + 1))
      echo "  Removed: ${prompt_dir}" >> "$report_file"
    fi
  done

  # Clean uncommitted files from abandoned task manifests
  local created_files_dir="${ARTIFACTS_DIR}/created-files"
  if [ -d "$created_files_dir" ]; then
    for manifest in "$created_files_dir"/*.files; do
      [ -f "$manifest" ] || continue
      local manifest_task
      manifest_task=$(basename "$manifest" .files)
      if echo "$abandoned_tasks" | grep -q "$manifest_task" 2>/dev/null; then
        while IFS= read -r fpath; do
          [ -z "$fpath" ] && continue
          if [ -f "$fpath" ]; then
            rm -f "$fpath"
            removed=$((removed + 1))
            echo "  ABANDONED_REMOVED: ${fpath} (from ${manifest_task})" >> "$report_file"
          fi
        done < "$manifest"
      fi
    done
  fi

  {
    echo "## Summary"
    echo ""
    echo "- Files removed: ${removed}"
    echo "- Files flagged: ${flagged}"
  } >> "$report_file"

  echo "CLEANUP_COMPLETE=true"
  echo "FILES_REMOVED=${removed}"
  echo "FILES_FLAGGED=${flagged}"
}

# ── Reset Stagnation ─────────────────────────────────────────────
do_reset_stagnation() {
  if [ -f "$STATE_FILE" ]; then
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq '
      .stagnation.consecutive_no_progress = 0 |
      .stagnation.consecutive_continues = 0 |
      .metadata.updated_at = "'"${NOW}"'"
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi

  # Legacy flat files: clean up (don't create new ones)
  # If state.json exists, legacy files should be removed to prevent dual-path confusion
  for legacy_file in \
    "${FEATURE_DIR}/.stagnation_state" \
    "${FEATURE_DIR}/.stagnation_state.consec" \
    "${FEATURE_DIR}/.stagnation_state.continue_count" \
    "${FEATURE_DIR}/.stagnation_state.drift_count"; do
    if [ -f "$legacy_file" ]; then
      echo "CLEANUP: Removing legacy stagnation file: $(basename $legacy_file)" >&2
      rm -f "$legacy_file"
    fi
  done

  echo "STAGNANT=false"
  echo "CONTEXT LOADED -- resume from speckit.context"
}

# ── Fix Cycles Reset ────────────────────────────────────────────
do_fix_cycles_reset() {
  bash scripts/state-engine.sh fix-cycles-reset "$FEATURE_DIR"
  echo "FIX_CYCLES: reset — new fix-needed cycle allowed"
}

# ── Post-verify Checkpoint ──────────────────────────────────────
do_post_verify() {
  local task_id="" done_count=0 in_progress=""

  if [ -f "$TASKS_FILE" ]; then
    in_progress=$(awk '/^## TASK/{header=$0} /^Status: IN_PROGRESS$/{gsub(/^## /,"",header); print header; exit}' "$TASKS_FILE" 2>/dev/null || true)
    in_progress=$(echo "$in_progress" | sed 's/^## //')
    done_count=$(grep -c "^Status: DONE" "$TASKS_FILE" 2>/dev/null || echo 0)
  fi

  cat > "${ARTIFACTS_DIR}/checkpoint.json" <<EOF
{
  "phase": "implement_loop",
  "checkpoint": "post_verify",
  "timestamp": "${NOW}",
  "task_id": "${in_progress:-unknown}",
  "done_count": ${done_count},
  "in_progress_count": $([ -n "$in_progress" ] && echo 1 || echo 0),
  "in_progress_task": "${in_progress:-none}"
}
EOF

  echo "Checkpoint written: ${ARTIFACTS_DIR}/checkpoint.json"
}

# ── Post-gate Checkpoint ────────────────────────────────────────
do_post_gate() {
  cat > "${ARTIFACTS_DIR}/checkpoint.json" <<EOF
{
  "phase": "implement_loop",
  "checkpoint": "post_gate",
  "timestamp": "${NOW}",
  "gates_passed": true
}
EOF

  echo "Post-gate checkpoint written: ${ARTIFACTS_DIR}/checkpoint.json"
}

# ── Main dispatch ────────────────────────────────────────────────
case "$MODE" in
  checkpoint)           do_checkpoint "$@" ;;
  restore)              do_restore "$@" ;;
  list)                 do_list ;;
  cleanup)              do_cleanup "$@" ;;
  pause)                do_pause "${3:?step_name required}" ;;
  resume)               do_resume ;;
  abort)                do_abort "$@" ;;
  abandoned)            do_abandoned ;;
  reset-stagnation)     do_reset_stagnation ;;
  fix-cycles-reset)     do_fix_cycles_reset ;;
  post-verify)          do_post_verify ;;
  post-gate)            do_post_gate ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Usage: recovery-engine.sh <checkpoint|restore|list|cleanup|pause|resume|abort|abandoned|reset-stagnation|fix-cycles-reset|post-verify|post-gate> <feature_dir> [args...]" >&2
    exit 1
    ;;
esac
