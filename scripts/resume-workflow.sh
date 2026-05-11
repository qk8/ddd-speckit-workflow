#!/usr/bin/env bash
# resume-workflow.sh — DEPRECATED: delegates to recovery-engine.sh
#
# Legacy interface: resumes a paused workflow.
# New code should use: recovery-engine.sh resume <feature_dir>

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

FEATURE_DIR=$(bash "$SCRIPTS_DIR/find-first-feature.sh")
if [ -z "$FEATURE_DIR" ] || [ ! -d "$FEATURE_DIR" ]; then
  echo "No feature directory found. Nothing to resume."
  exit 0
fi

bash "$SCRIPTS_DIR/recovery-engine.sh" resume "$FEATURE_DIR"
