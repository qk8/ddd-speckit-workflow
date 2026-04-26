#!/usr/bin/env bash
# Usage: source scripts/repo-root.sh
#        or: REPO_ROOT=$(scripts/repo-root.sh)
#
# Resolves to the repository root directory.
# Falls back to pwd if git rev-parse fails.

git rev-parse --show-toplevel 2>/dev/null || pwd
