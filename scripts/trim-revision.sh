#!/usr/bin/env bash
# Shorthand for trimming revision history to last N entries.
# Usage: trim-revision.sh [max_entries]
set -euo pipefail
MAX="${1:-3}"
bash scripts/record-revision.sh --trim "$MAX"
