#!/usr/bin/env bash
# check-point.sh — Read/write .workflow-state.json checkpoint
#
# Usage:
#   check-point.sh read <feature_dir>
#   check-point.sh write <feature_dir> task_done <task_id> <type> <built> <test_file>
#   check-point.sh write <feature_dir> task_in_progress <task_id> <type>
#   check-point.sh write <feature_dir> task_abandoned <task_id> <reason>
#   check-point.sh snapshot <feature_dir> <task_id> <root_dir>
#   check-point.sh rollback <feature_dir> <task_id>
#   check-point.sh diff <feature_dir> <task_id>
#
# Uses jq if available, falls back to sed/grep for bash 3.2 compatibility.
#
# FILE SNAPSHOT (C5): Before a task starts, run:
#   check-point.sh snapshot <feature_dir> TASK-3 /path/to/project
# This records which files existed before the task and captures a git diff.
# After the task, the checkpoint stores created/modified files for rollback.
#
# ROLLBACK (C5): If a task's downstream impact is detected later:
#   check-point.sh rollback <feature_dir> TASK-3
# This restores files to their pre-task state using git checkout.

set -euo pipefail

MODE="${1:?Usage: check-point.sh <read|write|snapshot|rollback|diff> <feature_dir> <action> [args...]}"
FEATURE_DIR="${2:?Usage: check-point.sh <read|write|snapshot|rollback|diff> <feature_dir> <action> [args...]}"
ACTION="${3:-}"

CHECKPOINT_FILE="$FEATURE_DIR/.workflow-state.json"
mkdir -p "$FEATURE_DIR/.artifacts"

HAS_JQ=false
command -v jq &>/dev/null && HAS_JQ=true

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

init_checkpoint() {
  if [ ! -f "$CHECKPOINT_FILE" ]; then
    cat > "$CHECKPOINT_FILE" <<'EOF'
{
  "version": "2.0",
  "metadata": {"created_at": "", "updated_at": "", "complexity": "medium", "total_tasks": 0},
  "tasks": {},
  "batch_plan": {},
  "stagnation": {"consecutive": 0, "last_done_count": 0},
  "retrospective": {"next_due": 5, "interval": 10},
  "workflow": {"current_phase": "init", "current_iteration": 0}
}
EOF
  fi
}

# ── JQ operations ───────────────────────────────────────────────
TS="$(now_utc)"

do_task_done_jq() {
  local tid="$1" tt="$2" built="$3" tf="$4"
  init_checkpoint
  local tmp; tmp=$(mktemp)
  jq --arg tid "$tid" --arg tt "$tt" --arg b "$built" --arg tf "$tf" --arg ts "$TS" \
    '.tasks[$tid]={"status":"DONE","type":$tt,"built":$b,"test_file":$tf,"checks":{},"revision_history":[],"completed_at":$ts} | .metadata.updated_at=$ts' \
    "$CHECKPOINT_FILE" > "$tmp" && mv "$tmp" "$CHECKPOINT_FILE"
}

do_task_in_progress_jq() {
  local tid="$1" tt="$2"
  init_checkpoint
  local tmp; tmp=$(mktemp)
  jq --arg tid "$tid" --arg tt "$tt" --arg ts "$TS" \
    '.tasks[$tid]={"status":"IN_PROGRESS","type":$tt,"started_at":$ts} | .metadata.updated_at=$ts' \
    "$CHECKPOINT_FILE" > "$tmp" && mv "$tmp" "$CHECKPOINT_FILE"
}

do_task_abandoned_jq() {
  local tid="$1" reason="$2"
  init_checkpoint
  local tmp; tmp=$(mktemp)
  jq --arg tid "$tid" --arg r "$reason" --arg ts "$TS" \
    '.tasks[$tid].status="ABANDONED" | .tasks[$tid].abandoned_reason=$r | .tasks[$tid].abandoned_at=$ts | .metadata.updated_at=$ts' \
    "$CHECKPOINT_FILE" > "$tmp" && mv "$tmp" "$CHECKPOINT_FILE"
}

# ── Fallback (no jq) — uses sed/grep for JSON manipulation ───────
# These functions modify .workflow-state.json without jq.
# Entries are single-line: "TASK-N": {...},
# We use sed to replace existing entries or awk to insert new ones.

do_task_done_fallback() {
  local tid="$1" tt="$2" built="$3" tf="$4"
  init_checkpoint
  local tmp; tmp=$(mktemp)

  local entry="    \"${tid}\": {\"status\":\"DONE\",\"type\":\"${tt}\",\"built\":\"${built}\",\"test_file\":\"${tf}\",\"completed_at\":\"${TS}\"}"

  if grep -q "\"${tid}\":" "$CHECKPOINT_FILE" 2>/dev/null; then
    # Replace existing single-line entry with sed
    sed "s|    \"${tid}\": {[^}]*}|${entry}|" "$CHECKPOINT_FILE" > "$tmp"
  else
    # Insert before "batch_plan"
    awk -v entry="$entry" '
      /^  "batch_plan"/ {
        printf "%s,\n", entry
      }
      { print }
    ' "$CHECKPOINT_FILE" > "$tmp"
  fi
  mv "$tmp" "$CHECKPOINT_FILE"
}

do_task_in_progress_fallback() {
  local tid="$1" tt="$2"
  init_checkpoint
  local tmp; tmp=$(mktemp)

  local entry="    \"${tid}\": {\"status\":\"IN_PROGRESS\",\"type\":\"${tt}\",\"started_at\":\"${TS}\"}"

  if grep -q "\"${tid}\":" "$CHECKPOINT_FILE" 2>/dev/null; then
    sed "s|    \"${tid}\": {[^}]*}|${entry}|" "$CHECKPOINT_FILE" > "$tmp"
  else
    awk -v entry="$entry" '
      /^  "batch_plan"/ {
        printf "%s,\n", entry
      }
      { print }
    ' "$CHECKPOINT_FILE" > "$tmp"
  fi
  mv "$tmp" "$CHECKPOINT_FILE"
}

# ── Snapshot mode (C5: Task rollback via file snapshot) ─────────
# Captures the pre-task file state before a task begins.
# Records which files exist and captures a git diff for rollback.
if [ "$MODE" = "snapshot" ]; then
  TASK_ID="${4:?Usage: check-point.sh snapshot <feature_dir> <task_id> <root_dir>}"
  ROOT_DIR="${5:?Usage: check-point.sh snapshot <feature_dir> <task_id> <root_dir>}"
  SNAP_DIR="$FEATURE_DIR/.artifacts/snapshots"
  mkdir -p "$SNAP_DIR"
  SNAP_FILE="$SNAP_DIR/${TASK_ID}.snapshot.json"
  SNAP_GIT_FILE="$SNAP_DIR/${TASK_ID}.git-diff.txt"

  # Capture git diff (unstaged changes) for this task's scope
  # We diff the entire repo but only keep files that are actually changed
  if [ -d "$ROOT_DIR/.git" ]; then
    (cd "$ROOT_DIR" && git diff --stat 2>/dev/null || true) > "$SNAP_GIT_FILE"
    (cd "$ROOT_DIR" && git diff 2>/dev/null || true) > "${SNAP_GIT_FILE%.txt}.patch"
  else
    echo "  No .git directory — snapshotting file list only" > "$SNAP_GIT_FILE"
  fi

  # Record pre-task state: list of tracked files with their current content hash
  SNAPSHOT_JSON="{"
  SNAPSHOT_JSON="${SNAPSHOT_JSON}\"task_id\":\"${TASK_ID}\","
  SNAPSHOT_JSON="${SNAPSHOT_JSON}\"snapshot_at\":\"${TS}\","
  SNAPSHOT_JSON="${SNAPSHOT_JSON}\"root_dir\":\"${ROOT_DIR}\","

  # Build file list: relative paths + their sha256 hashes
  FILE_LIST=""
  FILE_COUNT=0
  MAX_SNAPSHOT_FILES=200  # Limit to avoid bloating the checkpoint

  if [ -d "$ROOT_DIR" ]; then
    while IFS= read -r filepath; do
      [ "$FILE_COUNT" -ge "$MAX_SNAPSHOT_FILES" ] && break
      # Get relative path from root_dir
      rel_path="${filepath#$ROOT_DIR/}"
      # Skip git artifacts, node_modules, .artifacts, etc.
      case "$rel_path" in
        .git/*|.artifacts/*|node_modules/*|.next/*|dist/*|build/*|.specify/*) continue ;;
      esac
      # Skip binary files
      if file "$filepath" 2>/dev/null | grep -q 'text'; then
        hash_val=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1 || echo "unreadable")
      else
        hash_val="binary"
      fi
      if [ -n "$FILE_LIST" ]; then
        FILE_LIST="${FILE_LIST},"
      fi
      FILE_LIST="${FILE_LIST}\"${rel_path}\":\"${hash_val}\""
      FILE_COUNT=$((FILE_COUNT + 1))
    done < <(find "$ROOT_DIR" -type f 2>/dev/null | head -500)
  fi

  SNAPSHOT_JSON="${SNAPSHOT_JSON}\"files\":{${FILE_LIST}}},"
  SNAPSHOT_JSON="${SNAPSHOT_JSON}\"file_count\":${FILE_COUNT},"
  SNAPSHOT_JSON="${SNAPSHOT_JSON}\"git_diff_file\":\"${SNAP_GIT_FILE}\""
  SNAPSHOT_JSON="${SNAPSHOT_JSON}}"

  echo "$SNAPSHOT_JSON" > "$SNAP_FILE"
  echo "SNAPSHOT: $TASK_ID — captured $FILE_COUNT file hashes to $SNAP_FILE"
  echo "SNAPSHOT: git diff saved to ${SNAP_GIT_FILE%.txt}.patch"

  # Store snapshot reference in workflow checkpoint
  if [ "$HAS_JQ" = true ]; then
    tmp=$(mktemp)
    jq --arg tid "$TASK_ID" --arg snap "$SNAP_FILE" \
      '.tasks[$tid].snapshot_file=$snap | .metadata.updated_at="'"$TS"'"' \
      "$CHECKPOINT_FILE" > "$tmp" && mv "$tmp" "$CHECKPOINT_FILE"
  else
    # Fallback: just echo — snapshot file is on disk, checkpoint is secondary
    echo "SNAPSHOT: $TASK_ID checkpoint stored in $SNAP_FILE (no jq — checkpoint update skipped)"
  fi

  exit 0
fi

# ── Rollback mode (C5: Restore files to pre-task state) ─────────
# Restores files to their state before a specific task ran.
# Uses git checkout to restore tracked files, or file hashes for untracked.
if [ "$MODE" = "rollback" ]; then
  TASK_ID="${4:?Usage: check-point.sh rollback <feature_dir> <task_id>}"
  SNAP_FILE="$FEATURE_DIR/.artifacts/snapshots/${TASK_ID}.snapshot.json"
  SNAP_GIT_FILE="$FEATURE_DIR/.artifacts/snapshots/${TASK_ID}.git-diff.txt"
  SNAP_PATCH_FILE="${SNAP_GIT_FILE%.txt}.patch"

  if [ ! -f "$SNAP_FILE" ]; then
    echo "ROLLBACK: No snapshot found for $TASK_ID at $SNAP_FILE"
    echo "ROLLBACK: Cannot rollback without a prior snapshot."
    echo "ROLLBACK: Run 'check-point.sh snapshot <feature_dir> $TASK_ID <root_dir>' before starting the task."
    exit 1
  fi

  ROLLED_BACK=0
  ROLLED_BACK_ERRORS=0

  # Method 1: Use git checkout to restore tracked files
  if [ -f "$SNAP_PATCH_FILE" ] && [ -s "$SNAP_PATCH_FILE" ]; then
    # Reverse-apply the pre-task diff to undo any changes
    # First, save current state
    if git apply -R "$SNAP_PATCH_FILE" 2>/dev/null; then
      echo "ROLLBACK: $TASK_ID — reversed git diff (untracked changes restored)"
      ROLLED_BACK=$((ROLLED_BACK + 1))
    else
      echo "ROLLBACK: $TASK_ID — git reverse-apply failed, trying individual restore"
      ROLLED_BACK_ERRORS=$((ROLLED_BACK_ERRORS + 1))
    fi
  fi

  # Method 2: Use jq to extract file list and restore from checkpoint
  if [ "$HAS_JQ" = true ] && command -v jq &>/dev/null; then
    FILE_COUNT=$(jq '.file_count // 0' "$SNAP_FILE" 2>/dev/null || echo "0")
    if [ "$FILE_COUNT" -gt 0 ]; then
      # Extract files that existed before the task
      FILES_BEFORE=$(jq -r '.files | keys[]' "$SNAP_FILE" 2>/dev/null || true)
      ROOT_DIR=$(jq -r '.root_dir // "."' "$SNAP_FILE" 2>/dev/null || echo ".")

      while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        full_path="$ROOT_DIR/$rel_path"
        if [ -f "$full_path" ]; then
          # Check if file matches the pre-task hash
          current_hash=$(sha256sum "$full_path" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
          expected_hash=$(jq -r --arg f "$rel_path" '.files[$f] // ""' "$SNAP_FILE" 2>/dev/null || echo "")
          if [ "$current_hash" != "$expected_hash" ]; then
            # File was modified — try git checkout
            if git checkout HEAD -- "$full_path" 2>/dev/null; then
              echo "ROLLBACK: $TASK_ID — restored $rel_path via git"
              ROLLED_BACK=$((ROLLED_BACK + 1))
            else
              echo "ROLLBACK: $TASK_ID — could not restore $rel_path (untracked or no git history)"
              ROLLED_BACK_ERRORS=$((ROLLED_BACK_ERRORS + 1))
            fi
          fi
        fi
      done <<< "$FILES_BEFORE"
    fi
  fi

  echo "ROLLBACK: $TASK_ID — $ROLLED_BACK file(s) restored, $ROLLED_BACK_ERRORS error(s)"
  exit 0
fi

# ── Diff mode (C5: Show what files changed during a task) ───────
# Compares pre-task snapshot with current state.
if [ "$MODE" = "diff" ]; then
  TASK_ID="${4:?Usage: check-point.sh diff <feature_dir> <task_id>}"
  SNAP_FILE="$FEATURE_DIR/.artifacts/snapshots/${TASK_ID}.snapshot.json"

  if [ ! -f "$SNAP_FILE" ]; then
    echo "DIFF: No snapshot found for $TASK_ID"
    exit 1
  fi

  if [ "$HAS_JQ" = true ] && command -v jq &>/dev/null; then
    echo "DIFF: $TASK_ID — file changes since snapshot:"
    ROOT_DIR=$(jq -r '.root_dir // "."' "$SNAP_FILE" 2>/dev/null || echo ".")

    # Check each file from the snapshot
    FILES_BEFORE=$(jq -r '.files | keys[]' "$SNAP_FILE" 2>/dev/null || true)
    MODIFIED=0
    DELETED=0

    while IFS= read -r rel_path; do
      [ -z "$rel_path" ] && continue
      full_path="$ROOT_DIR/$rel_path"
      expected_hash=$(jq -r --arg f "$rel_path" '.files[$f] // ""' "$SNAP_FILE" 2>/dev/null || echo "")

      if [ ! -f "$full_path" ]; then
        echo "  DELETED: $rel_path"
        DELETED=$((DELETED + 1))
      elif [ "$expected_hash" != "binary" ] && [ "$expected_hash" != "" ]; then
        current_hash=$(sha256sum "$full_path" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        if [ "$current_hash" != "$expected_hash" ]; then
          echo "  MODIFIED: $rel_path (hash changed)"
          MODIFIED=$((MODIFIED + 1))
        fi
      fi
    done <<< "$FILES_BEFORE"

    # Also detect new files (git untracked)
    if [ -d "$ROOT_DIR/.git" ]; then
      NEW_FILES=$(cd "$ROOT_DIR" && git ls-files --others --exclude-standard 2>/dev/null || true)
      if [ -n "$NEW_FILES" ]; then
        echo "  NEW FILES:"
        echo "$NEW_FILES" | while IFS= read -r nf; do
          echo "    + $nf"
        done
      fi
    fi

    echo "DIFF: $TASK_ID — $MODIFIED modified, $DELETED deleted, new files listed above"
  else
    echo "DIFF: $TASK_ID — jq not available for detailed diff"
    echo "DIFF: Snapshot file: $SNAP_FILE"
  fi

  exit 0
fi

# ── Read mode ───────────────────────────────────────────────────
if [ "$MODE" = "read" ]; then
  if [ -f "$CHECKPOINT_FILE" ]; then
    cat "$CHECKPOINT_FILE"
  else
    echo "{}"
  fi
  exit 0
fi

# ── Write mode ──────────────────────────────────────────────────
if [ "$MODE" = "write" ]; then
  case "$ACTION" in
    task_done)
      if [ "$HAS_JQ" = true ]; then
        do_task_done_jq "$4" "$5" "$6" "$7"
      else
        do_task_done_fallback "$4" "$5" "$6" "$7"
      fi
      ;;
    task_in_progress)
      if [ "$HAS_JQ" = true ]; then
        do_task_in_progress_jq "$4" "$5"
      else
        do_task_in_progress_fallback "$4" "$5"
      fi
      ;;
    task_abandoned)
      if [ "$HAS_JQ" = true ]; then
        do_task_abandoned_jq "$4" "${5:-}"
      else
        tid="$4"
        reason="${5:-Manual abandon}"
        tmp=$(mktemp)
        entry="    \"${tid}\": {\"status\":\"ABANDONED\",\"abandoned_reason\":\"${reason}\",\"abandoned_at\":\"${TS}\"}"
        if grep -q "\"${tid}\":" "$CHECKPOINT_FILE" 2>/dev/null; then
          sed "s|    \"${tid}\": {[^}]*}|${entry}|" "$CHECKPOINT_FILE" > "$tmp"
        else
          awk -v entry="$entry" '
            /^  "batch_plan"/ {
              printf "%s,\n", entry
            }
            { print }
          ' "$CHECKPOINT_FILE" > "$tmp"
        fi
        mv "$tmp" "$CHECKPOINT_FILE"
      fi
      ;;
    *)
      echo "Unknown action: $ACTION" >&2
      exit 1
      ;;
  esac
else
  echo "Unknown mode: $MODE" >&2
  exit 1
fi
