#!/usr/bin/env bash
set -euo pipefail
# Usage: source scripts/require-file.sh
#        or: bash scripts/require-file.sh <path> <label>
#
# Ensures a file exists. Exits 1 with error message if not.
# If sourced, uses $1 and $2 as file path and label.

if [ $# -ge 2 ]; then
  _path="$1"; _label="$2"
elif [ $# -ge 1 ]; then
  _path="$1"; _label="$(basename "$_path")"
else
  echo "ERROR: require-file.sh requires a file path argument" >&2
  exit 2
fi

if [ ! -f "$_path" ]; then
  echo "ERROR: $_label not found at $_path"
  exit 1
fi
