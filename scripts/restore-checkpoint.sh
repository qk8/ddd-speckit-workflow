#!/usr/bin/env bash
# restore-checkpoint.sh — User-facing checkpoint restore for the DDD Speckit Workflow
#
# Usage:
#   scripts/restore-checkpoint.sh <feature_dir> <checkpoint_id|--list> [--dry-run] [--confirm]
#
# Provides a safe rollback mechanism:
#   --list       List available checkpoints
#   --dry-run    Show diff without making changes
#   --confirm    Actually perform the restore
#
# Safety: --confirm flag required, never auto-deletes (backups to .artifacts/rollback-backup/),
#         logs to error-memory.json, uses file-lock.sh around tasks.md writes.
#
# Bash 3.2 compatible — no jq dependency in core logic.

set -euo pipefail

FEATURE_DIR="${1:?Usage: restore-checkpoint.sh <feature_dir> <checkpoint_id|--list> [--dry-run] [--confirm]}"
CHECKPOINT_ARG="${2:?Usage: restore-checkpoint.sh <feature_dir> <checkpoint_id|--list> [--dry-run] [--confirm]}"
DRY_RUN=false
CONFIRM=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=true ;;
    --confirm)  CONFIRM=true ;;
  esac
  shift
done

SNAP_DIR="$FEATURE_DIR/.artifacts/snapshots"
BACKUP_DIR="$FEATURE_DIR/.artifacts/rollback-backup"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

HAS_JQ=false
command -v jq &>/dev/null && HAS_JQ=true

# ── List mode ───────────────────────────────────────────────────
if [ "$CHECKPOINT_ARG" = "--list" ]; then
  echo "Available checkpoints:"
  if [ ! -d "$SNAP_DIR" ]; then
    echo "  (none — no snapshots directory found)"
    exit 0
  fi
  for snap_file in "$SNAP_DIR"/*.snapshot.json; do
    [ -f "$snap_file" ] || continue
    snap_basename=$(basename "$snap_file")
    if [ "$HAS_JQ" = true ]; then
      cid=$(jq -r '.task_id // "unknown"' "$snap_file" 2>/dev/null || echo "unknown")
      ts=$(jq -r '.snapshot_at // "unknown"' "$snap_file" 2>/dev/null || echo "unknown")
      fc=$(jq -r '.file_count // 0' "$snap_file" 2>/dev/null || echo "0")
    else
      cid=$(grep -oE '"task_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$snap_file" 2>/dev/null | head -1 | sed 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "unknown")
      ts=$(grep -oE '"snapshot_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$snap_file" 2>/dev/null | head -1 | sed 's/.*"snapshot_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "unknown")
      fc=$(grep -oE '"file_count"[[:space:]]*:[[:space:]]*[0-9]*' "$snap_file" 2>/dev/null | head -1 | sed 's/.*"file_count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/' || echo "0")
    fi
    echo "  $snap_basename | task: $cid | snapshot_at: $ts | files: $fc"
  done
  exit 0
fi

# ── Validate checkpoint exists ─────────────────────────────────
SNAP_FILE="$SNAP_DIR/${CHECKPOINT_ARG}.snapshot.json"
if [ ! -f "$SNAP_FILE" ]; then
  echo "ERROR: Snapshot not found: $CHECKPOINT_ARG"
  echo "  Expected: $SNAP_FILE"
  echo "  Run --list to see available checkpoints."
  exit 1
fi

# ── Dry-run mode: compute diff ─────────────────────────────────
if [ "$DRY_RUN" = true ]; then
  echo "DRY RUN — diff for $CHECKPOINT_ARG:"
  echo ""

  ROOT_DIR=""
  if [ "$HAS_JQ" = true ]; then
    ROOT_DIR=$(jq -r '.root_dir // "."' "$SNAP_FILE" 2>/dev/null || echo ".")
  else
    ROOT_DIR=$(grep -oE '"root_dir"[[:space:]]*:[[:space:]]*"[^"]*"' "$SNAP_FILE" 2>/dev/null | head -1 | sed 's/.*"root_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo ".")
  fi

  # Check files from snapshot
  MODIFIED=0
  DELETED=0

  if [ "$HAS_JQ" = true ]; then
    FILES_BEFORE=$(jq -r '.files | keys[]' "$SNAP_FILE" 2>/dev/null || true)
  else
    # Extract file keys from the files object using awk
    FILES_BEFORE=$(awk '
      /"files"/ { in_files=1; next }
      in_files && /\}/ { in_files=0 }
      in_files && /"[^"]+":/ {
        gsub(/^[[:space:]]*"/, "")
        gsub(/".*/, "")
        print
      }
    ' "$SNAP_FILE" 2>/dev/null)
  fi

  while IFS= read -r rel_path; do
    [ -z "$rel_path" ] && continue
    full_path="$ROOT_DIR/$rel_path"
    if [ ! -f "$full_path" ]; then
      echo "  DELETED: $rel_path"
      DELETED=$((DELETED + 1))
    else
      if [ "$HAS_JQ" = true ]; then
        expected_hash=$(jq -r --arg f "$rel_path" '.files[$f] // ""' "$SNAP_FILE" 2>/dev/null || echo "")
      else
        expected_hash=$(awk -v fp="$rel_path" '
          /"files"/ { in_files=1; next }
          in_files && /\}/ { in_files=0 }
          in_files && index($0, "\"" fp "\":") {
            gsub(/.*"[^"]*"[[:space:]]*:[[:space:]]*"/, "")
            gsub(/".*/, "")
            print
            exit
          }
        ' "$SNAP_FILE" 2>/dev/null || echo "")
      fi
      if [ "$expected_hash" != "binary" ] && [ "$expected_hash" != "" ]; then
        current_hash=$(sha256sum "$full_path" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        if [ "$current_hash" != "$expected_hash" ]; then
          echo "  MODIFIED: $rel_path (hash changed)"
          MODIFIED=$((MODIFIED + 1))
        fi
      fi
    fi
  done <<< "$FILES_BEFORE"

  # Detect new files
  NEW=0
  if [ -d "$ROOT_DIR/.git" ]; then
    NEW_FILES=$(cd "$ROOT_DIR" && git ls-files --others --exclude-standard 2>/dev/null || true)
    if [ -n "$NEW_FILES" ]; then
      echo "  NEW FILES:"
      echo "$NEW_FILES" | while IFS= read -r nf; do
        echo "    + $nf"
      done
      NEW=$(echo "$NEW_FILES" | wc -l | tr -d ' ')
    fi
  fi

  echo ""
  echo "SUMMARY: $MODIFIED modified, $DELETED deleted, $NEW new files"
  echo "Run with --confirm to perform the restore."
  exit 0
fi

# ── Confirm mode: perform restore ───────────────────────────────
if [ "$CONFIRM" != true ]; then
  echo "ERROR: --confirm flag required to perform restore."
  echo "  Run with --dry-run first to preview changes."
  exit 1
fi

echo "RESTORING: $CHECKPOINT_ARG"
echo ""

ROOT_DIR=""
TASK_ID_FROM_SNAP=""
if [ "$HAS_JQ" = true ]; then
  ROOT_DIR=$(jq -r '.root_dir // "."' "$SNAP_FILE" 2>/dev/null || echo ".")
  TASK_ID_FROM_SNAP=$(jq -r '.task_id // ""' "$SNAP_FILE" 2>/dev/null || echo "")
else
  ROOT_DIR=$(grep -oE '"root_dir"[[:space:]]*:[[:space:]]*"[^"]*"' "$SNAP_FILE" 2>/dev/null | head -1 | sed 's/.*"root_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo ".")
  TASK_ID_FROM_SNAP=$(grep -oE '"task_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$SNAP_FILE" 2>/dev/null | head -1 | sed 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
fi

mkdir -p "$BACKUP_DIR/$CHECKPOINT_ARG"

RESTORED=0
BACKED_UP=0
TASKS_RESET=0

# Step 1: Backup new (untracked) files
if [ -d "$ROOT_DIR/.git" ]; then
  NEW_FILES=$(cd "$ROOT_DIR" && git ls-files --others --exclude-standard 2>/dev/null || true)
  if [ -n "$NEW_FILES" ]; then
    echo "$NEW_FILES" | while IFS= read -r nf; do
      [ -z "$nf" ] && continue
      full_path="$ROOT_DIR/$nf"
      [ -f "$full_path" ] || continue
      backup_path="$BACKUP_DIR/$CHECKPOINT_ARG/$nf"
      mkdir -p "$(dirname "$backup_path")"
      cp "$full_path" "$backup_path"
      BACKED_UP=$((BACKED_UP + 1))
      echo "  BACKED UP: $nf -> $backup_path"
    done
  fi
fi

# Step 2: Restore modified files via git checkout
if [ "$HAS_JQ" = true ]; then
  FILES_BEFORE=$(jq -r '.files | keys[]' "$SNAP_FILE" 2>/dev/null || true)
else
  FILES_BEFORE=$(awk '
    /"files"/ { in_files=1; next }
    in_files && /\}/ { in_files=0 }
    in_files && /"[^"]+":/ {
      gsub(/^[[:space:]]*"/, "")
      gsub(/".*/, "")
      print
    }
  ' "$SNAP_FILE" 2>/dev/null)
fi

while IFS= read -r rel_path; do
  [ -z "$rel_path" ] && continue
  full_path="$ROOT_DIR/$rel_path"
  if [ -f "$full_path" ]; then
    if [ "$HAS_JQ" = true ]; then
      expected_hash=$(jq -r --arg f "$rel_path" '.files[$f] // ""' "$SNAP_FILE" 2>/dev/null || echo "")
    else
      expected_hash=$(awk -v fp="$rel_path" '
        /"files"/ { in_files=1; next }
        in_files && /\}/ { in_files=0 }
        in_files && index($0, "\"" fp "\":") {
          gsub(/.*"[^"]*"[[:space:]]*:[[:space:]]*"/, "")
          gsub(/".*/, "")
          print
          exit
        }
      ' "$SNAP_FILE" 2>/dev/null || echo "")
    fi
    if [ "$expected_hash" != "binary" ] && [ "$expected_hash" != "" ]; then
      current_hash=$(sha256sum "$full_path" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
      if [ "$current_hash" != "$expected_hash" ]; then
        if git -C "$ROOT_DIR" checkout HEAD -- "$full_path" 2>/dev/null; then
          echo "  RESTORED: $rel_path via git checkout"
          RESTORED=$((RESTORED + 1))
        fi
      fi
    fi
  fi
done <<< "$FILES_BEFORE"

# Step 3: Reset task states using file-lock.sh
TASKS_FILE="$FEATURE_DIR/tasks.md"
if [ -f "$TASKS_FILE" ] && [ -n "$TASK_ID_FROM_SNAP" ]; then
  # Get the task ID from the checkpoint snapshot name
  SNAPSHOT_TASK_ID=$(echo "$CHECKPOINT_ARG" | grep -oE 'TASK-[0-9]+' | head -1 || echo "")

  if [ -n "$SNAPSHOT_TASK_ID" ]; then
    # Tasks completed after the snapshot task should be reset
    # We reset all tasks with index > snapshot task index that are DONE/IN_PROGRESS
    awk -v snap_id="$SNAPSHOT_TASK_ID" '
      BEGIN { gsub(/TASK-/, "", snap_id); snap_num = snap_id + 0 }
      /^## TASK-/ {
        gsub(/^## /, "")
        gsub(/[^0-9]/, "")
        current_num = $0 + 0
        in_task = 1
        task_id = "## TASK-" $0
        next
      }
      in_task && /^Status: (DONE|IN_PROGRESS)$/ && current_num > snap_num {
        print task_id
      }
      in_task { }
    ' "$TASKS_FILE" 2>/dev/null | while IFS= read -r reset_task; do
      [ -z "$reset_task" ] && continue
      reset_tid=$(echo "$reset_task" | sed 's/^## //')
      if [ -f "$SCRIPT_DIR/file-lock.sh" ]; then
        bash "$SCRIPT_DIR/file-lock.sh" "$TASKS_FILE.lock" \
          bash "$SCRIPT_DIR/set-task-status.sh" "$TASKS_FILE" TODO "$reset_tid" "Reset by rollback to $CHECKPOINT_ARG" 2>/dev/null || true
      else
        bash "$SCRIPT_DIR/set-task-status.sh" "$TASKS_FILE" TODO "$reset_tid" "Reset by rollback to $CHECKPOINT_ARG" 2>/dev/null || true
      fi
      TASKS_RESET=$((TASKS_RESET + 1))
      echo "  TASK RESET: $reset_tid -> TODO"
    done
  fi
fi

# Step 4: Rebuild unified context
if [ -f "$SCRIPT_DIR/unified-context.sh" ] && [ -n "$TASK_ID_FROM_SNAP" ]; then
  # Extract task type from tasks.md if available
  TASK_TYPE="backend-domain"
  if [ -f "$TASKS_FILE" ]; then
    TASK_TYPE=$(awk -v tid="## $TASK_ID_FROM_SNAP" '
      $0 == tid { found=1; next }
      found && /^Type:/ { gsub(/^Type:[[:space:]]*/, ""); print; exit }
    ' "$TASKS_FILE" 2>/dev/null || echo "backend-domain")
  fi
  bash "$SCRIPT_DIR/unified-context.sh" "$FEATURE_DIR" "$TASK_ID_FROM_SNAP" "$TASK_TYPE" > /dev/null 2>&1 || true
  echo "  Unified context rebuilt."
fi

# Step 5: Log rollback in error-memory.json
if [ -f "$SCRIPT_DIR/error-memory.sh" ]; then
  bash "$SCRIPT_DIR/error-memory.sh" update "$FEATURE_DIR" "ROLLBACK" "checkpoint-restore" \
    "rolled back to $CHECKPOINT_ARG" "restore files and reset tasks" 2>/dev/null || true
  echo "  Rollback logged in error-memory.json."
fi

echo ""
echo "ROLLBACK COMPLETE: $CHECKPOINT_ARG"
echo "  Files restored: $RESTORED"
echo "  Files backed up: $BACKED_UP"
echo "  Tasks reset: $TASKS_RESET"
