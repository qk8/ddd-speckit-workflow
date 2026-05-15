#!/usr/bin/env bash
set -euo pipefail
# Usage: source scripts/print-result.sh
#        or: bash scripts/print-result.sh <errors> <warnings> <error_msg> <fix_msg> <warn_msg> <pass_msg>
#
# Prints a validation result summary and exits.
# If sourced, uses ERRORS/WARNINGS variables if not passed as args.
#
# Args (positional, all required if not sourced):
#   1: error count
#   2: warning count
#   3: error detail message
#   4: fix instruction message
#   5: warning message (use "none" to skip warning branch)
#   6: success message

if [ $# -ge 6 ]; then
  _e="$1"; _w="$2"; _err_msg="$3"; _fix_msg="$4"; _warn_msg="$5"; _pass_msg="$6"
elif [ -n "${ERRORS:-}" ]; then
  _e="$ERRORS"; _w="${WARNINGS:-0}"
  _err_msg="${1:-Issues found: $ERRORS error(s), $WARNINGS warning(s).}"
  _fix_msg="${2:-FIX the errors before proceeding.}"
  _warn_msg="${3:-$WARNINGS warning(s). Consider reviewing.}"
  _pass_msg="${4:-All checks passed. $ERRORS errors, $WARNINGS warnings.}"
else
  echo "ERROR: print-result.sh requires ERRORS/WARNINGS variables or 6 args" >&2
  exit 2
fi

# Helper: return when sourced, exit when run directly
_pr_exit() {
  if [ "${#BASH_SOURCE[@]}" -gt 1 ]; then
    return "$1"
  fi
  exit "$1"
}

echo ""
echo "━━━ Validation Result ━━━"
if [ "$_e" -gt 0 ]; then
  echo "  $_err_msg"
  echo "  $_fix_msg"
  _pr_exit 1
elif [ "$_w" -gt 0 ] && [ "$_warn_msg" != "none" ]; then
  echo "  $_warn_msg"
  _pr_exit 0
else
  echo "  $_pass_msg"
  _pr_exit 0
fi
