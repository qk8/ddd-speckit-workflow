#!/usr/bin/env bash
# Usage: bash scripts/ensure-gitleaks-toml.sh [repo-root]
# Ensures .gitleaks.toml exists at repo root.
# Creates it from gitleaks-base.toml if missing.
# Always exits 0 (script never fails — file existence is the goal).
# Used by: setup-hooks.sh (checks file existence directly),
#          secret-scan.sh (idempotent initialization).

REPO_ROOT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$REPO_ROOT/.gitleaks.toml" ]; then
  cp "$SCRIPT_DIR/gitleaks-base.toml" "$REPO_ROOT/.gitleaks.toml"
  echo "Created .gitleaks.toml from gitleaks-base.toml"
else
  echo ".gitleaks.toml already exists — skipping creation"
fi
exit 0
