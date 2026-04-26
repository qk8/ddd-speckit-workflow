#!/usr/bin/env bash
# Usage: bash scripts/ensure-gitleaks-toml.sh [repo-root]
# Ensures .gitleaks.toml exists at repo root.
# Creates it from gitleaks-base.toml if missing.
# Exit 0: created new file. Exit 1: already exists.
# Used by: setup-hooks.sh (to decide whether to append examples),
#          secret-scan.sh (idempotent initialization).

REPO_ROOT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$REPO_ROOT/.gitleaks.toml" ]; then
  cp "$SCRIPT_DIR/gitleaks-base.toml" "$REPO_ROOT/.gitleaks.toml"
  exit 0
fi
exit 1
