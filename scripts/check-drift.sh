#!/usr/bin/env bash
# Parses drift check report and outputs PASS/FAIL status.
# Usage: check-drift.sh <feature_dir> [--json] [--help]
# Outputs: DRIFT_DETECTED=true|false, DRIFT_CLEAN=true|false, DRIFT_SKIP=true|false
#          DRIFT_FAIL_COUNT=N, DRIFT_FAIL_LINES=...
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

# ── Parse flags ────────────────────────────────────────────────────
JSON_MODE=false
if [ "${1:-}" = "--json" ]; then
  JSON_MODE=true
  shift
fi
if [ "${1:-}" = "--help" ]; then
  check_help "check-drift.sh" "<feature_dir> [--json] [--help]"
fi

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(check_find_feature_dir "" || true)
fi
FEATURE_DIR="${FEATURE_DIR:-}"

if [ -z "$FEATURE_DIR" ]; then
  echo "DRIFT_SKIP=true"
  echo "No feature directory found."
  exit 0
fi

REPORT="$FEATURE_DIR/.artifacts/drift_check_report.md"
mkdir -p "$FEATURE_DIR/.artifacts"

if [ ! -f "$REPORT" ]; then
  echo "DRIFT_SKIP=true"
  echo "No drift report — check [Z] was not triggered this round."
  check_write_result "$FEATURE_DIR" "drift" "SKIP"
  exit 0
fi

FAIL_COUNT=$(grep -E '^\s*[0-9]+\.' "$REPORT" | grep -c 'FAIL' || true)
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "DRIFT_DETECTED=true"
  echo "DRIFT_FAIL_COUNT=${FAIL_COUNT}"
  # Collect FAIL lines for the gate message
  FAIL_LINES=$(grep "FAIL" "$REPORT" | head -20 | sed "s/'/\\\\'/g")
  echo "DRIFT_FAIL_LINES='${FAIL_LINES}'"
  echo "$FAIL_LINES" >&2
  check_write_result "$FEATURE_DIR" "drift" "FAIL" "$FAIL_LINES"
else
  echo "DRIFT_CLEAN=true"
  check_write_result "$FEATURE_DIR" "drift" "PASS"
fi
exit 0
