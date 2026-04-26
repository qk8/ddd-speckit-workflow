#!/usr/bin/env bash
# Usage: source scripts/find-first-feature.sh
#        or: FEATURE_DIR=$(scripts/find-first-feature.sh)
#
# Finds the first feature directory under .specify/specs/.
# Outputs the path to stdout.
# Exits 0 with empty output if no feature directory exists.

SPECS_DIR="${SPECS_DIR:-.specify/specs}"
find "$SPECS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n 1
