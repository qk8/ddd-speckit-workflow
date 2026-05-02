#!/usr/bin/env bash
# Checks CLAUDE.md line count against advisory limit.
# Usage: check-claude-md-lines.sh [limit]
# Outputs: CLAUDE_MD_LINES_WARN=true|false, line count info
set -euo pipefail

CLAUDE_MD=".claude/CLAUDE.md"
LIMIT="${1:-100}"

if [ ! -f "$CLAUDE_MD" ]; then
  echo "SKIP: CLAUDE.md not yet created"
  echo "CLAUDE_MD_LINES_WARN=false"
  exit 0
fi

LINES=$(wc -l < "$CLAUDE_MD" | xargs)
if [ -s "$CLAUDE_MD" ] && [ "$(tail -c1 "$CLAUDE_MD" | wc -l)" -eq 0 ]; then
  LINES=$((LINES + 1))
fi

if [ "$LINES" -gt "$LIMIT" ]; then
  echo "WARN: CLAUDE.md is $LINES lines (advisory limit: $LIMIT). "
  echo "       Consider condensing Architecture and Module boundaries."
  echo "CLAUDE_MD_LINES_WARN=true"
else
  echo "PASS: CLAUDE.md is $LINES lines (limit: $LIMIT)"
  echo "CLAUDE_MD_LINES_WARN=false"
fi
