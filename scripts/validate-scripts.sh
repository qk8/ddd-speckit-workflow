#!/usr/bin/env bash
# validate-scripts.sh — ShellCheck gate for all workflow scripts
#
# Usage: bash scripts/validate-scripts.sh [--fix]
#
# Runs shellcheck on every .sh file in scripts/ and reports issues.
# --fix: attempt to auto-fix common shellcheck issues (SC2034, SC2086, etc.)
#
# Exit codes:
#   0 = all scripts pass shellcheck
#   1 = shellcheck not installed or issues found
#
# Issue A: Prevents shell script silent failures by catching syntax
# errors, unset variable usage, and other common shell pitfalls at
# setup time rather than at runtime during a long workflow execution.

set -euo pipefail

FIX_MODE=false
if [ "${1:-}" = "--fix" ]; then
  FIX_MODE=true
fi

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Check ShellCheck availability ────────────────────────────────
if ! command -v shellcheck &>/dev/null; then
  echo "ERROR: ShellCheck is not installed." >&2
  echo "Install it before running this validation:" >&2
  echo "  macOS:   brew install shellcheck" >&2
  echo "  Ubuntu:  apt install shellcheck" >&2
  echo "  Windows: scoop install shellcheck" >&2
  echo "  Docker:  docker run --rm -v \"$(pwd)/scripts:/scripts\" koalaman/shellcheck:stable /scripts/*.sh" >&2
  exit 1
fi

# ── Find all scripts ─────────────────────────────────────────────
SCRIPT_FILES=()
while IFS= read -r f; do
  SCRIPT_FILES+=("$f")
done < <(find "$SCRIPTS_DIR" -name '*.sh' -not -name '*.sh.bak' | sort)

SCRIPT_COUNT=${#SCRIPT_FILES[@]}
if [ "$SCRIPT_COUNT" -eq 0 ]; then
  echo "No scripts found in $SCRIPTS_DIR"
  exit 0
fi

echo "━━━ ShellCheck Validation ━━━"
echo "Scripts found: $SCRIPT_COUNT"
echo ""

# ── Run ShellCheck ───────────────────────────────────────────────
TOTAL_ISSUES=0
FILES_WITH_ISSUES=0

for script in "${SCRIPT_FILES[@]}"; do
  script_name=$(basename "$script")
  output=$(shellcheck --shell=bash "$script" 2>&1 || true)
  if [ -n "$output" ]; then
    issues=$(echo "$output" | grep -cE '^' || echo 0)
    TOTAL_ISSUES=$((TOTAL_ISSUES + issues))
    FILES_WITH_ISSUES=$((FILES_WITH_ISSUES + 1))
    echo "  FAIL: $script_name ($issues issue(s))"
    echo "$output" | head -10 | sed 's/^/    /'
    if [ "$issues" -gt 10 ]; then
      echo "    ... (truncated, $issues total)"
    fi
  fi
done

echo ""
echo "━━━ Results ━━━"
echo "Pass: $((SCRIPT_COUNT - FILES_WITH_ISSUES))"
echo "Fail: $FILES_WITH_ISSUES"
echo "Total issues: $TOTAL_ISSUES"
echo ""

if [ "$FILES_WITH_ISSUES" -gt 0 ]; then
  echo "Fix the issues above before running the workflow."
  if [ "$FIX_MODE" = true ]; then
    echo "Attempting auto-fix..."
    for script in "${SCRIPT_FILES[@]}"; do
      script_name=$(basename "$script")
      output=$(shellcheck --shell=bash --fix "$script" 2>&1 || true)
      if [ -n "$output" ]; then
        echo "  Could not auto-fix: $script_name"
      else
        echo "  Auto-fixed: $script_name"
      fi
    done
  fi
  exit 1
fi

echo "All scripts pass ShellCheck."
exit 0
