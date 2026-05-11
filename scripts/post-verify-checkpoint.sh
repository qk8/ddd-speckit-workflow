#!/usr/bin/env bash
# post-verify-checkpoint.sh — DEPRECATED: delegates to recovery-engine.sh
#
# Legacy interface: writes lightweight checkpoint after implement_verify.
# New code should use: recovery-engine.sh post-verify <feature_dir>

set -euo pipefail

FEATURE_DIR="${1:?Usage: post-verify-checkpoint.sh <feature_dir>}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPTS_DIR/recovery-engine.sh" post-verify "$FEATURE_DIR"
