#!/usr/bin/env bash
# Validate environment setup before running the workflow.
# Checks all prerequisites and reports exactly what's missing.
#
# Usage: bash scripts/validate-setup.sh
# Exit codes: 0 = all PASS (WARNs allowed), 1 = any FAIL
set -euo pipefail

FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0

report() {
  local level="$1" msg="$2"
  case "$level" in
    PASS) echo "CHECK [PASS]: $msg"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN) echo "CHECK [WARN]: $msg"; WARN_COUNT=$((WARN_COUNT + 1)) ;;
    FAIL) echo "CHECK [FAIL]: $msg"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
  esac
}

# ── 1. Specify CLI ──────────────────────────────────────────────
if command -v specify &>/dev/null; then
  SPEC_VERSION=$(specify --version 2>/dev/null | head -1 || echo "unknown")
  # Extract version number
  SPEC_VER_NUM=$(echo "$SPEC_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
  SPEC_MAJOR=$(echo "$SPEC_VER_NUM" | cut -d. -f1)
  SPEC_MINOR=$(echo "$SPEC_VER_NUM" | cut -d. -f2)
  if [ "${SPEC_MAJOR:-0}" -gt 0 ] || [ "${SPEC_MINOR:-0}" -ge 7 ]; then
    report PASS "specify CLI installed ($SPEC_VERSION, >= 0.7.2 required)"
  else
    report FAIL "specify CLI version $SPEC_VERSION found, >= 0.7.2 required"
  fi
else
  report FAIL "specify CLI not installed (run: uv tool install specify-cli --from git+https://github.com/github/spec-kit.git)"
fi

# ── 2. Node.js ──────────────────────────────────────────────────
if command -v node &>/dev/null; then
  NODE_VERSION=$(node --version 2>/dev/null || echo "unknown")
  NODE_MAJOR=$(echo "$NODE_VERSION" | grep -oE '[0-9]+' | head -1 || echo "0")
  if [ "${NODE_MAJOR:-0}" -ge 18 ]; then
    report PASS "Node.js $NODE_VERSION (>= 18 recommended for Playwright MCP)"
  else
    report WARN "Node.js $NODE_VERSION found, >= 18 recommended (Playwright MCP may not work)"
  fi
else
  report WARN "Node.js not installed (needed for Playwright MCP, npm tests)"
fi

# ── 3. gitleaks ─────────────────────────────────────────────────
if command -v gitleaks &>/dev/null; then
  GL_VERSION=$(gitleaks version 2>/dev/null | head -1 || echo "unknown")
  report PASS "gitleaks installed ($GL_VERSION, secret scanning available)"
else
  report WARN "gitleaks not installed (needed for secret scanning, run: bash scripts/setup-hooks.sh)"
fi

# ── 4. Git configuration ────────────────────────────────────────
if git config user.name &>/dev/null && git config user.email &>/dev/null; then
  report PASS "Git user configured ($(git config user.name) <$(git config user.email)>)"
else
  report FAIL "Git user.name and user.email not configured (required for commits)"
fi

# ── 5. Writable directories ─────────────────────────────────────
for dir in .artifacts .specify/specs .specify/memory; do
  if [ -d "$dir" ] && [ -w "$dir" ]; then
    report PASS "$dir exists and is writable"
  elif [ -d "$dir" ]; then
    report FAIL "$dir exists but is not writable"
  else
    report FAIL "$dir not found (create with: mkdir -p $dir)"
  fi
done

# ── 6. ShellCheck (Issue A: shell script fragility gate) ─────────
SHELLCHECK_AVAILABLE=false
if command -v shellcheck &>/dev/null; then
  SHELLCHECK_AVAILABLE=true
  report PASS "ShellCheck installed (shell script linting available)"
else
  report WARN "ShellCheck not installed (run: brew install shellcheck / apt install shellcheck / scoop install shellcheck)"
  report WARN "  Without ShellCheck, script syntax errors won't be caught before runtime"
fi

# ── 7. Bash version ─────────────────────────────────────────────
BASH_MAJOR="${BASH_VERSION%%.*}"
if [ "${BASH_MAJOR:-0}" -ge 4 ]; then
  report PASS "Bash $BASH_VERSION (bash 4+ detected)"
elif [ "${BASH_MAJOR:-0}" -ge 3 ]; then
  # Check for specific bash 3.2 features used in scripts
  if bash -c 'set -o pipefail' 2>/dev/null; then
    report PASS "Bash $BASH_VERSION (bash 3.2+ with pipefail support)"
  else
    report FAIL "Bash $BASH_VERSION — scripts require bash 3.2+ with pipefail support"
  fi
else
  report FAIL "Bash $BASH_VERSION — scripts require bash 3.2+"
fi

# ── 8. Validate scripts with ShellCheck (Issue A) ───────────────
if [ "$SHELLCHECK_AVAILABLE" = true ]; then
  SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
  SCRIPT_COUNT=$(find "$SCRIPTS_DIR" -name '*.sh' -not -name '*.sh.bak' | wc -l | tr -d ' ')
  FAIL_COUNT_SC=0
  while IFS= read -r script; do
    if ! shellcheck --shell=bash "$script" &>/dev/null; then
      FAIL_COUNT_SC=$((FAIL_COUNT_SC + 1))
    fi
  done < <(find "$SCRIPTS_DIR" -name '*.sh' -not -name '*.sh.bak')
  if [ "$FAIL_COUNT_SC" -gt 0 ]; then
    report FAIL "ShellCheck found issues in $FAIL_COUNT_SC of $SCRIPT_COUNT scripts"
  else
    report PASS "ShellCheck passed on all $SCRIPT_COUNT scripts"
  fi
else
  report WARN "Skipping ShellCheck validation (not installed)"
fi

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "Setup validation: $FAIL_COUNT FAIL, $WARN_COUNT WARN, $PASS_COUNT PASS"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Fix the FAIL items above before running the workflow."
  exit 1
fi

exit 0
