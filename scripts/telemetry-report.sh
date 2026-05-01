#!/usr/bin/env bash
# Reads telemetry.json and prints a summary table
FEATURE_DIR="${FEATURE_DIR:-.}"
FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo ".")
TELEM_FILE="$FEATURE_DIR/.specify/state/telemetry.json"

if [ ! -f "$TELEM_FILE" ]; then
  echo "No telemetry data found."
  exit 0
fi

echo "=== Workflow Telemetry Report ==="
echo ""
echo "Started: $(grep -o '"started_at": "[^"]*"' "$TELEM_FILE" | sed 's/.*": "//;s/"//')"
echo ""
echo "Phases:"
grep -o '"[a-z_]*": {[^}]*}' "$TELEM_FILE" | sed 's/"\([^"]*\)": {[^}]*}/  \1/'
echo ""
echo "Gates: $(grep -c '"gate":' "$TELEM_FILE" 2>/dev/null || echo 0)"
echo "Tasks completed: $(grep -c '"task":' "$TELEM_FILE" 2>/dev/null || echo 0)"
