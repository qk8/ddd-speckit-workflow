#!/usr/bin/env bash
# Usage: bash scripts/setup-hooks.sh
#
# Installs pre-commit hooks:
#   1. Secret scanner (gitleaks) — blocks commits that contain credentials
#   2. Linter — blocks commits with lint errors
#   3. Naming validation — blocks commits with ubiquitous language violations
#
# Run once per developer per machine after cloning.

set -euo pipefail

REPO_ROOT="$(bash scripts/repo-root.sh)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

echo ""
echo "=== Pre-commit Hook Setup ==="
echo ""

if [ ! -d "$REPO_ROOT/.git" ]; then
  echo "ERROR: Not a git repository. Run 'git init' first."
  exit 1
fi

# ── DETECT OR INSTALL GITLEAKS ───────────────────────────────────────────────
GITLEAKS_AVAILABLE=false
if command -v gitleaks &>/dev/null; then
  GITLEAKS_AVAILABLE=true
  echo "→ gitleaks: found"
else
  echo "→ gitleaks: not found — attempting install..."
  if command -v brew &>/dev/null; then
    brew install gitleaks && GITLEAKS_AVAILABLE=true && echo "  ✓ installed via brew"
  elif command -v go &>/dev/null; then
    go install github.com/gitleaks/gitleaks/v8@latest && GITLEAKS_AVAILABLE=true && echo "  ✓ installed via go"
  else
    echo "  ⚠ Cannot auto-install. Install manually: https://github.com/gitleaks/gitleaks"
  fi
fi

# ── DETECT LINT COMMAND ──────────────────────────────────────────────────────
LINT_CMD="echo 'WARNING: lint command not configured in setup-hooks.sh'"
if [ -f "$REPO_ROOT/package.json" ] && grep -q '"lint"' "$REPO_ROOT/package.json" 2>/dev/null; then
  PKG_MGR="npm"
  [ -f "$REPO_ROOT/pnpm-lock.yaml" ] && PKG_MGR="pnpm"
  [ -f "$REPO_ROOT/yarn.lock" ] && PKG_MGR="yarn"
  LINT_CMD="$PKG_MGR run lint"
  echo "→ lint command: $LINT_CMD"
elif [ -f "$REPO_ROOT/build.gradle" ] || [ -f "$REPO_ROOT/build.gradle.kts" ]; then
  LINT_CMD="./gradlew lint"
  echo "→ lint command: $LINT_CMD"
elif [ -f "$REPO_ROOT/pom.xml" ]; then
  LINT_CMD="./mvnw checkstyle:check"
  echo "→ lint command: $LINT_CMD"
else
  echo "→ lint command: not detected — edit .git/hooks/pre-commit to set it"
fi

# ── WRITE HOOK ───────────────────────────────────────────────────────────────
# Copy template, then substitute LINT_CMD into the lint section
cp "$(dirname "$0")/pre-commit-template.sh" "$HOOKS_DIR/pre-commit"
sed -i "s|__LINT_CMD__|$LINT_CMD|" "$HOOKS_DIR/pre-commit"
chmod +x "$HOOKS_DIR/pre-commit"

chmod +x "$HOOKS_DIR/pre-commit"
echo "→ Hook written to .git/hooks/pre-commit"

# ── CREATE .gitleaks.toml IF MISSING ────────────────────────────────────────
# ensure-gitleaks-toml.sh creates base config if missing.
# If it created the file, append developer-friendly examples.
if ! bash scripts/ensure-gitleaks-toml.sh "$REPO_ROOT"; then
  cat >> "$REPO_ROOT/.gitleaks.toml" << 'CFG'

# Add allowlist entries here for false positives.
# Example:
# [[rules]]
#   id = "test-token-allowlist"
#   [rules.allowlist]
#     regexes = ['''test-token-[a-z0-9]{8}''']
#     description = "Synthetic tokens used in unit test fixtures only"
CFG
fi
echo "→ .gitleaks.toml ready"

echo ""
echo "=== Done ==="
echo "Hook blocks commits with: secrets (gitleaks) | lint errors | naming violations"
echo "Emergency bypass (avoid): git commit --no-verify"
