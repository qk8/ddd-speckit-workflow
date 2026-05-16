#!/usr/bin/env bash
# auto-approve-gate.sh — Check if all deterministic checks passed
#
# Usage: bash scripts/auto-approve-gate.sh <feature_dir>
#
# Reads .artifacts/check-results/ for all .result files.
# If all pass: outputs AUTO_APPROVE=YES
# If any fail: outputs AUTO_APPROVE=NO with list of failures
# Always exits 0 (advisory, enforced by gate)

set -euo pipefail

FEATURE_DIR="${1:?Usage: auto-approve-gate.sh <feature_dir>}"
RESULTS_DIR="$FEATURE_DIR/.artifacts/check-results"

if [ ! -d "$RESULTS_DIR" ]; then
  echo "AUTO_APPROVE=NO — no check results directory"
  echo "REASON: No deterministic checks have been run yet"
  exit 0
fi

# Count results
TOTAL=0
PASSED=0
FAILED=""

for result_file in "$RESULTS_DIR"/*.result; do
  [ -f "$result_file" ] || continue
  TOTAL=$(( TOTAL + 1 ))
  first_line=$(head -1 "$result_file" 2>/dev/null || echo "UNKNOWN")
  check_name=$(basename "$result_file" .result)
  if [ "$first_line" = "PASS" ]; then
    PASSED=$(( PASSED + 1 ))
  else
    FAILED="${FAILED}${FAILED:+, }${check_name}=$first_line"
  fi
done

if [ "$TOTAL" -eq 0 ]; then
  echo "AUTO_APPROVE=NO — no check results found"
  echo "REASON: Results directory exists but contains no .result files"
  exit 0
fi

if [ -n "$FAILED" ]; then
  echo "AUTO_APPROVE=NO"
  echo "FAILURES: $FAILED"
  echo "REASON: $TOTAL - $PASSED checks passed, $FAILED failed"
else
  echo "AUTO_APPROVE=YES"
  echo "PASSED: $PASSED / $TOTAL deterministic checks"
fi

exit 0
