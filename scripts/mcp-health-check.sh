#!/usr/bin/env bash
# MCP server health check before browser verification tasks.
# Usage: mcp-health-check.sh [--server playwright|chrome-devtools|all]
#
# Checks if configured MCP servers are responding.
# If a server is unavailable, outputs a warning and offers skip option.
#
# Output:
#   MCP_HEALTHY=true|false
#   MCP_MISSING=<comma-separated server names>
#   MCP_WARNING=<warning messages>

set -euo pipefail

SERVER="${1:-all}"
HEALTHY=true
MISSING=""
WARNINGS=""

check_server() {
  local server_name="$1"
  local server_cmd="$2"
  local server_args="$3"

  # Try to ping the MCP server via npx
  if command -v npx &>/dev/null; then
    # Quick smoke test: check if the package is installed
    if npx --yes "$server_name@latest" --help &>/dev/null 2>&1; then
      echo "OK: $server_name is available"
      return 0
    fi
    # Even if --help fails, check if the binary exists
    if command -v "$server_name" &>/dev/null; then
      echo "OK: $server_name binary found"
      return 0
    fi
  fi

  # Check if running inside claude.ai/code web sandbox (MCPs not supported)
  if [ -n "${CLAUDE_CODE_SANDBOX:-}" ]; then
    echo "SKIP: $server_name not available in web sandbox"
    return 0
  fi

  echo "UNAVAILABLE: $server_name — install with: npx $server_name@latest"
  return 1
}

echo "━━━ MCP Health Check ━━━"

case "$SERVER" in
  playwright)
    if ! check_server "playwright" "npx" "@playwright/mcp@latest"; then
      HEALTHY=false
      MISSING="playwright"
      WARNINGS="Browser verification tasks (check [H]) will be skipped or may fail without Playwright MCP."
    fi
    ;;
  chrome-devtools)
    if ! check_server "chrome-devtools" "npx" "chrome-devtools-mcp@latest"; then
      HEALTHY=false
      MISSING="chrome-devtools"
      WARNINGS="Chrome DevTools debugging not available. Network/console inspection will be limited."
    fi
    ;;
  all)
    SERVERS_OK=true
    if ! check_server "playwright" "npx" "@playwright/mcp@latest"; then
      SERVERS_OK=false
    fi
    if ! check_server "chrome-devtools" "npx" "chrome-devtools-mcp@latest"; then
      SERVERS_OK=false
    fi
    if [ "$SERVERS_OK" = false ]; then
      HEALTHY=false
      MISSING="playwright,chrome-devtools"
      WARNINGS="Some browser verification tasks will be skipped or may fail."
    fi
    ;;
  *)
    echo "ERROR: Unknown server '$SERVER'. Valid: playwright, chrome-devtools, all" >&2
    exit 1
    ;;
esac

echo ""
echo "MCP_HEALTHY=$HEALTHY"
echo "MCP_MISSING=$MISSING"
if [ -n "$WARNINGS" ]; then
  echo "MCP_WARNING=$WARNINGS"
fi

if [ "$HEALTHY" = false ]; then
  echo ""
  echo "WARNING: MCP servers are unavailable."
  echo "Browser verification (check [H]) may be skipped or produce incomplete results."
  echo "Install required MCP servers before running browser tasks:"
  echo "  npx @playwright/mcp@latest"
  echo "  npx chrome-devtools-mcp@latest"
fi

exit 0
