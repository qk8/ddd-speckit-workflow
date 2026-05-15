#!/usr/bin/env bash
set -euo pipefail
# Usage: bash scripts/find-file.sh <filename>
# Searches for filename in current dir, then .specify/specs/*/
# Prints the full path if found, empty string otherwise.

FILENAME="${1:?Usage: bash scripts/find-file.sh <filename>}"

for dir in . .specify/specs/*; do
  if [ -f "$dir/$FILENAME" ]; then
    echo "$dir/$FILENAME"
    exit 0
  fi
done
