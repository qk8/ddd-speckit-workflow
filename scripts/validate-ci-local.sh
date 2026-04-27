#!/usr/bin/env bash
# Usage: bash scripts/validate-ci-local.sh [--validate | --dry-run]
#
# Validates ci-local.sh command variables are properly configured.
# After plan-devex, all 8 command variables are empty placeholders.
# Running ci-local.sh with all empty commands silently reports "ALL STAGES PASSED"
# with zero actual tests — this script prevents that silent failure.
#
# Flags:
#   --validate  Check ci-local.sh commands (default). Returns 0 if valid, 1 if issues.
#   --dry-run   Run ci-local.sh in validate mode (adds --validate flag to the script).
#
# Exit codes:
#   0  All critical commands configured, no issues
#   1  One or more critical commands are empty (needs human attention)
#   2  ci-local.sh not found

set -euo pipefail

CI_LOCAL="scripts/ci-local.sh"
if [ ! -f "$CI_LOCAL" ]; then
  echo "ERROR: $CI_LOCAL not found"
  exit 2
fi

# Extract command variable values from ci-local.sh
extract_cmd() {
  grep "^${1}=" "$CI_LOCAL" | sed 's/^[^"]*"\([^"]*\)".*/\1/' | head -1
}

CRITICAL_CMDS=(
  "SECRET_SCAN_CMD"
  "LINT_CMD"
  "UNIT_TEST_CMD"
  "INTEGRATION_TEST_CMD"
  "API_TEST_CMD"
  "E2E_TEST_CMD"
)

OPTIONAL_CMDS=(
  "ARCH_TEST_CMD"
  "CONTRACT_TEST_CMD"
)

WARNINGS=()
ERRORS=()

# Check critical commands
for cmd_var in "${CRITICAL_CMDS[@]}"; do
  val=$(extract_cmd "$cmd_var")
  if [ -z "$val" ]; then
    ERRORS+=("CRITICAL: $cmd_var is empty — ci-local.sh will silently skip this stage")
  fi
done

# Check optional commands
for cmd_var in "${OPTIONAL_CMDS[@]}"; do
  val=$(extract_cmd "$cmd_var")
  if [ -z "$val" ]; then
    WARNINGS+=("WARNING: $cmd_var is empty — this stage will be skipped")
  fi
done

# Check command structure: basic sanity for non-empty commands
for cmd_var in "${CRITICAL_CMDS[@]}"; do
  val=$(extract_cmd "$cmd_var")
  if [ -n "$val" ]; then
    # Warn if command contains shell metacharacters that could be risky
    if echo "$val" | grep -qE '(\$\(|`|&&|\|\||;)' 2>/dev/null; then
      WARNINGS+=("WARNING: $cmd_var contains shell metacharacters — ensure it's safe for CI")
    fi
    # Warn if command references external tools not in common PATH
    cmd_name=$(echo "$val" | awk '{print $1}')
    if ! command -v "$cmd_name" &>/dev/null && [ "$cmd_name" != "node" ] && [ "$cmd_name" != "python" ]; then
      WARNINGS+=("WARNING: $cmd_var references '$cmd_name' which is not in PATH")
    fi
  fi
done

# Output results
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "=== VALIDATION FAILED ==="
  for err in "${ERRORS[@]}"; do
    echo "  $err"
  done
  echo ""
  echo "Fix ci-local.sh COMMANDS section before pushing."
  echo "See: scripts/ci-local.sh lines 21-28"
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo "=== WARNINGS ==="
  for warn in "${WARNINGS[@]}"; do
    echo "  $warn"
  done
fi

if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
  echo "OK: All critical commands configured, no issues found."
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
  exit 1
fi
