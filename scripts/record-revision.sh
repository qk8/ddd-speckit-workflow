#!/usr/bin/env bash
# Usage: bash scripts/record-revision.sh <step-id> <iteration> <summary>
#        bash scripts/record-revision.sh --trim <max_entries> [preset_path]
# Appends revision context to .specify/specs/[feature]/revision_history.md
# --trim: keep only the last N revision entries, trim the rest
set -euo pipefail

TRIM_MODE=false
TRIM_MAX=3

if [ "${1:-}" = "--trim" ]; then
  TRIM_MODE=true
  TRIM_MAX="${2:-3}"
fi

if [ "$TRIM_MODE" = true ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh)
  HISTORY="$FEATURE_DIR/revision_history.md"
  if [ ! -f "$HISTORY" ]; then
    exit 0
  fi

  TMPFILE=$(mktemp)
  TOTAL=$(grep -c "^### Revision" "$HISTORY" || true)
  if [ "$TOTAL" -le "$TRIM_MAX" ]; then
    cat "$HISTORY" > "$TMPFILE"
  else
    TRIM_COUNT=$((TOTAL - TRIM_MAX))
    awk -v trim="$TRIM_COUNT" '
      /^### Revision/ { count++; next }
      count <= trim { next }
      { print }
    ' "$HISTORY" > "$TMPFILE"
  fi
  mv "$TMPFILE" "$HISTORY"
  echo "TRIMMED: revision_history.md trimmed to last $TRIM_MAX entries (was $TOTAL)"
  exit 0
fi

STEP_ID="${1:?Usage: record-revision.sh <step-id> <iteration> <summary>}"
ITERATION="${2:?}"
SUMMARY="${3:?}"

FEATURE_DIR=$(bash scripts/find-first-feature.sh)
if [ -z "$FEATURE_DIR" ] || [ ! -d "$FEATURE_DIR" ]; then
  exit 0
fi

HISTORY="$FEATURE_DIR/revision_history.md"
mkdir -p "$FEATURE_DIR"

cat >> "$HISTORY" <<EOF

### Revision $ITERATION — $STEP_ID
Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Summary: $SUMMARY
EOF
