#!/usr/bin/env bash
set -euo pipefail
# Shared cadence defaults — mirror of preset.yml cadence section.
# Source this file: source scripts/cadence-defaults.sh
#
# These defaults are used when preset.yml is missing or unreadable.
# Keep in sync with ddd-clean-arch/preset.yml cadence section.
# Values sourced from ddd-clean-arch/workflow-config.json when available.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/ddd-clean-arch/workflow-config.json"

if [ -f "$CONFIG" ]; then
  CADENCE_RETRO_INTERVAL_SIMPLE=$(bash "$SCRIPT_DIR/workflow-config.sh" cadence.retro_interval.simple 2>/dev/null || echo 15)
  CADENCE_RETRO_INTERVAL_MEDIUM=$(bash "$SCRIPT_DIR/workflow-config.sh" cadence.retro_interval.medium 2>/dev/null || echo 10)
  CADENCE_RETRO_INTERVAL_COMPLEX=$(bash "$SCRIPT_DIR/workflow-config.sh" cadence.retro_interval.complex 2>/dev/null || echo 5)
  CADENCE_FIRST_RETRO_THRESHOLD=$(bash "$SCRIPT_DIR/workflow-config.sh" cadence.first_retro_threshold 2>/dev/null || echo 5)
  CADENCE_TRACEABILITY_INTERVAL_SIMPLE=$(bash "$SCRIPT_DIR/workflow-config.sh" cadence.traceability_check_interval.simple 2>/dev/null || echo 25)
  CADENCE_TRACEABILITY_INTERVAL_MEDIUM=$(bash "$SCRIPT_DIR/workflow-config.sh" cadence.traceability_check_interval.medium 2>/dev/null || echo 20)
  CADENCE_TRACEABILITY_INTERVAL_COMPLEX=$(bash "$SCRIPT_DIR/workflow-config.sh" cadence.traceability_check_interval.complex 2>/dev/null || echo 15)
else
  CADENCE_RETRO_INTERVAL_SIMPLE=15
  CADENCE_RETRO_INTERVAL_MEDIUM=10
  CADENCE_RETRO_INTERVAL_COMPLEX=5
  CADENCE_FIRST_RETRO_THRESHOLD=5
  CADENCE_TRACEABILITY_INTERVAL_SIMPLE=25
  CADENCE_TRACEABILITY_INTERVAL_MEDIUM=20
  CADENCE_TRACEABILITY_INTERVAL_COMPLEX=15
fi

# Get cadence value by key: cadence_get retro_interval simple
# Returns empty string if key not found.
cadence_get() {
  local key="${1:-}"
  local sub="${2:-}"
  case "${key}_${sub}" in
    retro_interval_simple)      echo "$CADENCE_RETRO_INTERVAL_SIMPLE" ;;
    retro_interval_medium)      echo "$CADENCE_RETRO_INTERVAL_MEDIUM" ;;
    retro_interval_complex)     echo "$CADENCE_RETRO_INTERVAL_COMPLEX" ;;
    first_retro_threshold)      echo "$CADENCE_FIRST_RETRO_THRESHOLD" ;;
    traceability_interval_simple) echo "$CADENCE_TRACEABILITY_INTERVAL_SIMPLE" ;;
    traceability_interval_medium) echo "$CADENCE_TRACEABILITY_INTERVAL_MEDIUM" ;;
    traceability_interval_complex) echo "$CADENCE_TRACEABILITY_INTERVAL_COMPLEX" ;;
  esac
}

# List all known cadence counter keys
cadence_known_keys() {
  echo "traceability_counter"
}
