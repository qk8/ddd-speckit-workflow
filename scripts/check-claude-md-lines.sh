#!/usr/bin/env bash
# Checks CLAUDE.md line count against limit.
# Usage: check-claude-md-lines.sh [limit] [--hard] [--adaptive]
#   --hard: exits non-zero if over limit (for workflow gate enforcement)
#   --adaptive: derive limit from project-brief.md complexity
# Outputs: CLAUDE_MD_LINES_WARN=true|false, line count info
set -euo pipefail

CLAUDE_MD=".claude/CLAUDE.md"
HARD_MODE=false
ADAPTIVE=false
LIMIT=150

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --hard) HARD_MODE=true ;;
    --adaptive) ADAPTIVE=true ;;
    *) LIMIT="$arg" ;;
  esac
done

# Find CLAUDE.md — try feature dir first, then .claude/
FEATURE_DIR=""
if [ -f "project-brief.md" ]; then
  FEATURE_DIR="."
elif [ -d ".specify" ]; then
  FEATURE_DIR=$(find . -maxdepth 3 -name "project-brief.md" -exec dirname {} \; 2>/dev/null | head -1 || true)
fi
if [ -n "$FEATURE_DIR" ] && [ -f "${FEATURE_DIR}/CLAUDE.md" ]; then
  CLAUDE_MD="${FEATURE_DIR}/CLAUDE.md"
elif [ ! -f "$CLAUDE_MD" ]; then
  echo "SKIP: CLAUDE.md not yet created"
  echo "CLAUDE_MD_LINES_WARN=false"
  exit 0
fi

# Adaptive limit based on complexity
if [ "$ADAPTIVE" = true ] && [ -f "project-brief.md" ]; then
  COMPLEXITY=$(grep -E '^\s*Complexity:' project-brief.md 2>/dev/null | head -1 | sed 's/.*Complexity:\s*//' | tr -d '[:space:]' || echo "medium")
  case "$COMPLEXITY" in
    simple)  LIMIT=150 ;;
    medium)  LIMIT=200 ;;
    complex) LIMIT=250 ;;
    *)       LIMIT=150 ;;  # default
  esac
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
