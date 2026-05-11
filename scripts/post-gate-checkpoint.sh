#!/usr/bin/env bash
# post-gate-checkpoint.sh — DEPRECATED: delegates to recovery-engine.sh
#
# Legacy interface: writes checkpoint after review gates pass.
# New code should use: recovery-engine.sh post-gate <feature_dir>

set -euo pipefail

FEATURE_DIR="${1:?Usage: post-gate-checkpoint.sh <feature_dir>}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPTS_DIR/recovery-engine.sh" post-gate "$FEATURE_DIR"
