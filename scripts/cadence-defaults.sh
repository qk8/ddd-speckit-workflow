#!/usr/bin/env bash
# Shared cadence defaults — mirror of preset.yml cadence section.
# Source this file: source scripts/cadence-defaults.sh
#
# These defaults are used when preset.yml is missing or unreadable.
# Keep in sync with ddd-clean-arch/preset.yml cadence section.

CADENCE_RETRO_INTERVAL_SIMPLE=15
CADENCE_RETRO_INTERVAL_MEDIUM=10
CADENCE_RETRO_INTERVAL_COMPLEX=5
CADENCE_FIRST_RETRO_THRESHOLD=5
CADENCE_TRACEABILITY_INTERVAL_SIMPLE=25
CADENCE_TRACEABILITY_INTERVAL_MEDIUM=20
CADENCE_TRACEABILITY_INTERVAL_COMPLEX=15

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
