#!/usr/bin/env bash
# reset-stagnation.sh — DEPRECATED: delegates to recovery-engine.sh
#
# Legacy interface: resets stagnation state after troubleshooting.
# New code should use: recovery-engine.sh reset-stagnation <feature_dir>

set -euo pipefail

FEATURE_DIR="${1:?Usage: reset-stagnation.sh <feature_dir>}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPTS_DIR/recovery-engine.sh" reset-stagnation "$FEATURE_DIR"
