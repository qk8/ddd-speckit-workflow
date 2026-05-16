#!/usr/bin/env bash
# check-runner.sh — Wrapper for check-runner-v2.sh
#
# This script exists as a compatibility layer. Command files (speckit.check.md,
# speckit.health.md, speckit.implement-verify.md) reference check-runner.sh,
# but the actual implementation lives in check-runner-v2.sh.
#
# Usage: scripts/check-runner.sh <feature_dir> <task_type> [--tier critical|secondary]

set -euo pipefail

exec "$(dirname "$0")/check-runner-v2.sh" "$@"
