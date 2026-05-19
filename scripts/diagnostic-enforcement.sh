#!/usr/bin/env bash
# ── Diagnostic Enforcement ───────────────────────────────────────
# Reads diagnostic output and enforces REQUIRED_ACTION by verifying
# file modifications match the action. Provides --verify mode to
# check if the LLM modified files it shouldn't have.
#
# Usage:
#   diagnostic-enforcement.sh <feature_dir>              — write action file from diagnostic output
#   diagnostic-enforcement.sh --verify <feature_dir>     — verify no unauthorized changes
#
# Output (verify mode):
#   ENFORCEMENT=ENFORCED|VIOLATION_FOUND|PASSED
#   VIOLATION-1=...
#   VIOLATION-2=...
#   REVERTED=N (count of files reverted with --auto-revert)
# Exit codes: 0 = enforced/passed, 1 = violation found (or --auto-revert reverted files)

set -euo pipefail

FEATURE_DIR=""
VERIFY_MODE=false
AUTO_REVERT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --verify) VERIFY_MODE=true; shift ;;
    --auto-revert) AUTO_REVERT=true; shift ;;
    *) FEATURE_DIR="$1"; shift ;;
  esac
done

if [ -z "$FEATURE_DIR" ]; then
  echo "Usage: diagnostic-enforcement.sh [--verify] <feature_dir>"
  exit 0
fi

ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
DIAGNOSTIC_FILE="$ARTIFACTS_DIR/diagnostic-output.txt"
ACTION_FILE="$ARTIFACTS_DIR/diagnostic-enforcement.action"

# ── Mode 1: Write action file from diagnostic output ────────────
if [ "$VERIFY_MODE" = false ]; then
  if [ ! -f "$DIAGNOSTIC_FILE" ]; then
    echo "DIAGNOSTIC_NOT_FOUND"
    echo "ACTION=NONE"
    exit 0
  fi

  # Extract REQUIRED_ACTION from diagnostic output
  REQUIRED_ACTION=""
  if grep -q "REQUIRED_ACTION=" "$DIAGNOSTIC_FILE" 2>/dev/null; then
    REQUIRED_ACTION=$(grep "REQUIRED_ACTION=" "$DIAGNOSTIC_FILE" | tail -1 | cut -d'=' -f2 | tr -d '[:space:]')
  fi

  if [ -z "$REQUIRED_ACTION" ]; then
    echo "ACTION=NONE"
    echo "NO_REQUIRED_ACTION_FOUND"
    exit 0
  fi

  # Write action file
  cat > "$ACTION_FILE" << EOF
REQUIRED_ACTION=${REQUIRED_ACTION}
DIAGNOSTIC_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
EOF

  # Also write evidence summary
  local_evidence=""
  if grep -q "EVIDENCE=" "$DIAGNOSTIC_FILE" 2>/dev/null; then
    local_evidence=$(grep "EVIDENCE=" "$DIAGNOSTIC_FILE" | tail -1 | cut -d'=' -f2-)
  fi
  echo "EVIDENCE=${local_evidence}" >> "$ACTION_FILE"

  echo "ACTION=${REQUIRED_ACTION}"
  echo "ENFORCEMENT_FILE_WRITTEN=${ACTION_FILE}"
  exit 0
fi

# ── Mode 2: Verify no unauthorized file changes ─────────────────
if [ ! -f "$ACTION_FILE" ]; then
  echo "ENFORCEMENT=NOT_APPLICABLE"
  echo "NO_ACTION_FILE_FOUND"
  exit 0
fi

REQUIRED_ACTION=$(grep "REQUIRED_ACTION=" "$ACTION_FILE" | tail -1 | cut -d'=' -f2 | tr -d '[:space:]')

if [ -z "$REQUIRED_ACTION" ] || [ "$REQUIRED_ACTION" = "NONE" ]; then
  echo "ENFORCEMENT=PASSED"
  exit 0
fi

# Get list of modified files from git diff
MODIFIED_FILES=""
if [ -d "$FEATURE_DIR/.git" ]; then
  MODIFIED_FILES=$(cd "$FEATURE_DIR" && git diff --name-only HEAD 2>/dev/null || true)
  ADDED_FILES=$(cd "$FEATURE_DIR" && git diff --name-only --cached HEAD 2>/dev/null || true)
  MODIFIED_FILES="${MODIFIED_FILES}
${ADDED_FILES}"
  MODIFIED_FILES=$(echo "$MODIFIED_FILES" | sed '/^$/d' | sort -u || true)
fi

VIOLATION_COUNT=0
VIOLATIONS=""
VIOLATED_FILES=""

is_test_file() {
  echo "$1" | grep -qiE '(\.test\.|\.spec\.|_test\.|test_|tests/|__tests__/|/test/|\.test\.ts$|\.test\.js$|\.spec\.ts$|\.spec\.js$|test_.*\.py$|.*_test\.go$|Test\.|_spec\.rb$)'
}

is_impl_file() {
  echo "$1" | grep -qiE '(\.(js|ts|py|go|java|rs|rb|cs|kt)$|src/|lib/|app/|pkg/)'
}

case "$REQUIRED_ACTION" in
  FIX_TEST)
    # Must NOT modify implementation files. Only test files should change.
    while IFS= read fpath; do
      [ -z "$fpath" ] && continue
      if is_test_file "$fpath"; then
        continue
      fi
      VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
      VIOLATIONS="${VIOLATIONS}VIOLATION-${VIOLATION_COUNT}=FIX_TEST action but file modified: ${fpath} (not a test file); "
      VIOLATED_FILES="${VIOLATED_FILES}${fpath}
"
    done <<< "$MODIFIED_FILES"
    ;;
  FIX_IMPL)
    # Must NOT modify test files. Only implementation files should change.
    while IFS= read fpath; do
      [ -z "$fpath" ] && continue
      if is_test_file "$fpath"; then
        VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
        VIOLATIONS="${VIOLATIONS}VIOLATION-${VIOLATION_COUNT}=FIX_IMPL action but test file modified: ${fpath}; "
        VIOLATED_FILES="${VIOLATED_FILES}${fpath}
"
      fi
    done <<< "$MODIFIED_FILES"
    ;;
  FIX_ENV)
    # Must NOT modify test or implementation files. Only config/environment files.
    while IFS= read fpath; do
      [ -z "$fpath" ] && continue
      if is_test_file "$fpath"; then
        VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
        VIOLATIONS="${VIOLATIONS}VIOLATION-${VIOLATION_COUNT}=FIX_ENV action but test file modified: ${fpath}; "
        VIOLATED_FILES="${VIOLATED_FILES}${fpath}
"
      elif is_impl_file "$fpath"; then
        VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
        VIOLATIONS="${VIOLATIONS}VIOLATION-${VIOLATION_COUNT}=FIX_ENV action but implementation file modified: ${fpath}; "
        VIOLATED_FILES="${VIOLATED_FILES}${fpath}
"
      fi
    done <<< "$MODIFIED_FILES"
    ;;
  HUMAN)
    # Requires explicit override — no changes allowed without --override flag
    if [ "${DIAGNOSTIC_OVERRIDE:-false}" = "true" ]; then
      echo "ENFORCEMENT=OVERRIDDEN"
      echo "NOTE: HUMAN action overridden by operator"
      exit 0
    fi
    if [ -n "$MODIFIED_FILES" ]; then
      VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
      VIOLATIONS="${VIOLATIONS}VIOLATION-1=HUMAN action requires operator review — no changes allowed without --override flag; "
      VIOLATED_FILES="$MODIFIED_FILES"
    fi
    ;;
  RETRY)
    echo "ENFORCEMENT=PASSED"
    echo "NOTE: RETRY action allows flexible file modifications"
    exit 0
    ;;
  *)
    echo "ENFORCEMENT=PASSED"
    echo "NOTE: Unknown action '${REQUIRED_ACTION}' — no enforcement applied"
    exit 0
    ;;
esac

# ── Output results ──────────────────────────────────────────────
if [ "$VIOLATION_COUNT" -gt 0 ]; then
  echo "ENFORCEMENT=VIOLATION_FOUND"
  echo "$VIOLATIONS" | tr ';' '\n' | while IFS= read line; do
    [ -n "$line" ] && echo "$line"
  done

  # Auto-revert unauthorized changes
  REVERTED=0
  if [ "$AUTO_REVERT" = true ] && [ -n "$VIOLATED_FILES" ]; then
    while IFS= read vfile; do
      [ -z "$vfile" ] && continue
      if (cd "$FEATURE_DIR" && git checkout HEAD -- "$vfile" 2>/dev/null); then
        REVERTED=$((REVERTED + 1))
        echo "REVERTED: $vfile"
      else
        echo "REVERT_FAILED: $vfile (may not be tracked by git)"
      fi
    done <<< "$VIOLATED_FILES"
  fi
  echo "REVERTED=$REVERTED"
  exit 1
else
  echo "ENFORCEMENT=ENFORCED"
fi

exit 0
