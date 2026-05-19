#!/usr/bin/env bash
# Deterministic test quality checker — scans test files for anti-patterns
# that are reliably detectable without semantic understanding.
#
# Replaces LLM self-audit (self-affirmation bias) with objective pattern detection.
#
# Usage: verify-test-quality.sh <test_file_or_dir>
#   If a directory is given, scans all test files within it.
#
# Output:
#   TEST_QUALITY: [N] errors, [M] warnings
#   For each issue: FILE:LINE SEVERITY: description
#
# Exit 1 if any ERROR found, 0 otherwise.

set -euo pipefail

TARGET="${1:?Usage: verify-test-quality.sh <test_file_or_dir> [--spec <spec_file>] [--help]}"
SPEC_FILE=""

# Parse optional flags
FILTERED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --spec) SPEC_FILE="${2:?Usage: verify-test-quality.sh <test_file_or_dir> --spec <spec_file>}"; shift 2 ;;
    --help) echo "Usage: verify-test-quality.sh <test_file_or_dir> [--spec <spec_file>] [--help]"; exit 0 ;;
    *) FILTERED_ARGS+=("$arg") ;;
  esac
done
set -- "${FILTERED_ARGS[@]}"
TARGET="${1:?Usage: verify-test-quality.sh <test_file_or_dir> [--spec <spec_file>]}"

ERRORS=0
WARNINGS=0
ISSUES=""

# ── Spec cross-reference: extract expected values from spec.md ────
SPEC_VALUES=""
if [ -n "$SPEC_FILE" ] && [ -f "$SPEC_FILE" ]; then
  # Extract numeric values from acceptance criteria (e.g., "returns 200", "within 500ms", "max 10 items")
  SPEC_VALUES=$(grep -oiE '(returns|status|code|expect|should be|must be|limit|max|min|threshold|within)[[:space:]]+[0-9]+' "$SPEC_FILE" 2>/dev/null | grep -oE '[0-9]+' | sort -u || true)
  # Also extract string values from acceptance criteria
  SPEC_STRINGS=$(grep -oiE '(returns|status|code|expect|should be|must be|named|title)[[:space:]]+"[^"]+"' "$SPEC_FILE" 2>/dev/null | sed 's/.*"//;s/"$//' || true)
fi

# ── Check if a number is a spec-backed value ──────────────────────
is_spec_backed() {
  local num="$1"
  if [ -n "$SPEC_VALUES" ]; then
    echo "$SPEC_VALUES" | grep -qx "$num" 2>/dev/null
    return $?
  fi
  return 1  # No spec file, can't verify
}

# Scan a single file for quality anti-patterns
scan_file() {
  local file="$1"
  [ -f "$file" ] || return 0

  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # ERROR: Trivial boolean assertions — expect(true), expect(false)
    if echo "$line" | grep -qiE 'expect[[:space:]]*\([[:space:]]*(true|false)[[:space:]]*\)[.]to[[:space:]]*(be|equal|eql|toEqual|eq)' 2>/dev/null; then
      ERRORS=$((ERRORS + 1))
      ISSUES="${ISSUES}${file}:${line_num} ERROR: Trivial boolean assertion (expect(true/false)). "
    fi

    # WARNING: Potential tautology — expect(x).toEqual(x) (same identifier in both)
    # NOTE: This is a warning only; the pass-through check below is an ERROR.
    if echo "$line" | grep -qiE 'expect[[:space:]]*\([a-zA-Z_]' 2>/dev/null; then
      local left right
      left=$(echo "$line" | sed -n 's/.*expect[[:space:]]*([[:space:]]*\([a-zA-Z_][a-zA-Z0-9_.]*\)[[:space:]]*).*/\1/p')
      right=$(echo "$line" | sed -n 's/.*[.]to[[:space:]]*\(equal\|eql\|toEqual\)[[:space:]]*([[:space:]]*\([a-zA-Z_][a-zA-Z0-9_.]*\)[[:space:]]*).*/\2/p')
      if [ -n "$left" ] && [ -n "$right" ] && [ "$left" = "$right" ]; then
        WARNINGS=$((WARNINGS + 1))
        ISSUES="${ISSUES}${file}:${line_num} WARNING: Potential tautology (expect($left).toEqual($left)). "
      fi
    fi

    # ERROR: Hardcoded status code checks without behavior verification — expect(200).toBe(200)
    if echo "$line" | grep -qiE 'expect[[:space:]]*\([[:space:]]*[0-9]{3}[[:space:]]*\)' 2>/dev/null; then
      local num
      num=$(echo "$line" | grep -oE '[0-9]{3}' | head -1)
      if [ -n "$num" ]; then
        local rest
        rest=$(echo "$line" | sed "s/.*expect([^)]*)//" || true)
        if echo "$rest" | grep -qiE "(to[[:space:]]*)?(be|equal|toEqual)[[:space:]]*\([[:space:]]*${num}[[:space:]]*\)" 2>/dev/null; then
          ERRORS=$((ERRORS + 1))
          ISSUES="${ISSUES}${file}:${line_num} ERROR: Hardcoded status code tautology (expect(${num}).toBe(${num})). "
        fi
      fi
    fi

    # ERROR: Pass-through assertion — expect(result).toEqual(input) where result is same as input param
    if echo "$line" | grep -qiE 'expect[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_.]*\)[[:space:]]*[.]to[[:space:]]*(equal|eql|toEqual)' 2>/dev/null; then
      # Heuristic: if the same identifier appears in both expect() and toEqual(), flag it
      local expect_arg actual_arg
      expect_arg=$(echo "$line" | sed -n 's/.*expect[[:space:]]*([[:space:]]*\([a-zA-Z_][a-zA-Z0-9_.]*\)[[:space:]]*).*/\1/p')
      actual_arg=$(echo "$line" | sed -n 's/.*[.]to[[:space:]]*\(equal\|eql\|toEqual\)[[:space:]]*([[:space:]]*\([a-zA-Z_][a-zA-Z0-9_.]*\)[[:space:]]*).*/\2/p')
      if [ -n "$expect_arg" ] && [ -n "$actual_arg" ] && [ "$(echo "$expect_arg" | tr '[:upper:]' '[:lower:]')" = "$(echo "$actual_arg" | tr '[:upper:]' '[:lower:]')" ]; then
        ERRORS=$((ERRORS + 1))
        ISSUES="${ISSUES}${file}:${line_num} ERROR: Pass-through assertion (expect($expect_arg).toEqual($expect_arg)). "
      fi
    fi

    # WARNING: Empty mock — jest.fn() / vi.fn() with no return value
    if echo "$line" | grep -qiE 'jest\.fn[[:space:]]*\(\s*\)|vi\.fn[[:space:]]*\(\s*\)' 2>/dev/null; then
      # Check next few lines for .mockReturnValue / .mockImplementation
      local next_lines
      next_lines=$(sed -n "$((line_num+1)),$((line_num+3))p" "$file" 2>/dev/null || true)
      if ! echo "$next_lines" | grep -qiE 'mockReturnValue|mockImplementation|mockResolvedValue|mockRejectedValue' 2>/dev/null; then
        WARNINGS=$((WARNINGS + 1))
        ISSUES="${ISSUES}${file}:${line_num} WARNING: Empty mock created (jest.fn()/vi.fn()) without return value setup. "
      fi
    fi

    # WARNING: done() callback with no assertions — callback smoke test only
    if echo "$line" | grep -qiE 'done[[:space:]]*\([[:space:]]*\)[[:space:]]*;' 2>/dev/null; then
      # Check if there are any expect() calls in the surrounding context
      local context_lines
      context_lines=$(sed -n "$((line_num-5)),$((line_num+2))p" "$file" 2>/dev/null || true)
      if ! echo "$context_lines" | grep -qiE 'expect\(' 2>/dev/null; then
        WARNINGS=$((WARNINGS + 1))
        ISSUES="${ISSUES}${file}:${line_num} WARNING: done() callback with no expect() in surrounding lines — callback smoke test only. "
      fi
    fi

    # === Python anti-patterns ===

    # ERROR: assert True / assert False (trivial boolean)
    if echo "$line" | grep -qiE '^\s*assert[[:space:]]+(True|False)[[:space:]]*[,)]' 2>/dev/null; then
      ERRORS=$((ERRORS + 1))
      ISSUES="${ISSUES}${file}:${line_num} ERROR: Python trivial boolean assertion (assert True/False). "
    fi

    # ERROR: assert 200 / assert 404 (hardcoded status code)
    if echo "$line" | grep -qiE '^\s*assert[[:space:]]+(200|301|404|500)[[:space:]]*[,)]' 2>/dev/null; then
      ERRORS=$((ERRORS + 1))
      ISSUES="${ISSUES}${file}:${line_num} ERROR: Python hardcoded status code assertion. "
    fi

    # WARNING: self.assertEqual(True/False) — should use assertTrue/assertFalse
    if echo "$line" | grep -qiE 'self\.assertEqual[[:space:]]*\([[:space:]]*(True|False)' 2>/dev/null; then
      WARNINGS=$((WARNINGS + 1))
      ISSUES="${ISSUES}${file}:${line_num} WARNING: Python self.assertEqual(True/False) — use assertTrue/assertFalse. "
    fi

    # === Go anti-patterns ===

    # WARNING: t.Log without t.Error/t.Fatal — logging, not asserting
    if echo "$line" | grep -qiE '\.Log\([[:space:]]*"[^"]*"[[:space:]]*\)' 2>/dev/null; then
      WARNINGS=$((WARNINGS + 1))
      ISSUES="${ISSUES}${file}:${line_num} WARNING: Go t.Log — logging, not asserting. "
    fi

    # ERROR: assert.Equal tautology (same value on both sides)
    if echo "$line" | grep -qiE 'assert\.Equal[[:space:]]*\([^,]+,[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*,[[:space:]]*\1' 2>/dev/null; then
      ERRORS=$((ERRORS + 1))
      ISSUES="${ISSUES}${file}:${line_num} ERROR: Go assert.Equal tautology (same value on both sides). "
    fi

    # === Java anti-patterns ===

    # ERROR: assertEquals(tautology) — same value on both sides
    if echo "$line" | grep -qiE 'assertEquals[[:space:]]*\([^,]+,[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*,[[:space:]]*\1' 2>/dev/null; then
      ERRORS=$((ERRORS + 1))
      ISSUES="${ISSUES}${file}:${line_num} ERROR: Java assertEquals tautology (same value on both sides). "
    fi

    # WARNING: assertTrue(true) / assertFalse(false) — trivial
    if echo "$line" | grep -qiE '(assertTrue|assertFalse)[[:space:]]*\(\s*(true|false)\s*\)' 2>/dev/null; then
      WARNINGS=$((WARNINGS + 1))
      ISSUES="${ISSUES}${file}:${line_num} WARNING: Java trivial assertTrue(true)/assertFalse(false). "
    fi

    # === Fix #19: Assertion meaningfulness checks ===

    # WARNING: Magic number in assertion without spec backing
    # Extract all numbers from assertion lines and flag those not found in spec
    local assert_line=""
    assert_line=$(echo "$line" | grep -oiE '(expect|assert|assertEquals|assertEqual|assertSame|should|must_be|verify)[[:space:]]*[^;]*' 2>/dev/null | head -1 || true)
    if [ -n "$assert_line" ]; then
      # Find all standalone numbers (3+ digits or specific patterns)
      local nums
      nums=$(echo "$assert_line" | grep -oE '[0-9]{1,}' || true)
      for num in $nums; do
        # Skip common benign numbers
        case "$num" in
          0|1|2|10|100) continue ;;  # Common benign counts
        esac
        # If spec file is provided, check if number is spec-backed
        if [ -n "$SPEC_FILE" ] && [ -n "$SPEC_VALUES" ]; then
          if ! is_spec_backed "$num"; then
            # Only flag if it's a "magic" number (not 0, 1, 2, 10, 100 which are common)
            if [ "${#num}" -ge 2 ] && [ "$num" -gt 100 ] 2>/dev/null; then
              WARNINGS=$((WARNINGS + 1))
              ISSUES="${ISSUES}${file}:${line_num} WARNING: Magic number $num in assertion — not found in spec acceptance criteria. "
            fi
          fi
        fi
      done
    fi

    # WARNING: Assertion uses a hardcoded string that may not match spec
    # Check for expect("some string") patterns with long hardcoded strings
    local hard_strings
    hard_strings=$(echo "$line" | grep -oE '"[^"]{10,}"' 2>/dev/null || true)
    if [ -n "$hard_strings" ] && [ -n "$SPEC_FILE" ]; then
      while IFS= read -r str; do
        str="${str//\"/}"  # Remove quotes
        if [ -n "$SPEC_STRINGS" ]; then
          if ! echo "$SPEC_STRINGS" | grep -qiF "$str" 2>/dev/null; then
            WARNINGS=$((WARNINGS + 1))
            ISSUES="${ISSUES}${file}:${line_num} WARNING: Hardcoded string \"$str\" in assertion — not found in spec. "
          fi
        fi
      done <<< "$hard_strings"
    fi

  done < "$file"
}

# Discover test files
if [ -f "$TARGET" ]; then
  scan_file "$TARGET"
elif [ -d "$TARGET" ]; then
  # Find test files by common naming conventions (bash 3.2 compatible)
  _tmpfile=$(mktemp)
  find "$TARGET" -type f \( \
    -name "*.test.ts" -o -name "*.test.js" -o -name "*.test.py" -o -name "*.test.go" \
    -o -name "*.spec.ts" -o -name "*.spec.js" -o -name "*.spec.py" \
    -o -name "*_test.go" -o -name "*_test.py" -o -name "test_*.py" \
    -o -name "test_*.ts" -o -name "test_*.js" \
    2>/dev/null > "$_tmpfile" || true
  while IFS= read -r test_file; do
    [ -n "$test_file" ] && scan_file "$test_file"
  done < "$_tmpfile"
  rm -f "$_tmpfile"
fi

echo "TEST_QUALITY: $ERRORS errors, $WARNINGS warnings"
if [ -n "$ISSUES" ]; then
  echo "$ISSUES"
fi

[ "$ERRORS" -eq 0 ]
exit_code=$?
exit $exit_code
