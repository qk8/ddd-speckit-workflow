#!/usr/bin/env bash
# prompt-factory.sh — DEPRECATED: delegates to bundle-assembler.sh
#
# Legacy interface: produces .artifacts/prompts/<task_id>/context.md for backward compat.
# New code should use: bundle-assembler.sh implement <task_id> <feature_dir>
#
# Usage: scripts/prompt-factory.sh <feature_dir> <task_id> <task_type>

set -euo pipefail

FEATURE_DIR="${1:?Usage: prompt-factory.sh <feature_dir> <task_id> <task_type>}"
TASK_ID="${2:?Usage: prompt-factory.sh <feature_dir> <task_id> <task_type>}"
TASK_TYPE="${3:?Usage: prompt-factory.sh <feature_dir> <task_id> <task_type>}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Delegate to bundle-assembler.sh for the implement phase
"$SCRIPTS_DIR/bundle-assembler.sh" implement "$TASK_ID" "$FEATURE_DIR" \
  --output "${FEATURE_DIR}/.artifacts/prompts/${TASK_ID}/context.md" 2>&1

echo "PROMPT FACTORY: ${TASK_ID} (${TASK_TYPE}) → ${FEATURE_DIR}/.artifacts/prompts/${TASK_ID}/context.md (DEPRECATED — use bundle-assembler.sh)"
