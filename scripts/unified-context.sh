#!/usr/bin/env bash
# unified-context.sh — DEPRECATED: delegates to bundle-assembler.sh
#
# Legacy interface: produces .artifacts/unified-context.json for backward compat.
# New code should use: bundle-assembler.sh implement <task_id> <feature_dir>
#
# Usage: scripts/unified-context.sh <feature_dir> <task_id> <task_type>

set -euo pipefail

FEATURE_DIR="${1:?Usage: unified-context.sh <feature_dir> <task_id> <task_type>}"
TASK_ID="${2:?Usage: unified-context.sh <feature_dir> <task_id> <task_type>}"
TASK_TYPE="${3:?Usage: unified-context.sh <feature_dir> <task_id> <task_type>}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Delegate to bundle-assembler.sh for the implement phase
"$SCRIPTS_DIR/bundle-assembler.sh" implement "$TASK_ID" "$FEATURE_DIR" \
  --output "${FEATURE_DIR}/.artifacts/bundles/implement-${TASK_ID}.md" 2>&1

# Legacy: also produce unified-context.json for scripts that still read it
# (converts bundle markdown to a minimal JSON structure)
if [ -f "${FEATURE_DIR}/.artifacts/bundles/implement-${TASK_ID}.md" ]; then
  BUNDLE="${FEATURE_DIR}/.artifacts/bundles/implement-${TASK_ID}.md"
  OUTPUT="${FEATURE_DIR}/.artifacts/unified-context.json"
  mkdir -p "$(dirname "$OUTPUT")"
  # Minimal JSON wrapper around bundle — just enough for legacy consumers
  cat > "$OUTPUT" <<JSONEOF
{
  "version": 1,
  "meta": {
    "feature_dir": "$(echo "$FEATURE_DIR" | sed 's/"/\\"/g')",
    "task_id": "$TASK_ID",
    "task_type": "$TASK_TYPE",
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "source": "bundle-assembler.sh"
  },
  "bundle": "$(cat "$BUNDLE" | tr '\n' ' ' | sed 's/"/\\"/g')",
  "note": "DEPRECATED: Use .artifacts/bundles/implement-${TASK_ID}.md directly"
}
JSONEOF
fi

echo "UNIFIED CONTEXT: ${TASK_ID} (${TASK_TYPE}) → ${OUTPUT} (DEPRECATED — use bundle-assembler.sh)"
