#!/usr/bin/env bash
# check-common.sh — Shared utilities for check scripts
#
# Source this file in your check script:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/check-common.sh"
#
# Bash 3.2 compatible: no associative arrays (declare -A).
# All functions exit 0 on success, return 1 on failure.

# Prevent double-sourcing
if [ -n "${CHECK_COMMON_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
CHECK_COMMON_LOADED=1

# ── Paths ──────────────────────────────────────────────────────────
SCRIPTS_DIR="${SCRIPTS_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"}"
PRESET_DIR="$(cd "$SCRIPTS_DIR/../ddd-clean-arch" 2>/dev/null && pwd || echo "")"

# ── check_find_feature_dir ─────────────────────────────────────────
# Find feature directory via: $FEATURE_DIR env → find-first-feature.sh → $1 fallback
# Usage: FEATURE_DIR=$(check_find_feature_dir "/default/path")
check_find_feature_dir() {
  local fallback="${1:-}"

  # 1. $FEATURE_DIR env var
  if [ -n "${FEATURE_DIR:-}" ] && [ -d "$FEATURE_DIR" ]; then
    echo "$FEATURE_DIR"
    return 0
  fi

  # 2. find-first-feature.sh
  local found
  found=$(bash "$SCRIPTS_DIR/find-first-feature.sh" 2>/dev/null || echo "")
  if [ -n "$found" ] && [ -d "$found" ]; then
    echo "$found"
    return 0
  fi

  # 3. Fallback
  if [ -n "$fallback" ] && [ -d "$fallback" ]; then
    echo "$fallback"
    return 0
  fi

  return 1
}

# ── check_write_result ─────────────────────────────────────────────
# Write PASS/FAIL/SKIP to .artifacts/check-results/<check_id>.result
# Usage: check_write_result "$FEATURE_DIR" "drift" "PASS"
# Usage: check_write_result "$FEATURE_DIR" "drift" "FAIL" "detail line 1"
check_write_result() {
  local feature_dir="$1"
  local check_id="$2"
  local status="$3"
  shift 3
  local detail_lines="$@"

  local results_dir="$feature_dir/.artifacts/check-results"
  mkdir -p "$results_dir"

  local result_file="$results_dir/${check_id}.result"
  mkdir -p "$(dirname "$result_file")"
  local lock_file="$results_dir/.locks/$(echo "$check_id" | tr '/' '_').lock"
  mkdir -p "$results_dir/.locks"

  (
    flock -w 30 200 || { echo "FLOCK_TIMEOUT: $check_id" >&2; return 1; }
    echo "$status" > "$result_file"
    if [ -n "$detail_lines" ]; then
      echo "---" >> "$result_file"
      echo "$detail_lines" >> "$result_file"
    fi
  ) 200>"$lock_file"
}

# ── check_kv ───────────────────────────────────────────────────────
# Output KEY=VALUE consistently (for key=value stdout format)
# Usage: check_kv "DRIFT_DETECTED" "true"
check_kv() {
  echo "$1=$2"
}

# ── check_require_tool ─────────────────────────────────────────────
# Check if a command-line tool exists. Exit with SKIP if not found.
# Usage: check_require_tool "jq"
# Usage: check_require_tool "wrk" "performance benchmarking"
check_require_tool() {
  local tool="$1"
  local desc="${2:-$tool}"

  if command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi

  echo "SKIP: $desc not available (missing $tool)"
  return 1
}

# ── check_require_file ─────────────────────────────────────────────
# Check if a file exists. Exit with SKIP if not found.
# Usage: check_require_file "plan.md" "feature specification"
check_require_file() {
  local filepath="$1"
  local desc="${2:-$filepath}"

  if [ -f "$filepath" ]; then
    return 0
  fi

  echo "SKIP: $desc not available (missing $filepath)"
  return 1
}

# ── check_resolve_tier ─────────────────────────────────────────────
# Parse preset-routing.yml for routing_critical or routing_secondary.
# Usage: check_resolve_tier "backend-api"
# Output: critical or secondary
check_resolve_tier() {
  local task_type="${1:-}"
  local preset_file="$PRESET_DIR/preset-routing.yml"

  if [ ! -f "$preset_file" ]; then
    echo "critical"
    return 0
  fi

  # Check critical first
  if awk -v tt="$task_type" '
    $0 ~ ("^  " tt ":") { in_block=1 }
    in_block && /^  routing_critical:/ { print "critical"; exit }
    in_block && /^[^ ]/ { exit }
  ' "$preset_file" 2>/dev/null | grep -q .; then
    echo "critical"
    return 0
  fi

  echo "secondary"
}

# ── check_resolve_profile ──────────────────────────────────────────
# Parse preset-routing.yml for check profile (minimal/standard/full).
# Usage: check_resolve_profile
# Output: minimal, standard, or full
check_resolve_profile() {
  local preset_file="$PRESET_DIR/preset-routing.yml"

  if [ ! -f "$preset_file" ]; then
    echo "standard"
    return 0
  fi

  local profile
  profile=$(grep -oE 'profile[=:]"?[[:space:]]*(minimal|standard|full)' "$preset_file" 2>/dev/null | head -1 | grep -oE '(minimal|standard|full)' || echo "")

  if [ -n "$profile" ]; then
    echo "$profile"
  else
    echo "standard"
  fi
}

# ── check_help ─────────────────────────────────────────────────────
# Print usage/help and exit 0.
# Usage: check_help "check-name" "Description of what this check does."
#        check_help "check-name" "Usage: check-name.sh <feature_dir> [--json] [--help]"
check_help() {
  local name="$1"
  shift
  echo "Usage: $name $@"
  echo ""
  echo "Options:"
  echo "  --json    Output results in JSON format"
  echo "  --help    Show this help message"
  exit 0
}

# ── check_json_output ──────────────────────────────────────────────
# Build JSON output (bash 3.2 compatible — manual string building).
# Usage: check_json_output "check_id" "status" "key1" "val1" "key2" "val2"
check_json_output() {
  local check_id="$1"
  local status="$2"
  shift 2

  echo -n "{\"check\":\"$check_id\",\"status\":\"$status\""

  while [ $# -ge 2 ]; do
    local key="$1"
    local val="$2"
    shift 2
    # Escape quotes in values
    val=$(echo "$val" | sed 's/"/\\"/g')
    echo -n ",\"$key\":\"$val\""
  done

  echo "}"
}
