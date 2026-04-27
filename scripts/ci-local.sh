#!/usr/bin/env bash
# Usage: bash scripts/ci-local.sh [--fast] [--e2e-only]
#
# Runs the full CI pipeline locally, in the same order and with the same
# commands that CI uses. Run before pushing to catch failures locally.
#
# Flags:
#   --fast      Skip E2E tests (stages 1-6 only). Fast enough for most commits.
#   --e2e-only  Run only E2E tests (stage 7). Use after frontend changes.
#   (no flag)   Run everything (stages 1-7).
#
# Commands are read from plan.md §13 regression_command and §14 task_runner.
# Edit the COMMANDS section below to match your project after plan phase completes.

set -euo pipefail

# ── EDIT THIS SECTION AFTER PLAN PHASE ───────────────────────────────────────
# Derive these from plan.md §13 and §14 after the plan is approved.
# Replace the placeholder strings with your actual commands.

SECRET_SCAN_CMD="gitleaks detect --source . --redact -q"
LINT_CMD=""              # e.g. "pnpm lint" | "./gradlew lint" | "npm run lint"
ARCH_TEST_CMD=""         # e.g. "./gradlew test --tests ArchitectureTest" | "pnpm arch:check"
UNIT_TEST_CMD=""         # e.g. "./gradlew test" | "pnpm test:unit" | "pytest tests/unit"
INTEGRATION_TEST_CMD=""  # e.g. "./gradlew integrationTest" | "pnpm test:integration"
API_TEST_CMD=""          # e.g. "./gradlew test --tests '*ApiTest'" | "npx playwright test --project=api"
CONTRACT_TEST_CMD=""     # e.g. "pnpm test:contract" | leave empty if not applicable
E2E_TEST_CMD=""          # e.g. "npx playwright test --project=e2e" | "pnpm test:e2e"

# ── DO NOT EDIT BELOW THIS LINE ──────────────────────────────────────────────

FAST=false
E2E_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --fast)     FAST=true ;;
    --e2e-only) E2E_ONLY=true ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

join_cmds() {
  # Join non-empty arguments with ' && '. Ignores empty args.
  local result=""
  for arg in "$@"; do
    if [ -n "$arg" ]; then
      if [ -n "$result" ]; then
        result="$result && $arg"
      else
        result="$arg"
      fi
    fi
  done
  echo "$result"
}

FAILED_STAGES=()
START_TIME=$(date +%s)

run_stage() {
  local num="$1"
  local name="$2"
  local cmd="$3"

  if [ -z "$cmd" ]; then
    echo -e "${YELLOW}[$num] $name — SKIPPED (command not configured in ci-local.sh)${NC}"
    return 0
  fi

  echo ""
  echo -e "${BLUE}[$num] $name${NC}"
  echo "    $ $cmd"

  local stage_start=$(date +%s)
  if eval "$cmd"; then
    local elapsed=$(( $(date +%s) - stage_start ))
    echo -e "${GREEN}    ✓ PASSED (${elapsed}s)${NC}"
  else
    local elapsed=$(( $(date +%s) - stage_start ))
    echo -e "${RED}    ✗ FAILED (${elapsed}s)${NC}"
    FAILED_STAGES+=("[$num] $name")
    return 1
  fi
}

echo ""
echo "════════════════════════════════════════"
echo "  CI Local — $(date '+%Y-%m-%d %H:%M:%S')"
if $FAST; then echo "  Mode: FAST (no E2E)"; fi
if $E2E_ONLY; then echo "  Mode: E2E ONLY"; fi
echo "════════════════════════════════════════"

STAGE_NAMES=("Secret scan (gitleaks)" "Lint + arch tests" "Unit tests" "Integration tests" "API tests" "Contract tests")
STAGE_CMDS=(
  "$SECRET_SCAN_CMD"
  "$(join_cmds "$LINT_CMD" "$ARCH_TEST_CMD")"
  "$UNIT_TEST_CMD"
  "$INTEGRATION_TEST_CMD"
  "$API_TEST_CMD"
  "$CONTRACT_TEST_CMD"
)
TOTAL_STAGES=${#STAGE_NAMES[@]}

print_summary() {
  local total_elapsed=$(( $(date +%s) - START_TIME ))
  echo ""
  echo "════════════════════════════════════════"
  if [ ${#FAILED_STAGES[@]} -eq 0 ]; then
    echo -e "  ${GREEN}ALL STAGES PASSED${NC} (${total_elapsed}s)"
    echo "  Safe to push."
  else
    echo -e "  ${RED}FAILED STAGES:${NC}"
    for stage in "${FAILED_STAGES[@]}"; do
      echo -e "    ${RED}✗ $stage${NC}"
    done
    echo ""
    echo "  Fix the failures before pushing."
    echo "  Tip: CI runs stages in the same order — fix the earliest failure first."
  fi
  echo "════════════════════════════════════════"
}

if $E2E_ONLY; then
  run_stage $((TOTAL_STAGES + 1)) "E2E tests (headless)" "$E2E_TEST_CMD"
else
  for i in "${!STAGE_NAMES[@]}"; do
    run_stage "$((i+1))" "${STAGE_NAMES[$i]}" "${STAGE_CMDS[$i]}" || { print_summary; exit 1; }
  done

  if ! $FAST; then
    run_stage $((TOTAL_STAGES + 1)) "E2E tests (headless)" "$E2E_TEST_CMD"
  else
    echo ""
    echo -e "${YELLOW}[$((TOTAL_STAGES + 1))] E2E tests — SKIPPED (--fast mode)${NC}"
  fi
fi

print_summary

if [ ${#FAILED_STAGES[@]} -gt 0 ]; then
  exit 1
fi
