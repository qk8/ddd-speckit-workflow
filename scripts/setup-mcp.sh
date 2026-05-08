#!/usr/bin/env bash
# Usage: bash scripts/setup-mcp.sh
#
# Installs Playwright MCP and Chrome DevTools MCP for Claude Code.
# Run once per machine (user-scoped, applies to all projects).
#
# Requirements:
#   - Claude Code CLI installed (claude --version)
#   - Node.js 18+ installed (node --version)
#   - Local machine only — does NOT work in claude.ai/code web sandbox.

set -euo pipefail

echo ""
echo "=== DDD Workflow — MCP Setup ==="
echo ""

# Check claude CLI
if ! command -v claude &> /dev/null; then
  echo "ERROR: Claude Code CLI not found."
  echo "Install it from: https://claude.ai/code"
  exit 1
fi

# Check node
if ! command -v node &> /dev/null; then
  echo "ERROR: Node.js not found. Install from https://nodejs.org"
  exit 1
fi

NODE_VERSION=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
if [ "$NODE_VERSION" -lt 18 ]; then
  echo "ERROR: Node.js 18+ required. Current: $(node --version)"
  exit 1
fi

echo "→ Installing Playwright browsers..."
npx playwright install chromium
echo "  ✓ Chromium installed"

echo ""
echo "→ Registering Playwright MCP (user-scoped)..."
claude mcp add playwright -s user -- npx @playwright/mcp@latest
echo "  ✓ Playwright MCP registered"

echo ""
echo "→ Registering Chrome DevTools MCP (user-scoped)..."
claude mcp add chrome-devtools -s user -- npx chrome-devtools-mcp@latest
echo "  ✓ Chrome DevTools MCP registered"

echo ""
echo "→ Verifying registration..."
MCP_LIST=$(claude mcp list 2>&1 || true)
if echo "$MCP_LIST" | grep -q "playwright"; then
  echo "  ✓ playwright present"
else
  echo "  ⚠ playwright not found in mcp list — check manually: claude mcp list"
fi
if echo "$MCP_LIST" | grep -q "chrome-devtools"; then
  echo "  ✓ chrome-devtools present"
else
  echo "  ⚠ chrome-devtools not found in mcp list — check manually: claude mcp list"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Playwright MCP:      browser testing (E2E, frontend-feature, user flows)"
echo "Chrome DevTools MCP: debugging (network, console errors, performance)"
echo ""
echo "Both are user-scoped and available in all Claude Code sessions on this machine."
echo "They do NOT work in the claude.ai/code web sandbox — local only."
echo ""
echo "Test the setup:"
echo "  claude"
echo "  > Use playwright mcp to open a browser to localhost and take a screenshot"
