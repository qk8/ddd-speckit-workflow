#!/usr/bin/env bash
# Track spec revision attempts.
# Prevents infinite spec-revise loops during the implement loop.
#
# Usage:
#   check-spec-revisions.sh <feature_dir> [--dry-run] [--json] [--help]
#
# Outputs:
#   SPEC_REVISIONS=N
#   SPEC_REVISION_OK=true|false
#   SPEC_REVISION_EXHAUSTED=true|false
#
# Delegates to spec-revision-counter.sh for unified tracking via state.json.
#
# Default max revisions: sourced from revision-limits.sh (default: 3).
# Spec revisions are more disruptive than task revisions — they reset completed tasks.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

# ── Parse --json and --help flags ──────────────────────────────────
JSON_MODE=false
FILTERED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --json)      JSON_MODE=true ;;
    --help)      check_help "check-spec-revisions.sh" "<feature_dir> [--dry-run] [--json] [--help]" ;;
    *)           FILTERED_ARGS+=("$arg") ;;
  esac
done
set -- "${FILTERED_ARGS[@]}"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  shift
fi

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(check_find_feature_dir "" || true)
fi
FEATURE_DIR="${FEATURE_DIR:-}"

if [ -z "$FEATURE_DIR" ]; then
  echo "SPEC_REVISIONS=0"
  echo "SPEC_REVISION_OK=true"
  echo "SPEC_REVISION_EXHAUSTED=false"
  exit 0
fi

# Delegate to unified spec-revision-counter.sh
if [ "$DRY_RUN" = true ]; then
  # Read-only mode: just check current state
  OUTPUT=$(bash "$SCRIPTS_DIR/spec-revision-counter.sh" "$FEATURE_DIR" read 2>/dev/null || echo "SPEC_REVISIONS=0
OK=true
EXHAUSTED=false")
  SPEC_REV=$(echo "$OUTPUT" | grep '^REVISIONS=' | cut -d= -f2)
  OK=$(echo "$OUTPUT" | grep '^OK=' | cut -d= -f2)
  EXHAUSTED=$(echo "$OUTPUT" | grep '^EXHAUSTED=' | cut -d= -f2)
  CASCADE_EXHAUSTED=$(echo "$OUTPUT" | grep '^CASCADE_EXHAUSTED=' | cut -d= -f2 || echo "false")

  echo "SPEC_REVISIONS=${SPEC_REV}"
  if [ "$OK" = "true" ]; then
    echo "SPEC_REVISION_OK=true"
    echo "SPEC_REVISION_EXHAUSTED=false"
  else
    echo "SPEC_REVISION_OK=false"
    echo "SPEC_REVISION_EXHAUSTED=true"
  fi
  if [ "$CASCADE_EXHAUSTED" = "true" ]; then
    echo "CASCADE_EXHAUSTED=true"
    echo "Spec revision cascade limit reached. No further revisions." >&2
    check_write_result "$FEATURE_DIR" "spec_revisions" "FAIL" "Cascade limit reached"
    exit 1
  fi
  check_write_result "$FEATURE_DIR" "spec_revisions" "PASS"
  exit 0
fi

# Increment mode: delegate to spec-revision-counter.sh
OUTPUT=$(bash "$SCRIPTS_DIR/spec-revision-counter.sh" "$FEATURE_DIR" increment 2>/dev/null || true)
SPEC_REV=$(echo "$OUTPUT" | grep '^REVISIONS=' | cut -d= -f2)
OK=$(echo "$OUTPUT" | grep '^OK=' | cut -d= -f2)
EXHAUSTED=$(echo "$OUTPUT" | grep '^EXHAUSTED=' | cut -d= -f2)
CASCADE_EXHAUSTED=$(echo "$OUTPUT" | grep '^CASCADE_EXHAUSTED=' | cut -d= -f2 || echo "false")

echo "SPEC_REVISIONS=${SPEC_REV}"
if [ "$OK" = "true" ]; then
  echo "SPEC_REVISION_OK=true"
  echo "SPEC_REVISION_EXHAUSTED=false"
else
  echo "SPEC_REVISION_OK=false"
  echo "SPEC_REVISION_EXHAUSTED=true"
fi
if [ "${CASCADE_INCREMENT:-0}" = "1" ]; then
  CAS_OUT=$(bash "$SCRIPTS_DIR/spec-revision-counter.sh" "$FEATURE_DIR" increment --cascade 2>/dev/null || true)
  CAS_REV=$(echo "$CAS_OUT" | grep '^CASCADE=' | cut -d= -f2)
  echo "CASCADE_ROUND=${CAS_REV}"
fi
if [ "$CASCADE_EXHAUSTED" = "true" ]; then
  echo "CASCADE_EXHAUSTED=true"
  echo "Spec revision cascade limit reached. No further revisions." >&2
  check_write_result "$FEATURE_DIR" "spec_revisions" "FAIL" "Cascade limit reached"
  exit 1
fi

check_write_result "$FEATURE_DIR" "spec_revisions" "PASS"
exit 0
