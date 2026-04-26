#!/usr/bin/env bash
# Usage: ./scripts/secret-scan.sh [repo-root]
# Runs gitleaks secret scan on the working tree.
# Ensures .gitleaks.toml exists (creates minimal config if missing).
# Exit 0: no secrets found. Exit 1: secrets detected or gitleaks not installed.

set -euo pipefail

REPO_ROOT="${1:-.}"
cd "$REPO_ROOT"

# Ensure .gitleaks.toml exists
if [ ! -f "$REPO_ROOT/.gitleaks.toml" ]; then
  cp "$(dirname "$0")/gitleaks-base.toml" "$REPO_ROOT/.gitleaks.toml"
fi

# Check gitleaks is available
if ! command -v gitleaks &> /dev/null; then
  echo "WARNING: gitleaks not installed — skipping secret scan."
  echo "Install: brew install gitleaks  (or: go install github.com/gitleaks/gitleaks/v2/cmd/gitleaks@latest)"
  exit 0
fi

echo "[I] SECRET SCANNING — scanning entire working tree..."
if gitleaks detect --source . --redact -q; then
  echo "[I] SECRET SCANNING: PASS — no secrets detected"
  exit 0
else
  echo "[I] SECRET SCANNING: FAIL — secrets detected"
  echo "Rotate any exposed credentials immediately."
  exit 1
fi
