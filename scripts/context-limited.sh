#!/usr/bin/env bash
# Wrapper around prompt-factory.sh that enforces --max-lines.
# Used by speckit.context to prevent context window overflow.
#
# Usage:
#   bash scripts/context-limited.sh <max_lines> [prompt_factory_args...]
#
# Calls prompt-factory.sh with the accumulated context, then truncates
# the output to max_lines lines. Prints a warning if truncated.
#
# This provides a hard programmatic cap — the LLM cannot bypass it.

set -euo pipefail

MAX_LINES="${1:?Usage: context-limited.sh <max_lines> [args...]}"
shift

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_SCRIPT="$SCRIPTS_DIR/prompt-factory.sh"

if [ ! -f "$FACTORY_SCRIPT" ]; then
  echo "ERROR: prompt-factory.sh not found at $FACTORY_SCRIPT" >&2
  exit 1
fi

# Run the full context, capture to temp file
OUTPUT_FILE=$(mktemp)
trap 'rm -f "$OUTPUT_FILE"' EXIT

bash "$FACTORY_SCRIPT" "$@" > "$OUTPUT_FILE" 2>&1 || true

ACTUAL_LINES=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')

if [ "$ACTUAL_LINES" -gt "$MAX_LINES" ]; then
  head -n "$MAX_LINES" < "$OUTPUT_FILE"
  echo "" >&2
  echo "CONTEXT TRUNCATED: ${ACTUAL_LINES} lines reduced to ${MAX_LINES}. ${ACTUAL_LINES - MAX_LINES} lines omitted." >&2
  echo "Consider increasing --max-lines or narrowing scope." >&2
else
  cat "$OUTPUT_FILE"
fi

exit 0
