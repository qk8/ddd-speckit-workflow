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
cat > "$HOOKS_DIR/pre-commit" << HOOK
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="\$(git rev-parse --show-toplevel)"
echo ""
echo "── pre-commit ─────────────────────────────────────"

# 1. SECRET SCAN
echo "→ Secret scan..."
if command -v gitleaks &>/dev/null; then
  if ! gitleaks protect --staged --no-banner 2>&1; then
    echo "BLOCKED: Secret detected in staged files."
    echo "Remove it. If false positive, add to .gitleaks.toml allowlist."
    exit 1
  fi
  echo "  ✓ No secrets"
else
  echo "  ⚠ gitleaks not installed. Run: bash scripts/setup-hooks.sh"
fi

# 2. LINT
echo "→ Lint..."
cd "\$REPO_ROOT"
if ! $LINT_CMD > /tmp/lint-out.txt 2>&1; then
  echo "BLOCKED: Lint errors."
  cat /tmp/lint-out.txt
  exit 1
fi
echo "  ✓ Lint passed"

# 3. NAMING VALIDATION
echo "→ Naming validation..."
if [ -f "\$REPO_ROOT/scripts/check-naming.sh" ] && [ -f "\$REPO_ROOT/plan.md" ]; then
  if ! bash "\$REPO_ROOT/scripts/check-naming.sh" > /tmp/naming-out.txt 2>&1; then
    echo "BLOCKED: Naming validation failed."
    cat /tmp/naming-out.txt
    exit 1
  fi
  echo "  ✓ Naming consistent"
elif [ -f "\$REPO_ROOT/scripts/check-naming.sh" ]; then
  echo "  ⚠ plan.md not found — naming validation skipped"
fi

echo "── pre-commit passed ──────────────────────────────"
echo ""
HOOK

chmod +x "$HOOKS_DIR/pre-commit"
echo "→ Hook written to .git/hooks/pre-commit"

# ── CREATE .gitleaks.toml IF MISSING ────────────────────────────────────────
if [ ! -f "$REPO_ROOT/.gitleaks.toml" ]; then
  # Copy base config, then append extended comments and examples
  cp "$(dirname "$0")/gitleaks-base.toml" "$REPO_ROOT/.gitleaks.toml"
  cat >> "$REPO_ROOT/.gitleaks.toml" << 'CFG'

# Add allowlist entries here for false positives.
# Example:
# [[rules]]
#   id = "test-token-allowlist"
#   [rules.allowlist]
#     regexes = ['''test-token-[a-z0-9]{8}''']
#     description = "Synthetic tokens used in unit test fixtures only"
CFG
  echo "→ .gitleaks.toml created"
fi

echo ""
echo "=== Done ==="
echo "Hook blocks commits with: secrets (gitleaks) | lint errors | naming violations"
echo "Emergency bypass (avoid): git commit --no-verify"
