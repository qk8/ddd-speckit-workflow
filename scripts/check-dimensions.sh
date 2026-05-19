#!/usr/bin/env bash
# check-dimensions.sh — Dimension-to-script lookup library
#
# Source this file to get dimension lookup functions.
# Reads ONLY preset-checks-dimensions.yml (the authoritative source).
#
# Usage: source scripts/check-dimensions.sh
#
# Functions exported:
#   expand_dimensions <task_type> <tier>     — space-separated "dim/sub" IDs
#   dimension_to_script <dim> <sub>          — script filename
#   expand_dimension <dim>                   — space-separated sub-check names
#
# Backward compat: If preset-checks-dimensions.yml is missing, returns empty
# strings (same as the previous fallback: SKIP behavior).

# Determine preset directory (supports override for testing)
_DIMENSIONS_FILE="${CHECK_DIMENSIONS_FILE:-$PRESET_DIR/preset-checks-dimensions.yml}"

# ── expand_dimensions: get all check IDs for a tier/task_type ─────
# Reads preset-routing.yml for dimensions, then expands each via preset-checks-dimensions.yml
expand_dimensions() {
  local tier="$1"
  local tt="$2"
  local preset_file="$PRESET_DIR/preset-routing.yml"

  if [ ! -f "$preset_file" ] || [ ! -f "$_DIMENSIONS_FILE" ]; then
    return
  fi

  # Get dimension list for this tier/task_type from routing table
  local dims
  dims=$(awk -v tier="$tier" -v tt="$tt" '
    $0 ~ ("^routing_" tier ":") { in_table=1; next }
    in_table && $0 ~ ("^  " tt ":") {
      s=$0
      gsub(/.*\[/, "", s)
      gsub(/\].*/, "", s)
      gsub(/ /, "", s)
      print s
      exit
    }
    in_table && /^[^ ]/ { exit }
  ' "$preset_file" 2>/dev/null)

  [ -z "$dims" ] && return

  for dim in $(echo "$dims" | tr ',' ' '); do
    local subs
    subs=$(expand_dimension "$dim")
    if [ -n "$subs" ]; then
      for sub in $subs; do
        echo "${dim}/${sub}"
      done
    else
      echo "$dim"
    fi
  done
}

# ── dimension_to_script: map dim+sub to script filename ───────────
# YAML layout: 2-space dim, 4-space sub_checks, 6-space sub-name, 8-space script
dimension_to_script() {
  local dim="$1"
  local subname="$2"

  if [ ! -f "$_DIMENSIONS_FILE" ]; then
    return
  fi

  awk -v dim="$dim" -v subname="$subname" '
    BEGIN { found=0; in_sub=0; in_sc=0 }
    $0 ~ ("^  " dim ":") { found=1; next }
    found && /sub_checks:/ { in_sub=1; next }
    in_sub && /^      [a-z]/ {
      candidate=$0
      sub(/:.*/, "", candidate)
      gsub(/[[:space:]]/, "", candidate)
      if (candidate == subname) in_sc=1
      next
    }
    in_sc && /script:/ { gsub(/.*script:[ ]*"?/, ""); gsub(/".*/, ""); print; exit }
    in_sc && /^    [^ ]/ { in_sc=0 }
    in_sub && /^  [a-z]/ { in_sub=0; found=0 }
    found && /^[^ ]/ { exit }
  ' "$_DIMENSIONS_FILE" 2>/dev/null
}

# ── expand_dimension: get sub-check names for a dimension ─────────
# YAML layout: 2-space dim, 4-space sub_checks, 6-space sub-check names
expand_dimension() {
  local dim="$1"

  if [ ! -f "$_DIMENSIONS_FILE" ]; then
    return
  fi

  awk -v dim="$dim" '
    BEGIN { found=0; in_sub=0 }
    $0 ~ ("^  " dim ":") { found=1; next }
    found && /sub_checks:/ { in_sub=1; next }
    in_sub && /^      [a-z]/ {
      name=$0
      sub(/:.*/, "", name)
      gsub(/[[:space:]]/, "", name)
      if (name != "") print name
      next
    }
    in_sub && /^  [a-z]/ { in_sub=0; found=0 }
    found && /^[^ ]/ { exit }
  ' "$_DIMENSIONS_FILE" 2>/dev/null
}

# ── check_script: resolve any check ID to its script ──────────────
# Handles both dimension/sub-check lookups AND standalone checks (E, G, AC).
# Usage: check_script <check_id> [dim_for_fallback]
check_script() {
  local check_id="$1"
  local fallback_dim="${2:-$check_id}"

  # Try dimension/sub-check lookup first (for "dim/sub" format)
  local dim sub
  case "$check_id" in
    */*)
      dim="${check_id%%/*}"
      sub="${check_id#*/}"
      local script
      script=$(dimension_to_script "$dim" "$sub")
      if [ -n "$script" ]; then
        echo "$script"
        return
      fi
      ;;
  esac

  # Standalone check fallback (E, G, AC)
  case "$check_id" in
    E) echo "check-drift.sh" ;;
    G) echo "check-drift.sh" ;;
    AC) echo "check-adversarial.sh" ;;
    *)
      # Last resort: try as dimension name
      dimension_to_script "$fallback_dim" "$fallback_dim"
      ;;
  esac
}
