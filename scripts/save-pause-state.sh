#!/usr/bin/env bash
# save-pause-state.sh — DEPRECATED: delegates to recovery-engine.sh
#
# Legacy interface: saves workflow pause state for resume.
# New code should use: recovery-engine.sh pause <feature_dir> <step_name>

set -euo pipefail

FEATURE_DIR="${1:?}"
STEP_NAME="${2:?}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPTS_DIR/recovery-engine.sh" pause "$FEATURE_DIR" "$STEP_NAME"
