#!/usr/bin/env bash
# resolve-merge-conflicts.sh — Find and report merge conflict markers in feature files
#
# Usage: scripts/resolve-merge-conflicts.sh <feature_dir>
#
# Scans all files in the feature directory for git-style merge conflict
# markers (<<<<<<, ======, >>>>>>>>) and reports them.
#
# Output:
#   CONFLICTS=N
#   CONFLICT_FILES=<comma-separated list>
#   CONFLICT_STATUS=CLEAN|CONFLICTS_FOUND
#
# Always exits 0 (advisory to orchestrator).

set -euo pipefail

FEATURE_DIR="${1:?Usage: resolve-merge-conflicts.sh <feature_dir>}"

if [ ! -d "$FEATURE_DIR" ]; then
  echo "ERROR: Feature directory not found: $FEATURE_DIR" >&2
  exit 1
fi

CONFLICT_COUNT=0
CONFLICT_FILES=""

# Search for git-style merge conflict markers
# Patterns: <<<<<<< HEAD, =======, >>>>>>> branch
while IFS= read -r file; do
  [ -z "$file" ] && continue
  # Skip binary files
  if file "$file" 2>/dev/null | grep -q 'binary'; then
    continue
  fi

  # Check for conflict markers
  if grep -qE '^<<<<<<< |^=======|^>>>>>>> ' "$file" 2>/dev/null; then
    CONFLICT_COUNT=$((CONFLICT_COUNT + 1))
    local_rel="${file#${FEATURE_DIR}/}"
    if [ -z "$CONFLICT_FILES" ]; then
      CONFLICT_FILES="$local_rel"
    else
      CONFLICT_FILES="${CONFLICT_FILES}, $local_rel"
    fi

    # Show context around conflict markers
    echo "  CONFLICT: $local_rel"
    grep -nE '^<<<<<<< |^=======|^>>>>>>> ' "$file" 2>/dev/null | head -5 | while IFS= read -r line; do
      echo "    $line"
    done || true
  fi
done < <(find "$FEATURE_DIR" -type f \
  ! -path '*/.artifacts/*' \
  ! -path '*/.git/*' \
  ! -name '*.result' \
  ! -name '*.lock' \
  2>/dev/null | sort)

if [ "$CONFLICT_COUNT" -eq 0 ]; then
  echo "CONFLICT_STATUS=CLEAN"
  echo "CONFLICTS=0"
  echo "CONFLICT_FILES="
else
  echo "CONFLICT_STATUS=CONFLICTS_FOUND"
  echo "CONFLICTS=$CONFLICT_COUNT"
  echo "CONFLICT_FILES=$CONFLICT_FILES"
  echo ""
  echo "  NOTE: $CONFLICT_COUNT file(s) contain merge conflict markers."
  echo "  Resolve them manually or run: git checkout -- <file>"
fi

exit 0
