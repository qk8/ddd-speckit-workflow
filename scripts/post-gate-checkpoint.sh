#!/usr/bin/env bash
# Post-gate checkpoint — writes checkpoint after review gates pass.
# Enables recovery to skip gates if session crashes mid-retrospective.
#
# Usage: post-gate-checkpoint.sh <feature_dir>
#
# Writes: .artifacts/checkpoint.json (overwrites post-verify checkpoint)

set -euo pipefail

FEATURE_DIR="${1:?Usage: post-gate-checkpoint.sh <feature_dir>}"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"

mkdir -p "$ARTIFACTS_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

cat > "$ARTIFACTS_DIR/checkpoint.json" <<EOF
{
  "phase": "implement_loop",
  "checkpoint": "post_gate",
  "timestamp": "$TIMESTAMP",
  "gates_passed": true
}
EOF

echo "Post-gate checkpoint written: $ARTIFACTS_DIR/checkpoint.json"
