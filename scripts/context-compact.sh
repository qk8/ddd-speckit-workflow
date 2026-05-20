#!/usr/bin/env bash
# context-compact.sh — DEPRECATED: delegates to context.py
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/context.py" compact "$@"
