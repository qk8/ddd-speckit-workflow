#!/usr/bin/env bash
# Checks CLAUDE.md line count against limit.
# Usage: check-claude-md-lines.sh [limit] [--hard]
#   --hard: exits non-zero if over limit (for workflow gate enforcement)
# Outputs: CLAUDE_MD_LINES_WARN=true|false, line count info
set -euo pipefail

CLAUDE_MD=".claude/CLAUDE.md"
HARD_MODE=false
LIMIT=150

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --hard) HARD_MODE=true ;;
    *) LIMIT="$arg" ;;
  esac
done

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
  echo "FAIL: CLAUDE.md is $LINES lines (limit: $LIMIT)."
  echo "       Must condense Architecture, Module boundaries, or Ubiquitous language sections."
  echo "CLAUDE_MD_LINES_WARN=true"
  if [ "$HARD_MODE" = true ]; then
    exit 1
  fi
else
  echo "PASS: CLAUDE.md is $LINES lines (limit: $LIMIT)"
  echo "CLAUDE_MD_LINES_WARN=false"
fi
