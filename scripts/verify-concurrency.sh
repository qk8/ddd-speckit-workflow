#!/usr/bin/env bash
# verify-concurrency.sh — Deterministic concurrency & transaction safety check [W]
#
# Usage: bash scripts/verify-concurrency.sh <feature_dir> [source_dir]
#
# Scans source files against concurrency patterns defined in
# scripts/concurrency-patterns.conf. Checks for:
#   - Missing idempotency keys in handlers
#   - Missing version checks in aggregates
#   - Transaction boundary violations (I/O in domain layer)
#   - Missing domain event dispatch
#   - Race condition patterns
#   - Shared mutable state in handlers
#   - Resource leaks
#
# Output format:
#   VIOLATION: [file]:[line] [check_id] — [detail]
#   SUMMARY: [N] violations ([N] critical, [N] warnings)
# Exit code: 0 = no critical violations, 1 = violations found

set -euo pipefail

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_DIR" ]; then
  echo "CONCURRENCY CHECK: SKIP (no feature directory)"
  exit 0
fi

SOURCE_DIR="${2:-}"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_FILE="$ARTIFACTS_DIR/concurrency-results.txt"
PATTERNS_FILE="$(dirname "$0")/concurrency-patterns.conf"
mkdir -p "$ARTIFACTS_DIR"

CRITICAL_COUNT=0
WARNING_COUNT=0

if [ ! -f "$PATTERNS_FILE" ]; then
  echo "CONCURRENCY CHECK: SKIP (no patterns file: $PATTERNS_FILE)"
  exit 0
fi

# ── Get source directory ───────────────────────────────────────
get_source_dir() {
  if [ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ]; then
    echo "$SOURCE_DIR"
    return
  fi
  for d in "$FEATURE_DIR/src" "$FEATURE_DIR/lib" "$FEATURE_DIR/app" "$FEATURE_DIR/pkg"; do
    if [ -d "$d" ]; then
      if find "$d" -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rb" 2>/dev/null | head -1 | grep -q .; then
        echo "$d"
        return
      fi
    fi
  done
  local found
  found=$(find "$FEATURE_DIR" -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rb" 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    echo "$(dirname "$found")"
  else
    echo ""
  fi
}

# ── Parse a check section from patterns file ───────────────────
# Extracts fields from a [CHECK_ID.DESC] section
parse_section() {
  local section="$1"
  local field="$2"
  local patterns_content="$3"

  echo "$patterns_content" | awk -v section="[$section]" -v field="$field" '
    BEGIN { in_section = 0 }
    /^\[/ {
      if ($0 == section) in_section = 1
      else in_section = 0
      next
    }
    in_section && $0 ~ "^"field"=" {
      sub("^"field"=", "")
      print
      exit
    }
  '
}

# ── Get all section IDs ────────────────────────────────────────
get_sections() {
  grep '^\[' "$PATTERNS_FILE" | sed 's/^\[\(.*\)\].*/\1/'
}

# ── Record a violation ─────────────────────────────────────────
record_violation() {
  local file="$1"
  local line="$2"
  local check_id="$3"
  local severity="$4"
  local detail="$5"
  local msg="VIOLATION: $file:$line [$check_id] ($severity) — $detail"
  echo "$msg" >> "$RESULTS_FILE"
  if [ "$severity" = "critical" ]; then
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
  else
    WARNING_COUNT=$((WARNING_COUNT + 1))
  fi
}

# ── Evaluate a single check against a file ─────────────────────
evaluate_check() {
  local section="$1"
  local file="$2"
  local patterns_content="$3"

  local lang_filter
  lang_filter=$(parse_section "$section" "language" "$patterns_content")
  local must_contain
  must_contain=$(parse_section "$section" "must_contain" "$patterns_content")
  local must_not_contain
  must_not_contain=$(parse_section "$section" "must_not_contain" "$patterns_content")
  local severity
  severity=$(parse_section "$section" "severity" "$patterns_content")

  # Skip if severity not set (default to warning)
  [ -z "$severity" ] && severity="warning"

  # Check language filter
  if [ "$lang_filter" != "all" ]; then
    local ext="${file##*.}"
    local lang_match=false
    case "$ext" in
      ts|js)    lang_filter_check="ts,js" ;;
      py)       lang_filter_check="python" ;;
      go)       lang_filter_check="go" ;;
      java)     lang_filter_check="java" ;;
      rb)       lang_filter_check="ruby" ;;
      *)        lang_filter_check="$ext" ;;
    esac
    echo "$lang_filter" | grep -q "$lang_filter_check" || return 0
  fi

  # Check must_contain pattern
  if [ -n "$must_contain" ]; then
    if ! grep -qiE "$must_contain" "$file" 2>/dev/null; then
      record_violation "$file" 0 "$section" "$severity" "Missing required pattern: $must_contain"
      return 0
    fi
  fi

  # Check must_not_contain pattern
  if [ -n "$must_not_contain" ]; then
    grep -niE "$must_not_contain" "$file" 2>/dev/null | while IFS= read -r match; do
      local linenum
      linenum=$(echo "$match" | cut -d: -f1)
      local matched_line
      matched_line=$(echo "$match" | cut -d: -f2-)
      # Truncate detail
      local detail
      detail=$(echo "$matched_line" | sed 's/^[[:space:]]*//' | cut -c1-80)
      record_violation "$file" "$linenum" "$section" "$severity" "Found forbidden pattern: $detail"
    done || true
  fi
}

# ── Main ───────────────────────────────────────────────────────
> "$RESULTS_FILE"

if [ -z "$SOURCE_DIR" ]; then
  SOURCE_DIR=$(get_source_dir)
fi

if [ -z "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR" ]; then
  echo "CONCURRENCY CHECK: SKIP (no source directory found)"
  echo "SUMMARY: 0 violations (0 critical, 0 warnings)"
  exit 0
fi

echo "CONCURRENCY CHECK: Scanning $SOURCE_DIR"

# Read entire patterns file
PATTERNS_CONTENT=$(cat "$PATTERNS_FILE")

# Get all check sections
SECTIONS=$(get_sections)

# Find source files (exclude test directories)
SOURCE_FILES=$(find "$SOURCE_DIR" -type f \( \
  -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" \
  -o -name "*.java" -o -name "*.rb" \
\) -not -path "*/node_modules/*" -not -path "*/.artifacts/*" \
      -not -path "*/dist/*" -not -path "*/build/*" \
      -not -path "*/__tests__/*" -not -path "*/test/*" \
      -not -path "*/tests/*" -not -path "*/spec/*" 2>/dev/null)

FILE_COUNT=0
while IFS= read -r file; do
  [ -z "$file" ] && continue
  FILE_COUNT=$((FILE_COUNT + 1))

  for section in $SECTIONS; do
    evaluate_check "$section" "$file" "$PATTERNS_CONTENT"
  done
done <<< "$SOURCE_FILES"

TOTAL=$((CRITICAL_COUNT + WARNING_COUNT))
echo "SUMMARY: $TOTAL violations found ($CRITICAL_COUNT critical, $WARNING_COUNT warnings)"

# Save results
cp "$RESULTS_FILE" "$ARTIFACTS_DIR/check-results/W.result" 2>/dev/null || true

if [ "$TOTAL" -gt 0 ]; then
  exit 1
else
  exit 0
fi
