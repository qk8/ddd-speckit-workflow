#!/usr/bin/env bash
# Tests for scripts/repo-root.sh
# Usage: . scripts/tests/test_repo-root.sh

# Test: repo-root.sh outputs a non-empty path
REPO_ROOT_OUTPUT=$(bash scripts/repo-root.sh)
assert_contains "$REPO_ROOT_OUTPUT" "ddd-speckit-boilerplate" "repo-root.sh outputs the repo path"

# Test: the output directory actually exists
[ -d "$REPO_ROOT_OUTPUT" ] || { echo "FAIL: repo-root.sh output is not a directory" >&2; exit 1; }

# Test: the output directory contains .git
[ -d "$REPO_ROOT_OUTPUT/.git" ] || { echo "FAIL: repo-root.sh output does not contain .git" >&2; exit 1; }
