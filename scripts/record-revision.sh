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
      /^### Revision/ { count++; if (count > trim) print; next }
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

# ── Fast path: state.json ──
if [ -f "$FEATURE_DIR/state.json" ]; then
  bash scripts/state-engine.sh history-append "$FEATURE_DIR" "{\"phase\":\"revise\",\"step\":\"$STEP_ID\",\"iteration\":$ITERATION,\"summary\":\"$SUMMARY\",\"timestamp\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}" >/dev/null 2>&1 || true
  # Also append to revision_history.md for human readability
  cat >> "$FEATURE_DIR/revision_history.md" <<EOF

### Revision $ITERATION — $STEP_ID
Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Summary: $SUMMARY
EOF
  exit 0
fi

HISTORY="$FEATURE_DIR/revision_history.md"
mkdir -p "$FEATURE_DIR"

cat >> "$HISTORY" <<EOF

### Revision $ITERATION — $STEP_ID
Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Summary: $SUMMARY
EOF
