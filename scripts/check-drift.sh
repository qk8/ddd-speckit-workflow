#!/usr/bin/env bash
# Parses drift check report and outputs PASS/FAIL status.
# Usage: check-drift.sh <feature_dir>
# Outputs: DRIFT_DETECTED=true|false, DRIFT_CLEAN=true|false, DRIFT_SKIP=true|false
set -euo pipefail

FEATURE_DIR="${1:?Usage: check-drift.sh <feature_dir>}"
REPORT=".artifacts/drift_check_report.md"
mkdir -p .artifacts

if [ ! -f "$REPORT" ]; then
  echo "DRIFT_SKIP=true"
  echo "No drift report — check [Z] was not triggered this round."
  exit 0
fi

FAIL_COUNT=$(grep -E '^\s*[0-9]+\.' "$REPORT" | grep -c 'FAIL' || true)
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "DRIFT_DETECTED=true"
  grep "FAIL" "$REPORT" >&2
else
  echo "DRIFT_CLEAN=true"
fi
