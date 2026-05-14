#!/usr/bin/env bash
# context-rotate.sh — Context rotation for implement phase
#
# Usage: scripts/context-rotate.sh <feature_dir>
#
# Reads state.json for done_count vs rotation_threshold.
# If exceeded: produces .artifacts/context-snapshot.json with aggregate summaries.
# Prunes history to last 10 entries.
# Resets per-task context cache in .artifacts/bundles/.

set -euo pipefail

FEATURE_DIR="${1:?Usage: scripts/context-rotate.sh <feature_dir>}"
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
  cd - > /dev/null
fi

echo "CONTEXT_ROTATE: complete (generation=${GEN_COUNT + 1})"
