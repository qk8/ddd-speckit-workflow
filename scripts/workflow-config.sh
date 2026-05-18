#!/usr/bin/env bash
# workflow-config.sh — Centralized workflow configuration reader
#
# Usage:
#   workflow-config.sh <key>                    — print value
#   workflow-config.sh <key> --json             — print raw JSON value
#   workflow-config.sh --defaults               — print all key=value pairs
#   workflow-config.sh --list                   — list all available keys
#   workflow-config.sh --config PATH            — use alternate config file
#
# Dot-notation keys: "iteration_limits.implement_loop"
# Exit 1 on missing key (fail loudly).
#
# Config file: ddd-clean-arch/workflow-config.json

set -euo pipefail

CONFIG_FILE="ddd-clean-arch/workflow-config.json"
JSON_MODE=false
LIST_MODE=false
DEFAULTS_MODE=false
KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)      JSON_MODE=true; shift ;;
    --list)      LIST_MODE=true; shift ;;
    --defaults)  DEFAULTS_MODE=true; shift ;;
    --config)    CONFIG_FILE="$2"; shift 2 ;;
    *)           KEY="$1"; shift ;;
  esac
done

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

if $LIST_MODE; then
  jq -r 'paths(scalars) | select(.[0] != "_meta") | join(".")' "$CONFIG_FILE"
  exit 0
fi

if $DEFAULTS_MODE; then
  jq -r 'paths(scalars) as $p | select($p[0] != "_meta") | "\($p | join("."))=\(getpath($p))"' "$CONFIG_FILE"
  exit 0
fi

if [ -z "$KEY" ]; then
  echo "Usage: workflow-config.sh <key> [--json] [--config PATH]" >&2
  exit 1
fi

# Normalize hyphens to underscores (YAML gate types use hyphens, JSON keys use underscores)
KEY=$(echo "$KEY" | tr '-' '_')

# Convert dot notation to jq getpath array: "a.b.c" → ["a","b","c"]
JQ_PATH=$(echo "$KEY" | sed 's/\./","/g' | sed 's/^/["/' | sed 's/$/"]/')

# Check if key exists first (jq returns null for missing keys with exit 0)
if ! jq -e "getpath($JQ_PATH) != null" "$CONFIG_FILE" >/dev/null 2>&1; then
  echo "ERROR: Key not found: $KEY" >&2
  echo "Available keys:" >&2
  jq -r 'paths(scalars) | select(.[0] != "_meta") | join(".")' "$CONFIG_FILE" >&2
  exit 1
fi

VALUE=$(jq -r "getpath($JQ_PATH)" "$CONFIG_FILE")

if $JSON_MODE; then
  jq "getpath($JQ_PATH)" "$CONFIG_FILE"
else
  echo "$VALUE"
fi
