#!/usr/bin/env bash
# Validates that ci-local.sh commands are populated (non-empty).
# Called by the workflow after plan-devex to catch empty COMMANDS.
#
# Usage: bash scripts/validate-ci-local-cmds.sh
# Output: PASS or FAIL with details.

set -euo pipefail

CI_SCRIPT="scripts/ci-local.sh"

if [ ! -f "$CI_SCRIPT" ]; then
  echo "SKIP: $CI_SCRIPT not found"
  exit 0
fi

# Extract command variable assignments from ci-local.sh COMMANDS section
# The section is between the comment markers on lines 17-28
MISSING=()
while IFS= read -r line; do
  # Skip comments and empty lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$line" ]] && continue

  # Extract variable name (before =)
  var="${line%%=*}"
  # Trim leading whitespace
  var=$(echo "$var" | sed 's/^[[:space:]]*//')

  # Extract value between first pair of double quotes after =
  # ci-local.sh format: VAR="value"  # comment
  # Step 1: get everything after the =
  raw=$(echo "$line" | sed 's/^[^=]*=//')
  # Step 2: extract between first pair of double quotes
  value=$(echo "$raw" | sed 's/^"\([^"]*\)".*/\1/')

  if [ -z "$value" ]; then
    MISSING+=("$var")
  fi
done < <(sed -n '/EDIT THIS SECTION/,/DO NOT EDIT/p' "$CI_SCRIPT")

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: ci-local.sh commands not yet populated by plan-devex:" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  echo "  Run the plan-devex step to populate these, or fill them manually." >&2
  echo "  Derive values from plan.md section 13 and section 14." >&2
  exit 1
fi

echo "PASS: ci-local.sh commands are populated (${#MISSING[@]} checked)"
exit 0
