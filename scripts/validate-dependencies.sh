#!/usr/bin/env bash
# validate-dependencies.sh — Check all runtime dependencies with graceful degradation
#
# Usage: bash scripts/validate-dependencies.sh
#
# I4: Graceful dependency validation. Checks MCP servers, npm packages,
# Docker/Testcontainers, and database connectivity.
# Outputs a clear "missing" list with install commands.
#
# Exit codes:
#   0 = all critical deps present (warnings allowed)
#   1 = critical dependency missing
#   2 = optional dependency missing (workflow can continue with reduced functionality)

set -euo pipefail

FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0
SKIP_COUNT=0
MISSING_DETAILS=""

report() {
  local level="$1" msg="$2" install_cmd="${3:-}"
  case "$level" in
    PASS)   echo "DEP [PASS]: $msg"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN)   echo "DEP [WARN]: $msg"; WARN_COUNT=$((WARN_COUNT + 1))
            [ -n "$install_cmd" ] && echo "        Install: $install_cmd" ;;
    FAIL)   echo "DEP [FAIL]: $msg"; FAIL_COUNT=$((FAIL_COUNT + 1))
            [ -n "$install_cmd" ] && echo "        Install: $install_cmd"
            MISSING_DETAILS="${MISSING_DETAILS}FAIL: $msg\n" ;;
    SKIP)   echo "DEP [SKIP]: $msg"; SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
}

# ── 1. Core CLI tools ───────────────────────────────────────────
echo "━━━ Core CLI Tools ━━━"

if command -v specify &>/dev/null; then
  report PASS "specify CLI installed ($(specify --version 2>/dev/null | head -1))"
else
  report FAIL "specify CLI not installed" "uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"
fi

if command -v node &>/dev/null; then
  NODE_VER=$(node --version 2>/dev/null || echo "unknown")
  report PASS "Node.js $NODE_VER"
else
  report FAIL "Node.js not installed (needed for Playwright MCP, npm tests)" "brew install node  # or: https://nodejs.org/"
fi

if command -v npm &>/dev/null; then
  NPM_VER=$(npm --version 2>/dev/null || echo "unknown")
  report PASS "npm $NPM_VER"
else
  report WARN "npm not installed" "Included with Node.js"
fi

if command -v gitleaks &>/dev/null; then
  report PASS "gitleaks installed (secret scanning available)"
else
  report WARN "gitleaks not installed (secret scanning disabled)" "bash scripts/setup-hooks.sh"
fi

# ── 2. MCP Server Dependencies ─────────────────────────────────
echo ""
echo "━━━ MCP Server Dependencies ━━━"

# Check if MCP servers are configured
SETTINGS_FILE=".claude/settings.json"
MCP_CONFIGURED=false

if [ -f "$SETTINGS_FILE" ]; then
  if grep -q 'playwright\|chrome-devtools' "$SETTINGS_FILE" 2>/dev/null; then
    MCP_CONFIGURED=true
    echo "MCP servers configured in $SETTINGS_FILE"

    # Check Playwright browser binaries
    if command -v npx &>/dev/null; then
      if npx @anthropic-ai/mcp-installer --list 2>/dev/null | grep -q playwright; then
        report PASS "Playwright MCP server configured"
      else
        report WARN "Playwright MCP server not found in installed MCP servers"
        echo "        Install: bash scripts/setup-mcp.sh"
      fi
    fi

    # Check Chrome DevTools MCP
    if npx @anthropic-ai/mcp-installer --list 2>/dev/null | grep -q chrome-devtools; then
      report PASS "Chrome DevTools MCP server configured"
    else
      report WARN "Chrome DevTools MCP server not found in installed MCP servers"
      echo "        Install: bash scripts/setup-mcp.sh"
    fi
  else
    report SKIP "No MCP servers configured in $SETTINGS_FILE"
  fi
else
  report SKIP "$SETTINGS_FILE not found — MCP servers not configured"
fi

# ── 3. NPM Package Dependencies ─────────────────────────────────
echo ""
echo "━━━ NPM Package Dependencies ━━━"

# Check for common test/build tools
if [ -f "package.json" ]; then
  # Extract devDependencies
  if command -v npm &>/dev/null; then
    # Check if node_modules exists (dependencies installed)
    if [ -d "node_modules" ]; then
      report PASS "node_modules exists (dependencies installed)"

      # Check key packages
      for pkg in typescript vitest jest playwright archunit dependency-cruiser; do
        if [ -d "node_modules/$pkg" ] || command -v "$pkg" &>/dev/null; then
          report PASS "$pkg installed"
        else
          report WARN "$pkg not found (may not be needed for this project)"
        fi
      done
    else
      report WARN "node_modules not found (run: npm install)"
    fi
  fi
else
  report SKIP "package.json not found — npm dependencies not applicable"
fi

# ── 4. Docker / Testcontainers ──────────────────────────────────
echo ""
echo "━━━ Docker / Testcontainers ━━━"

if command -v docker &>/dev/null; then
  if docker info &>/dev/null 2>&1; then
    DOCKER_VER=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
    report PASS "Docker $DOCKER_VER (Testcontainers integration available)"
  else
    report WARN "Docker installed but daemon not running"
    echo "        Start: sudo systemctl start docker"
  fi
else
  report WARN "Docker not installed (needed for Testcontainers in integration tests)"
  echo "        Install: https://docs.docker.com/get-docker/"
fi

# ── 5. Database Connectivity ────────────────────────────────────
echo ""
echo "━━━ Database ━━━"

# Check for database tools
if command -v psql &>/dev/null; then
  report PASS "PostgreSQL client (psql) available"
elif command -v mysql &>/dev/null; then
  report PASS "MySQL client available"
elif command -v sqlite3 &>/dev/null; then
  report PASS "SQLite available"
else
  report WARN "No database client detected (integration tests may be limited)"
fi

# Check if a database is actually running (if config exists)
if [ -f ".env" ] || [ -f ".env.local" ]; then
  DB_URL=$(grep -oE 'DATABASE_URL=[^ ]+' .env 2>/dev/null | head -1 | cut -d= -f2 || true)
  if [ -z "$DB_URL" ]; then
    DB_URL=$(grep -oE 'DATABASE_URL=[^ ]+' .env.local 2>/dev/null | head -1 | cut -d= -f2 || true)
  fi
  if [ -n "$DB_URL" ]; then
    echo "  Database URL detected: ${DB_URL:0:30}..."
    # Don't actually connect — just note the config exists
    report PASS "Database URL configured in .env"
  else
    report SKIP "No DATABASE_URL found in .env files"
  fi
else
  report SKIP "No .env files found — database connectivity not checked"
fi

# ── 6. Language-specific tools ──────────────────────────────────
echo ""
echo "━━━ Language-Specific Tools ━━━"

# TypeScript/Node
if command -v tsc &>/dev/null; then
  report PASS "TypeScript compiler (tsc) available"
fi

# Python
if command -v python3 &>/dev/null; then
  PY_VER=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  report PASS "Python $PY_VER"
elif command -v python &>/dev/null; then
  PY_VER=$(python --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  report PASS "Python $PY_VER"
fi

# Go
if command -v go &>/dev/null; then
  GO_VER=$(go version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "unknown")
  report PASS "Go $GO_VER"
fi

# Java
if command -v java &>/dev/null; then
  JAVA_VER=$(java -version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  report PASS "Java $JAVA_VER"
fi

# Rust
if command -v cargo &>/dev/null; then
  report PASS "Rust/Cargo available"
fi

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "Dependency validation: $FAIL_COUNT FAIL, $WARN_COUNT WARN, $PASS_COUNT PASS, $SKIP_COUNT SKIP"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "CRITICAL: The following dependencies are missing:"
  echo -e "$MISSING_DETAILS"
  echo "Fix these before running the workflow."
  exit 1
fi

# Exit 2 if optional dependencies are missing (workflow can continue)
if [ "$WARN_COUNT" -gt 0 ]; then
  echo ""
  echo "WARNING: $WARN_COUNT optional dependency(ies) missing."
  echo "The workflow will continue with reduced functionality."
  exit 2
fi

exit 0
