#!/usr/bin/env bash
# Global scope audit — verifies every source file has a task owner.
# Scans all source files, checks each against task scope entries in tasks.md,
# flags files with no task owner (feature creep).
#
# Usage: scripts/scope-audit.sh <feature_dir> [--strict]
#
# Exit codes: 0 = all files have owners (or --strict not set), 1 = unowned files found (--strict)
#
# Reads:
#   .artifacts/created-files/<task_id>.files  (from track-created-files.sh)
#   tasks.md                                  (task scope definitions)
#
# Also scans the entire feature directory tree for any files not tracked.

set -euo pipefail

FEATURE_DIR="${1:?Usage: scope-audit.sh <feature_dir> [--strict]}"
STRICT=false

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=true ;;
  esac
  shift
done

TRACKING_DIR="$FEATURE_DIR/.artifacts/created-files"

# Resolve to absolute for consistency
ABS_FEATURE_DIR=$(cd "$FEATURE_DIR" && pwd)

# ── Collect all tracked files with task owners ──────────────────
# Use a temp file as a lookup: relative_path|task_id
OWNED_INDEX=$(mktemp)
trap 'rm -f "$OWNED_INDEX"' EXIT

if [ -d "$TRACKING_DIR" ]; then
  for tracking_file in "$TRACKING_DIR"/*.files; do
    [ -f "$tracking_file" ] || continue
    task_id=$(basename "$tracking_file" .files)
    while IFS= read -r filepath; do
      [ -z "$filepath" ] && continue
      # Normalize: if relative, make absolute from feature dir
      case "$filepath" in
        /*) abs_path="$filepath" ;;
        *)  abs_path="$ABS_FEATURE_DIR/$filepath" ;;
      esac
      echo "$abs_path|$task_id" >> "$OWNED_INDEX"
    done < "$tracking_file"
  done
fi

# ── Collect all source files in the feature directory ───────────
ALL_FILES=$(mktemp)
trap 'rm -f "$OWNED_INDEX" "$ALL_FILES"' EXIT

# Find all files, excluding .artifacts, .git, node_modules, etc.
# Use -print with relative paths by cd-ing into feature dir
(cd "$ABS_FEATURE_DIR" && find . -type f \
  -not -path '*/.artifacts/*' \
  -not -path '*/.git/*' \
  -not -path '*/node_modules/*' \
  -not -path '*/.specify/*' \
  -not -name '*.lock' \
  -not -name '*.pid' \
  2>/dev/null | sed 's|^\./||' | sort) > "$ALL_FILES"

TOTAL_FILES=$(wc -l < "$ALL_FILES" | tr -d ' ')

# ── Check each file for ownership ──────────────────────────────
UNOWNED=$(mktemp)
trap 'rm -f "$OWNED_INDEX" "$ALL_FILES" "$UNOWNED"' EXIT

while IFS= read -r rel_path; do
  [ -z "$rel_path" ] && continue
  abs_path="$ABS_FEATURE_DIR/$rel_path"

  # Check if file is in the owned index
  if ! grep -q "^${abs_path}|" "$OWNED_INDEX" 2>/dev/null; then
    echo "$abs_path" >> "$UNOWNED"
  fi
done < "$ALL_FILES"

UNOWNED_COUNT=$(wc -l < "$UNOWNED" | tr -d ' ')
OWNED_COUNT=$((TOTAL_FILES - UNOWNED_COUNT))

# ── Output report ──────────────────────────────────────────────
echo "=== SCOPE AUDIT ==="
echo "Feature: $(basename "$FEATURE_DIR")"
echo "Total files: $TOTAL_FILES"
echo "Owned: $OWNED_COUNT"
echo "Unowned: $UNOWNED_COUNT"

if [ "$UNOWNED_COUNT" -gt 0 ]; then
  echo ""
  echo "UNOWNED FILES (possible feature creep):"
  while IFS= read -r f; do
    echo "  $f"
  done < "$UNOWNED"

  if [ "$STRICT" = true ]; then
    echo ""
    echo "STRICT MODE: $UNOWNED_COUNT unowned file(s) found."
    echo "Either add them to a task scope, or remove them."
    exit 1
  fi
fi

echo ""
echo "PASS"
exit 0
