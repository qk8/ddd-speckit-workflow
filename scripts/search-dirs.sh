#!/usr/bin/env bash
set -euo pipefail
# Usage: source scripts/search-dirs.sh
#        or: eval "$(scripts/search-dirs.sh)"
#
# Sets SEARCH_DIRS array with existing source directories.
# Searches src/ and app/ directories; falls back to any top-level dirs.

SEARCH_DIRS=()
for dir in src app; do
  if [ -d "$dir" ]; then
    SEARCH_DIRS+=("$dir")
  fi
done
