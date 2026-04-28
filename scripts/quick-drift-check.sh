#!/usr/bin/env bash
# Quick constraint drift check — runs at every task boundary
# Scans only the files modified in the current task for common violations.
# This is a lightweight pre-check; the full check Z runs at retro intervals.
set -euo pipefail

FEATURE_DIR=$(bash scripts/find-first-feature.sh)
PLAN_FILE="${FEATURE_DIR}/plan.md"
ARTIFACTS_DIR=".artifacts"
mkdir -p "$ARTIFACTS_DIR"

VIOLATIONS=0
SCANNED=0

# ── Check 1: Layer rule violations ──────────────────────────────
# Domain layer files should NOT import from delivery/infrastructure layers.
check_layer_violations() {
  local file="$1"
  local ext="${file##*.}"

  case "$ext" in
    java)
      if grep -qE 'import.*\.(delivery|infrastructure|web|controller)' "$file" 2>/dev/null; then
        echo "  LAYER VIOLATION: $(basename "$file") imports from non-domain layer"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      ;;
    ts|js)
      if grep -qE "from ['\"]\.\.?/.*(delivery|infrastructure|controller)" "$file" 2>/dev/null; then
        echo "  LAYER VIOLATION: $(basename "$file") imports from non-domain layer"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      ;;
    py)
      if grep -qE "from .+\.(delivery|infrastructure|views)" "$file" 2>/dev/null; then
        echo "  LAYER VIOLATION: $(basename "$file") imports from non-domain layer"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      ;;
  esac
}

# ── Check 2: Missing correlation ID in API responses ───────────
check_correlation_id() {
  local file="$1"
  local ext="${file##*.}"

  case "$ext" in
    ts|js)
      if grep -qE 'response|Response|result|Result' "$file" 2>/dev/null; then
        if ! grep -q 'correlation_id\|correlationId' "$file" 2>/dev/null; then
          if grep -qE 'status|statusCode|json\(|res\.' "$file" 2>/dev/null; then
            echo "  CORRELATION ID: $(basename "$file") may be missing correlation_id in response"
            VIOLATIONS=$((VIOLATIONS + 1))
          fi
        fi
      fi
      ;;
  esac
}

# ── Check 3: Test data isolation — hand-constructed domain objects ──
check_test_data_isolation() {
  local file="$1"
  local basename_file
  basename_file=$(basename "$file")

  # Only check test files
  if ! echo "$basename_file" | grep -qiE 'test|spec'; then
    return
  fi

  case "$basename_file" in
    *.test.*|*.spec.*|*Test.*|*Spec.*) ;;
    *) return ;;
  esac

  # Check for common patterns of hand-constructed domain objects
  if grep -qE 'new [A-Z][a-zA-Z]+\(' "$file" 2>/dev/null; then
    if ! grep -qE 'Factory|factory|Builder|builder' "$file" 2>/dev/null; then
      echo "  TEST DATA: $(basename "$file") may use hand-constructed domain objects"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi
}

# ── Scan modified files ────────────────────────────────────────
_COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [ "$_COMMIT_COUNT" -lt 1 ]; then
  echo "QUICK DRIFT CHECK: SKIPPED — no commits yet (first commit)."
  echo "Run this after the first commit."
  exit 0
fi
MODIFIED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || true)
if [ -z "$MODIFIED_FILES" ]; then
  MODIFIED_FILES=$(find "$FEATURE_DIR" -name '*.java' -o -name '*.ts' -o -name '*.js' -o -name '*.py' 2>/dev/null || true)
fi

if [ -z "$MODIFIED_FILES" ]; then
  echo "QUICK DRIFT CHECK: SKIPPED (no files to scan)"
  exit 0
fi

while IFS= read -r file; do
  [ -f "$file" ] || continue
  SCANNED=$((SCANNED + 1))
  check_layer_violations "$file"
  check_correlation_id "$file"
  check_test_data_isolation "$file"
done <<< "$MODIFIED_FILES"

echo "QUICK DRIFT CHECK: $SCANNED files scanned, $VIOLATIONS violations"
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "  WARNING: Review violations above. The full check Z will run at the next retro."
  exit 1
fi
echo "  All quick checks passed."
exit 0
