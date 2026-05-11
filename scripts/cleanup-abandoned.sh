#!/usr/bin/env bash
# cleanup-abandoned.sh — DEPRECATED: delegates to recovery-engine.sh
#
# Legacy interface: cleans up files created by ABANDONED tasks.
# New code should use: recovery-engine.sh abandoned <feature_dir>

set -euo pipefail

FEATURE_DIR="${1:?Usage: cleanup-abandoned.sh <feature_dir>}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPTS_DIR/recovery-engine.sh" abandoned "$FEATURE_DIR"
