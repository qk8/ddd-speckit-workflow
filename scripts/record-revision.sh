#!/usr/bin/env bash
# Usage: bash scripts/record-revision.sh <step-id> <iteration> <summary>
# Appends revision context to .specify/specs/[feature]/revision_history.md
set -euo pipefail

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
