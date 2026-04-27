#!/usr/bin/env bash
# Usage: ./scripts/secret-scan.sh [repo-root]
# Runs gitleaks secret scan on the working tree.
# Ensures .gitleaks.toml exists (creates minimal config if missing).
# Exit 0: no secrets found. Exit 1: secrets detected.
#
# NOTE: If gitleaks is not installed, the scan SKIPS (not passes).
# Output goes to stderr so CI pipelines can distinguish skip from pass.

set -euo pipefail

REPO_ROOT="${1:-.}"
cd "$REPO_ROOT"

# Ensure .gitleaks.toml exists
bash scripts/ensure-gitleaks-toml.sh "$REPO_ROOT"

# Check gitleaks is available
if ! command -v gitleaks &> /dev/null; then
  echo "WARNING: gitleaks not installed — secret scan SKIPPED (not passed)." >&2
  echo "Install: brew install gitleaks  (or: go install github.com/gitleaks/gitleaks/v8@latest)" >&2
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
