#!/usr/bin/env bash
# state-engine.sh — Thin wrapper around Python state engine (state.py)
# Replaces the 1,147-line Bash implementation with Python + SQLite.
# CLI contract is identical to the original state-engine.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check Python3 is available
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required but not installed" >&2
  exit 1
fi

exec python3 "$SCRIPT_DIR/state.py" "$@"
