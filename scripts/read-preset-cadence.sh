#!/usr/bin/env bash
# Usage: source scripts/read-preset-cadence.sh
#        or: PRESET_SIMPLE=$(bash scripts/read-preset-cadence.sh simple)
#
# Reads cadence values from ddd-clean-arch/preset.yml.
# Usage: bash scripts/read-preset-cadence.sh <key> [preset_path]
# Keys: simple, medium, complex, first_retro_threshold

PRESET_FILE="${3:-ddd-clean-arch/preset.yml}"
KEY="${1:-medium}"

if [ ! -f "$PRESET_FILE" ]; then
  exit 1
fi

if [ "$KEY" = "first_retro_threshold" ]; then
  awk -v key="$KEY" '/^[[:space:]]*first_retro_threshold:/{print $2; exit}' "$PRESET_FILE"
else
  awk -v key="$KEY" '
    /^  retro_interval:/{found=1}
    found && $0 ~ key ":/{print $2; exit}
  ' "$PRESET_FILE"
fi
