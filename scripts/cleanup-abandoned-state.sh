#!/usr/bin/env bash
# cleanup-abandoned-state.sh — DEPRECATED: delegates to recovery-engine.sh
#
# Legacy interface: cleanup on abort/stop paths.
# New code should use: recovery-engine.sh abort <feature_dir> [phase]

set -euo pipefail

FEATURE_DIR="${1:?Usage: cleanup-abandoned-state.sh <feature_dir> [phase]}"
PHASE="${2:-unknown}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPTS_DIR/recovery-engine.sh" abort "$FEATURE_DIR" "$PHASE"
