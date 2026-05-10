#!/usr/bin/env bash
# code-quality-thresholds.sh — Default code quality thresholds
#
# Usage:
#   source scripts/code-quality-thresholds.sh        # Sets V_* variables
#   bash scripts/code-quality-thresholds.sh <lang>   # Prints thresholds for lang
#
# Defines default thresholds per language. Override by setting
# V_<metric>_THRESHOLD_<LANG> before sourcing.
#
# Metrics:
#   MAX_FUNC_LINES       — maximum function/method body length
#   MAX_FILE_LINES       — maximum file length
#   MAX_NESTING          — maximum nesting depth
#   MAX_PARAMS           — maximum function parameters
#   MAX_CLASS_METHODS    — maximum public methods per class
#   MAX_CYCLOMATIC       — maximum cyclomatic complexity

# ── Defaults (language-agnostic baseline) ───────────────────────
V_MAX_FUNC_LINES_DEFAULT=50
V_MAX_FILE_LINES_DEFAULT=300
V_MAX_NESTING_DEFAULT=4
V_MAX_PARAMS_DEFAULT=5
V_MAX_CLASS_METHODS_DEFAULT=10
V_MAX_CYCLOMATIC_DEFAULT=10

# ── Per-language overrides ──────────────────────────────────────
# Format: V_<METRIC>_THRESHOLD_<LANG>=<value>
# LANG: java, ts, js, python, go, ruby, c, cpp, rust, csharp, kotlin, scala, php, swift

# Java — stricter in domain layer
V_MAX_FUNC_LINES_THRESHOLD_java=50
V_MAX_FILE_LINES_THRESHOLD_java=350
V_MAX_NESTING_THRESHOLD_java=4
V_MAX_PARAMS_THRESHOLD_java=6
V_MAX_CLASS_METHODS_THRESHOLD_java=12
V_MAX_CYCLOMATIC_THRESHOLD_java=12

# TypeScript / JavaScript
V_MAX_FUNC_LINES_THRESHOLD_ts=50
V_MAX_FILE_LINES_THRESHOLD_ts=300
V_MAX_NESTING_THRESHOLD_ts=4
V_MAX_PARAMS_THRESHOLD_ts=5
V_MAX_CLASS_METHODS_THRESHOLD_ts=10
V_MAX_CYCLOMATIC_THRESHOLD_ts=10

# Python
V_MAX_FUNC_LINES_THRESHOLD_python=50
V_MAX_FILE_LINES_THRESHOLD_python=300
V_MAX_NESTING_THRESHOLD_python=4
V_MAX_PARAMS_THRESHOLD_python=5
V_MAX_CLASS_METHODS_THRESHOLD_python=10
V_MAX_CYCLOMATIC_THRESHOLD_python=10

# Go
V_MAX_FUNC_LINES_THRESHOLD_go=60
V_MAX_FILE_LINES_THRESHOLD_go=300
V_MAX_NESTING_THRESHOLD_go=4
V_MAX_PARAMS_THRESHOLD_go=6
V_MAX_CLASS_METHODS_THRESHOLD_go=8
V_MAX_CYCLOMATIC_THRESHOLD_go=12

# ── Resolve threshold for a metric + language ──────────────────
# Usage: resolve_threshold <metric> <lang>
# metric: FUNC_LINES, FILE_LINES, NESTING, PARAMS, CLASS_METHODS, CYCLOMATIC
# lang: java, ts, js, python, go, ruby, c, cpp, rust, csharp, kotlin, scala, php, swift, default
resolve_threshold() {
  local metric="$1"
  local lang="${2:-default}"
  local varname="V_MAX_${metric}_THRESHOLD_${lang}"
  local defaultvar="V_MAX_${metric}_DEFAULT"

  # shellcheck disable=SC2086
  local val="${!varname:-${!defaultvar}}"
  echo "$val"
}

# If run directly (not sourced), print thresholds for a language
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  LANG="${1:-default}"
  if [ -z "$LANG" ]; then
    echo "Usage: bash code-quality-thresholds.sh [language]"
    echo "Languages: java, ts, js, python, go, ruby, c, cpp, rust, csharp, kotlin, scala, php, swift, default"
    exit 1
  fi
  echo "# Thresholds for: $LANG"
  echo "MAX_FUNC_LINES=$(resolve_threshold FUNC_LINES "$LANG")"
  echo "MAX_FILE_LINES=$(resolve_threshold FILE_LINES "$LANG")"
  echo "MAX_NESTING=$(resolve_threshold NESTING "$LANG")"
  echo "MAX_PARAMS=$(resolve_threshold PARAMS "$LANG")"
  echo "MAX_CLASS_METHODS=$(resolve_threshold CLASS_METHODS "$LANG")"
  echo "MAX_CYCLOMATIC=$(resolve_threshold CYCLOMATIC "$LANG")"
fi
