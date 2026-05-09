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
# Uses precise package/import patterns to reduce false positives.
check_layer_violations() {
  local file="$1"
  local ext="${file##*.}"

  case "$ext" in
    java)
      # Match infrastructure package patterns, not bare words in class names
      if grep -qE 'import.*\.(infrastructure|delivery\.service|delivery\.port|web\.controller|controller\.)' "$file" 2>/dev/null; then
        # Exclude known domain classes that use infrastructure-like names
        local basename_file
        basename_file=$(basename "$file")
        if ! echo "$basename_file" | grep -qiE 'DeliveryStatus|WebhookHandler|PaymentGateway|NotificationService'; then
          echo "  LAYER VIOLATION: $(basename "$file") imports from non-domain layer"
          VIOLATIONS=$((VIOLATIONS + 1))
        fi
      fi
      ;;
    ts|js)
      if grep -qE "from ['\"]\.\.?/.*(infrastructure|delivery/service|web/controller)" "$file" 2>/dev/null; then
        echo "  LAYER VIOLATION: $(basename "$file") imports from non-domain layer"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      ;;
    py)
      if grep -qE "from .+\.(infrastructure|delivery\.service|views)" "$file" 2>/dev/null; then
        echo "  LAYER VIOLATION: $(basename "$file") imports from non-domain layer"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      ;;
  esac
}

# ── Check 2: Missing correlation ID in API responses ───────────
# Only flag files that clearly produce HTTP responses (res.json, res.send,
# return Response, return HttpResponse) without correlation_id.
# This avoids false positives from variables named "result" or "response".
check_correlation_id() {
  local file="$1"
  local ext="${file##*.}"

  case "$ext" in
    ts|js)
      # Must have actual HTTP response patterns, not just variable names
      if grep -qE 'res\.(json|send|status|end|write)|return\s+(Response|HttpResponse)' "$file" 2>/dev/null; then
        if ! grep -q 'correlation_id\|correlationId' "$file" 2>/dev/null; then
          echo "  CORRELATION ID: $(basename "$file") may be missing correlation_id in response"
          VIOLATIONS=$((VIOLATIONS + 1))
        fi
      fi
      ;;
  esac
}

# ── Check 3: Test data isolation — hand-constructed domain objects ──
# Only flag direct domain aggregate construction in test files.
# Exclude test framework setup (Mockito, beforeEach, setUp, fixture helpers).
# Uses a broader set of aggregate names to reduce false negatives.
# Also excludes files with test helper patterns (Mock, Fake, Stub, TestDouble).
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

  # Exclude test doubles and helpers — they legitimately construct domain objects
  if echo "$basename_file" | grep -qiE 'Mock|Fake|Stub|TestDouble|TestHelper'; then
    return
  fi

  # Flag direct new AggregateName( patterns where AggregateName starts with
  # a capital letter and is not a known test utility class.
  # Exclude files that use Factory/Builder/Mockito/beforeEach (proper patterns).
  if grep -qE 'new [A-Z][a-zA-Z]+\(.*\)' "$file" 2>/dev/null; then
    if ! grep -qE 'Factory|factory|Builder|builder|Mockito|@Mock|@InjectMocks|beforeEach|setUp|fixture|create[A-Z]|make[A-Z]' "$file" 2>/dev/null; then
      echo "  TEST DATA: $(basename "$file") may use hand-constructed domain objects"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi
}

# ── Scan modified files ────────────────────────────────────────
_COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [ "$_COMMIT_COUNT" -lt 1 ]; then
  # First commit: scan uncommitted changes instead of skipping
  MODIFIED_FILES=$(git diff --name-only --cached 2>/dev/null || true)
  if [ -z "$MODIFIED_FILES" ]; then
    # No staged changes — scan all tracked source files
    MODIFIED_FILES=$(find . -name '*.java' -o -name '*.ts' -o -name '*.js' -o -name '*.py' 2>/dev/null | head -100 || true)
  fi
else
  MODIFIED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || true)
  if [ -z "$MODIFIED_FILES" ]; then
    MODIFIED_FILES=$(find "$FEATURE_DIR" -name '*.java' -o -name '*.ts' -o -name '*.js' -o -name '*.py' 2>/dev/null || true)
  fi
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
  echo "DRIFT_DETECTED=true"
  echo "DRIFT_FAIL_COUNT=$VIOLATIONS"
  echo "QUICK_DRIFT_DETECTED=true"
  echo "QUICK_DRIFT=true"
  echo "  WARNING: Review violations above. The full check Z will run at the next retro."
else
  echo "DRIFT_DETECTED=false"
  echo "QUICK_DRIFT_DETECTED=false"
  echo "DRIFT_CLEAN=true"
  echo "QUICK_DRIFT=true"
  echo "  All quick checks passed."
fi
# Always exit 0 — the workflow reads DRIFT_DETECTED to decide next steps.
# This prevents set -e from aborting the iteration on drift violations.
exit 0
