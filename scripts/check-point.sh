#!/usr/bin/env bash
# check-point.sh — DEPRECATED: delegates to recovery-engine.sh / state-engine.sh
#
# Legacy interface: read/write checkpoint, snapshot/rollback/diff
# New code should use: recovery-engine.sh checkpoint/restore/list/cleanup
#
# Usage:
#   check-point.sh read <feature_dir>
#   check-point.sh write <feature_dir> task_done|task_in_progress|task_abandoned ...
#   check-point.sh snapshot <feature_dir> <task_id> <root_dir>
#   check-point.sh rollback <feature_dir> <task_id>
#   check-point.sh diff <feature_dir> <task_id>

set -euo pipefail

MODE="${1:?Usage: check-point.sh <read|write|snapshot|rollback|diff> <feature_dir> <action> [args...]}"
FEATURE_DIR="${2:?Feature directory required}"
ACTION="${3:-}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Delegate task operations to state-engine.sh when available ───
if [ -f "$FEATURE_DIR/state.json" ]; then
  case "$MODE" in
    read)
      local_tasks=$(bash "$SCRIPTS_DIR/state-engine.sh" read "$FEATURE_DIR" tasks 2>/dev/null || echo '{}')
      cat <<EOF
{"version":"2.0","metadata":{"created_at":"","updated_at":"","complexity":"medium","total_tasks":0},"tasks":$local_tasks,"batch_plan":{},"stagnation":{"consecutive":0,"last_done_count":0},"retrospective":{"next_due":5,"interval":10},"workflow":{"current_phase":"init","current_iteration":0}}
EOF
      exit 0
      ;;
    write)
      case "$ACTION" in
        task_done)
          bash "$SCRIPTS_DIR/state-engine.sh" task-set "$FEATURE_DIR" "${4:?tid}" status DONE >/dev/null
          bash "$SCRIPTS_DIR/state-engine.sh" task-set "$FEATURE_DIR" "${4:?tid}" type "${5:?type}" >/dev/null
          bash "$SCRIPTS_DIR/state-engine.sh" task-set "$FEATURE_DIR" "${4:?tid}" revision_count 0 >/dev/null
          exit 0
          ;;
        task_in_progress)
          bash "$SCRIPTS_DIR/state-engine.sh" task-set "$FEATURE_DIR" "${4:?tid}" status IN_PROGRESS >/dev/null
          bash "$SCRIPTS_DIR/state-engine.sh" task-set "$FEATURE_DIR" "${4:?tid}" type "${5:?type}" >/dev/null
          exit 0
          ;;
        task_abandoned)
          bash "$SCRIPTS_DIR/state-engine.sh" task-set "$FEATURE_DIR" "${4:?tid}" status ABANDONED >/dev/null
          bash "$SCRIPTS_DIR/state-engine.sh" task-set "$FEATURE_DIR" "${4:?tid}" blocking_reason "${5:-Manual abandon}" >/dev/null
          exit 0
          ;;
      esac
      ;;
  esac
fi

# ── Snapshot/Rollback/Diff: legacy file-level operations (unchanged)
CHECKPOINT_FILE="$FEATURE_DIR/.workflow-state.json"
mkdir -p "$FEATURE_DIR/.artifacts"

HAS_JQ=false
command -v jq &>/dev/null && HAS_JQ=true

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

TS="$(now_utc)"

# ── Snapshot mode ────────────────────────────────────────────────
if [ "$MODE" = "snapshot" ]; then
  TASK_ID="${4:?Usage: check-point.sh snapshot <feature_dir> <task_id> <root_dir>}"
  ROOT_DIR="${5:?Usage: check-point.sh snapshot <feature_dir> <task_id> <root_dir>}"
  SNAP_DIR="$FEATURE_DIR/.artifacts/snapshots"
  mkdir -p "$SNAP_DIR"
  SNAP_FILE="$SNAP_DIR/${TASK_ID}.snapshot.json"
  SNAP_GIT_FILE="$SNAP_DIR/${TASK_ID}.git-diff.txt"

  if [ -d "$ROOT_DIR/.git" ]; then
    (cd "$ROOT_DIR" && git diff --stat 2>/dev/null || true) > "$SNAP_GIT_FILE"
    (cd "$ROOT_DIR" && git diff 2>/dev/null || true) > "${SNAP_GIT_FILE%.txt}.patch"
  else
    echo "  No .git directory — snapshotting file list only" > "$SNAP_GIT_FILE"
  fi

  FILE_LIST=""
  FILE_COUNT=0
  MAX_SNAPSHOT_FILES=200

  # Source from config if available
  if [ -f "$SCRIPTS_DIR/../ddd-clean-arch/workflow-config.json" ]; then
    val=$(bash "$SCRIPTS_DIR/workflow-config.sh" context.snapshot_max_files 2>/dev/null || echo "")
    [ -n "$val" ] && MAX_SNAPSHOT_FILES="$val"
  fi

  if [ -d "$ROOT_DIR" ]; then
    while IFS= read -r filepath; do
      [ "$FILE_COUNT" -ge "$MAX_SNAPSHOT_FILES" ] && break
      rel_path="${filepath#$ROOT_DIR/}"
      case "$rel_path" in
        .git/*|.artifacts/*|node_modules/*|.next/*|dist/*|build/*|.specify/*) continue ;;
      esac
      hash_val="binary"
      if file "$filepath" 2>/dev/null | grep -q 'text'; then
        hash_val=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1 || echo "unreadable")
      fi
      [ -n "$FILE_LIST" ] && FILE_LIST="${FILE_LIST},"
      FILE_LIST="${FILE_LIST}\"${rel_path}\":\"${hash_val}\""
      FILE_COUNT=$((FILE_COUNT + 1))
    done < <(find "$ROOT_DIR" -type f 2>/dev/null | head "$FIND_HEAD_LIMIT")

  # Source max files from config if available (for find limit)
  FIND_HEAD_LIMIT=500
  if [ -f "$SCRIPTS_DIR/../ddd-clean-arch/workflow-config.json" ]; then
    val=$(bash "$SCRIPTS_DIR/workflow-config.sh" other.check_point_max_files 2>/dev/null || echo "")
    [ -n "$val" ] && FIND_HEAD_LIMIT="$val"
  fi
  fi

  SNAPSHOT_JSON="{\"task_id\":\"${TASK_ID}\",\"snapshot_at\":\"${TS}\",\"root_dir\":\"${ROOT_DIR}\",\"files\":{${FILE_LIST}},\"file_count\":${FILE_COUNT},\"git_diff_file\":\"${SNAP_GIT_FILE}\"}"
  echo "$SNAPSHOT_JSON" > "$SNAP_FILE"

  echo "SNAPSHOT: $TASK_ID — captured $FILE_COUNT file hashes to $SNAP_FILE"
  echo "SNAPSHOT: git diff saved to ${SNAP_GIT_FILE%.txt}.patch"

  # Store snapshot reference in workflow checkpoint
  if [ -f "$CHECKPOINT_FILE" ] && [ "$HAS_JQ" = true ]; then
    tmp=$(mktemp)
    jq --arg tid "$TASK_ID" --arg snap "$SNAP_FILE" \
      '.tasks[$tid].snapshot_file=$snap | .metadata.updated_at="'"$TS"'"' \
      "$CHECKPOINT_FILE" > "$tmp" && mv "$tmp" "$CHECKPOINT_FILE"
  fi

  exit 0
fi

# ── Rollback mode ────────────────────────────────────────────────
if [ "$MODE" = "rollback" ]; then
  TASK_ID="${4:?Usage: check-point.sh rollback <feature_dir> <task_id>}"
  SNAP_FILE="$FEATURE_DIR/.artifacts/snapshots/${TASK_ID}.snapshot.json"
  SNAP_GIT_FILE="$FEATURE_DIR/.artifacts/snapshots/${TASK_ID}.git-diff.txt"
  SNAP_PATCH_FILE="${SNAP_GIT_FILE%.txt}.patch"

  if [ ! -f "$SNAP_FILE" ]; then
    echo "ROLLBACK: No snapshot found for $TASK_ID at $SNAP_FILE"
    exit 1
  fi

  ROLLED_BACK=0
  ROLLED_BACK_ERRORS=0

  if [ -f "$SNAP_PATCH_FILE" ] && [ -s "$SNAP_PATCH_FILE" ]; then
    if git apply -R "$SNAP_PATCH_FILE" 2>/dev/null; then
      echo "ROLLBACK: $TASK_ID — reversed git diff"
      ROLLED_BACK=$((ROLLED_BACK + 1))
    else
      ROLLED_BACK_ERRORS=$((ROLLED_BACK_ERRORS + 1))
    fi
  fi

  if [ "$HAS_JQ" = true ]; then
    FILE_COUNT=$(jq '.file_count // 0' "$SNAP_FILE" 2>/dev/null || echo "0")
    if [ "$FILE_COUNT" -gt 0 ]; then
      ROOT_DIR=$(jq -r '.root_dir // "."' "$SNAP_FILE" 2>/dev/null || echo ".")
      while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        full_path="$ROOT_DIR/$rel_path"
        if [ -f "$full_path" ]; then
          current_hash=$(sha256sum "$full_path" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
          expected_hash=$(jq -r --arg f "$rel_path" '.files[$f] // ""' "$SNAP_FILE" 2>/dev/null || echo "")
          if [ "$current_hash" != "$expected_hash" ]; then
            if git checkout HEAD -- "$full_path" 2>/dev/null; then
              ROLLED_BACK=$((ROLLED_BACK + 1))
            else
              ROLLED_BACK_ERRORS=$((ROLLED_BACK_ERRORS + 1))
            fi
          fi
        fi
      done < <(jq -r '.files | keys[]' "$SNAP_FILE" 2>/dev/null || true)
    fi
  fi

  echo "ROLLBACK: $TASK_ID — $ROLLED_BACK file(s) restored, $ROLLED_BACK_ERRORS error(s)"
  exit 0
fi

# ── Diff mode ────────────────────────────────────────────────────
if [ "$MODE" = "diff" ]; then
  TASK_ID="${4:?Usage: check-point.sh diff <feature_dir> <task_id>}"
  SNAP_FILE="$FEATURE_DIR/.artifacts/snapshots/${TASK_ID}.snapshot.json"

  if [ ! -f "$SNAP_FILE" ]; then
    echo "DIFF: No snapshot found for $TASK_ID"
    exit 1
  fi

  if [ "$HAS_JQ" = true ]; then
    echo "DIFF: $TASK_ID — file changes since snapshot:"
    ROOT_DIR=$(jq -r '.root_dir // "."' "$SNAP_FILE" 2>/dev/null || echo ".")
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
    done < <(jq -r '.files | keys[]' "$SNAP_FILE" 2>/dev/null || true)

    echo "DIFF: $TASK_ID — $MODIFIED modified, $DELETED deleted"
  else
    echo "DIFF: $TASK_ID — jq not available for detailed diff"
  fi

  exit 0
fi

# ── Read mode ────────────────────────────────────────────────────
if [ "$MODE" = "read" ]; then
  if [ -f "$CHECKPOINT_FILE" ]; then
    cat "$CHECKPOINT_FILE"
  else
    echo "{}"
  fi
  exit 0
fi

echo "Unknown mode: $MODE" >&2
exit 1
