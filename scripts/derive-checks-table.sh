#!/usr/bin/env bash
# Usage: bash scripts/derive-checks-table.sh [preset.yml path]
# Auto-derives the README "21 quality checks" table from preset.yml.
# Reads short labels and descriptions from scripts/check-labels.yml.
#
# Output: complete markdown table (with header).
# Replace the table in README.md:
#   bash scripts/derive-checks-table.sh > /tmp/checks-table.md
#   # Then replace lines 137-159 in README.md with the output.
#
# Or just validate it matches:
#   diff <(sed -n '137,159p' README.md) <(bash scripts/derive-checks-table.sh)

set -euo pipefail

PRESET_FILE="${1:-ddd-clean-arch/preset.yml}"
bash scripts/require-file.sh "$PRESET_FILE" preset.yml

LABELS_FILE="scripts/check-labels.yml"
bash scripts/require-file.sh "$LABELS_FILE" check-labels.yml

# ── Parse check-labels.yml (nested YAML: ID > label/desc) ─────────────────────
declare -A LABELS DESCS
CURRENT_LABEL=""
while IFS= read -r line; do
  # Check for check ID line: "A:", "BC:", "Z:" (1-2 uppercase letters at start of line)
  if [[ "$line" =~ ^([A-Z][A-Z]?):$ ]]; then
    CURRENT_LABEL="${BASH_REMATCH[1]}"
    continue
  fi
  # Check for label/desc under current ID
  if [ -n "$CURRENT_LABEL" ]; then
    if [[ "$line" =~ label:[[:space:]]+\"(.*)\" ]]; then
      LABELS["$CURRENT_LABEL"]="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ desc:[[:space:]]+\"(.*)\" ]]; then
      DESCS["$CURRENT_LABEL"]="${BASH_REMATCH[1]}"
    fi
  fi
done < "$LABELS_FILE"

# ── Emit table header ────────────────────────────────────────────────────────
echo "| Check | What it does | Applies to |"
echo "|-------|-------------|-----------|"

# ── Parse preset.yml checks section ──────────────────────────────────────────
IN_CHECKS=false
CURRENT_ID=""

while IFS= read -r line; do
  # Detect start of checks section (must come BEFORE section boundary check)
  if [[ "$line" == "checks:" ]]; then
    IN_CHECKS=true
    continue
  fi

  # Detect section boundaries: blank line or comment (only after we've entered checks)
  if [ "$IN_CHECKS" = true ] && ([[ "$line" =~ ^$ ]] || [[ "$line" =~ ^# ]]); then
    # Emit pending check before leaving section
    if [ -n "$CURRENT_ID" ] && [ -n "${LABELS[$CURRENT_ID]:-}" ] && [ -n "${DESCS[$CURRENT_ID]:-}" ] && [ -n "$_prev_applies" ]; then
      label="${LABELS[$CURRENT_ID]}"
      desc="${DESCS[$CURRENT_ID]}"
      if [ "$_prev_applies" = "all" ]; then
        applies_col="All"
      else
        applies_col=$(echo "$_prev_applies" | sed 's/,/, /g')
      fi
      echo "| [$CURRENT_ID] $label | $desc | $applies_col |"
    fi
    IN_CHECKS=false
    CURRENT_ID=""
    _prev_applies=""
    continue
  fi

  # Skip if not in checks section
  if [ "$IN_CHECKS" = false ]; then
    continue
  fi

  # Detect check ID line: "  A:", "  BC:", "  Z:", etc. (1-2 uppercase letters, 2-space indent)
  if [[ "$line" =~ ^[[:space:]]{2}([A-Z][A-Z]?):[[:space:]]*$ ]]; then
    # Emit previous check if complete
    if [ -n "$CURRENT_ID" ] && [ -n "${LABELS[$CURRENT_ID]:-}" ] && [ -n "${DESCS[$CURRENT_ID]:-}" ] && [ -n "$_prev_applies" ]; then
      label="${LABELS[$CURRENT_ID]}"
      desc="${DESCS[$CURRENT_ID]}"
      if [ "$_prev_applies" = "all" ]; then
        applies_col="All"
      else
        applies_col=$(echo "$_prev_applies" | sed 's/,/, /g')
      fi
      echo "| [$CURRENT_ID] $label | $desc | $applies_col |"
    fi
    CURRENT_ID="${BASH_REMATCH[1]}"
    _prev_applies=""
    continue
  fi

  # Detect applies_to line (4-space indent)
  if [[ "$line" =~ applies_to:[[:space:]]+\[([^\]]*)\] ]]; then
    raw="${BASH_REMATCH[1]}"
    _prev_applies=$(echo "$raw" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//')
  elif [[ "$line" =~ applies_to:[[:space:]]+all ]]; then
    _prev_applies="all"
  fi
done < "$PRESET_FILE"

# Emit the last check (U)
if [ -n "$CURRENT_ID" ] && [ -n "${LABELS[$CURRENT_ID]:-}" ] && [ -n "${DESCS[$CURRENT_ID]:-}" ] && [ -n "$_prev_applies" ]; then
  label="${LABELS[$CURRENT_ID]}"
  desc="${DESCS[$CURRENT_ID]}"
  if [ "$_prev_applies" = "all" ]; then
    applies_col="All"
  else
    applies_col=$(echo "$_prev_applies" | sed 's/,/, /g')
  fi
  echo "| [$CURRENT_ID] $label | $desc | $applies_col |"
fi
