#!/usr/bin/env bash
# context-rotate.sh — Context rotation for implement phase
#
# Usage: scripts/context-rotate.sh <feature_dir> [--force] [--help]
#
# Without --force: reads state.json for done_count vs rotation_threshold.
#   If exceeded: produces .artifacts/context-snapshot.json with aggregate summaries.
#   Prunes history to last 10 entries.
#   Resets per-task context cache in .artifacts/bundles/.
#
# --force: unconditional rotation — produces context snapshot, resets session_age
#          to 0, clears recent correction snapshots, outputs ROTATION=COMPLETE.
#          Used when context-health.sh reports SESSION_ROTATE_REQUIRED=true.

set -euo pipefail

FEATURE_DIR="${1:?Usage: scripts/context-rotate.sh <feature_dir> [--force]}"
FORCE=false

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --help)
      echo "Usage: scripts/context-rotate.sh <feature_dir> [--force]"
      exit 0
      ;;
    *) shift ;;
  esac
done
STATE_FILE="${FEATURE_DIR}/state.json"
BUNDLE_DIR="${FEATURE_DIR}/.artifacts/bundles"
SNAPSHOT_FILE="${FEATURE_DIR}/.artifacts/context-snapshot.json"

# Check state.json exists
if [ ! -f "$STATE_FILE" ]; then
  echo "CONTEXT_ROTATE: skipped (no state.json)"
  exit 0
fi

# Read done count and rotation threshold
DONE_COUNT=$(jq -r '[.tasks | to_entries[] | select(.value.status == "DONE")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
ROTATION_THRESHOLD=$(jq -r '.context.rotation_threshold // 10' "$STATE_FILE" 2>/dev/null || echo 10)

# Check if rotation is needed
if [ "$DONE_COUNT" -lt "$ROTATION_THRESHOLD" ]; then
  echo "CONTEXT_ROTATE: skipped (done=${DONE_COUNT} < threshold=${ROTATION_THRESHOLD})"
  exit 0
fi

# Check if already rotated this threshold cycle
GEN_COUNT=$(jq -r '.context.generation_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)
CYCLE=$(( DONE_COUNT / ROTATION_THRESHOLD ))

if [ "$GEN_COUNT" -ge "$CYCLE" ]; then
  echo "CONTEXT_ROTATE: skipped (already rotated for cycle ${CYCLE})"
  exit 0
fi

# Produce context snapshot: aggregate summaries by task type
echo "CONTEXT_ROTATE: rotating at done=${DONE_COUNT}, threshold=${ROTATION_THRESHOLD}"

# Build snapshot from state.json
jq --argjson gen "$((GEN_COUNT + 1))" '{
  generation: $gen,
  rotated_at: (now | todate),
  done_count: ([.tasks | to_entries[] | select(.value.status == "DONE")] | length),
  by_type: (.tasks | to_entries | group_by(.value.type) | map({
    type: .[0].value.type,
    count: length,
    recent: (sort_by(.value.status == "DONE" | not) | map({key: .key, title: .value.title}) | first)
  })),
  history_summary: {
    total_entries: (.history | length),
    last_phase: (.history[-1].phase // "none"),
    last_iteration: (.history[-1].iteration // 0)
  }
}' "$STATE_FILE" > "$SNAPSHOT_FILE" 2>/dev/null || {
  echo "CONTEXT_ROTATE: snapshot creation failed" >&2
  exit 0
}

# Update state.json: increment generation count
TMP=$(mktemp "${STATE_FILE}.XXXXXX")
jq --argjson gen "$((GEN_COUNT + 1))" \
  '.context.generation_count = $gen | .context.last_snapshot = $SNAPSHOT_FILE | .metadata.updated_at = (now | todate)' \
  "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"

# Prune history to last 10 entries
jq '.history = (.history[-10:]) | .metadata.updated_at = (now | todate)' "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"

# Reset per-task context cache (keep only last 5 bundles)
if [ -d "$BUNDLE_DIR" ]; then
  cd "$BUNDLE_DIR"
  ls -1t implement-*.md 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

  # (Fix 9) Also prune plan context bundles — keep only high-priority sections
  # Plan bundles are stored as implement-*.plan.md or context-plan-*.md
  ls -1t context-plan-*.md 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true

  cd - > /dev/null
fi

echo "CONTEXT_ROTATE: complete (generation=${GEN_COUNT + 1})"

# ── Force mode: unconditional rotation ──────────────────────────
if [ "$FORCE" = true ]; then
  echo "CONTEXT_ROTATE: forced rotation..."

  # 1. Produce a full context snapshot
  SNAPSHOT_PATH="${FEATURE_DIR}/.artifacts/context-snapshot-forced-$(date -u +%Y%m%d-%H%M%S).json"

  if [ -f "$STATE_FILE" ]; then
    cp "$STATE_FILE" "${SNAPSHOT_PATH}.state.json" 2>/dev/null || true
    if [ -f "${FEATURE_DIR}/tasks.md" ]; then
      cp "${FEATURE_DIR}/tasks.md" "${SNAPSHOT_PATH}.tasks.md" 2>/dev/null || true
    fi
    if [ -f "${FEATURE_DIR}/plan.md" ]; then
      cp "${FEATURE_DIR}/plan.md" "${SNAPSHOT_PATH}.plan.md" 2>/dev/null || true
    fi
    if [ -f "${FEATURE_DIR}/spec.md" ]; then
      cp "${FEATURE_DIR}/spec.md" "${SNAPSHOT_PATH}.spec.md" 2>/dev/null || true
    fi
    echo "CONTEXT_ROTATE: snapshot saved to ${SNAPSHOT_PATH}.*"
  fi

  # 2. Reset session_age to 0
  if [ -f "$STATE_FILE" ]; then
    local_tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq '.context.session_age = 0 | .context.last_rotation = (now | todate)' "$STATE_FILE" > "$local_tmp" 2>/dev/null && mv "$local_tmp" "$STATE_FILE" || rm -f "$local_tmp"
    echo "CONTEXT_ROTATE: session_age reset to 0"
  fi

  # 3. Clear recent correction snapshots (keep only last 2)
  local_snap_dir="${FEATURE_DIR}/.artifacts/correction-snapshots"
  if [ -d "$local_snap_dir" ]; then
    local_snap_count=$(find "$local_snap_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)
    if [ "$local_snap_count" -gt 2 ]; then
      find "$local_snap_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | \
        sort -rn | tail -n +3 | awk '{print $2}' | \
        xargs rm -rf 2>/dev/null || true
      echo "CONTEXT_ROTATE: cleaned up $((local_snap_count - 2)) old correction snapshots"
    fi
  fi

  # 4. Clear old prompt contexts (keep last 5)
  local_prompt_dir="${FEATURE_DIR}/.artifacts/prompts"
  if [ -d "$local_prompt_dir" ]; then
    local_ctx_count=$(find "$local_prompt_dir" -name "context.md" 2>/dev/null | wc -l || echo 0)
    if [ "$local_ctx_count" -gt 5 ]; then
      find "$local_prompt_dir" -name "context.md" -printf '%T@ %p\n' 2>/dev/null | \
        sort -rn | tail -n +6 | awk '{print $2}' | \
        xargs rm -f 2>/dev/null || true
      echo "CONTEXT_ROTATE: cleaned up $((local_ctx_count - 5)) old prompt contexts"
    fi
  fi

  echo "ROTATION=COMPLETE"
  echo "SNAPSHOT_PATH=${SNAPSHOT_PATH}"
fi
