#!/usr/bin/env bash
# ── Spec-to-Test Validation ──────────────────────────────────────
# Validates that test assertions match spec acceptance criteria.
# Complements verify-test-spec-alignment.sh (keyword overlap) with
# semantic validation of expected values and behavioral assertions.
#
# Usage: spec-to-test-validate.sh <feature_dir> [task_id]
#
# Output: VALIDATION=PASS|NEEDS_REVIEW
#         MISMATCH_COUNT=N
#         MISMATCH-1=...
#         MISMATCH-2=...
# Always exits 0 (advisory to orchestrator, enforced by command instruction).

set -euo pipefail

FEATURE_DIR="${1:?Usage: spec-to-test-validate.sh <feature_dir> [task_id]}"
TASK_ID="${2:-}"

if [ ! -f "$FEATURE_DIR/tasks.md" ]; then
  echo "VALIDATION=PASS"
  echo "MISMATCH_COUNT=0"
  exit 0
fi

# ── Extract acceptance criteria for a task ──────────────────────
extract_criteria() {
  local task_file="$1"
  local task_id="$2"

  awk -v tid="## $task_id" '
    $0 == tid { found=1; next }
    found && /^## / { exit }
    found && /^- / {
      # Remove leading "- " and trim
      sub(/^- /, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if (length($0) > 0) print
    }
  ' "$task_file" 2>/dev/null || true
}

# ── Extract test files for a task ───────────────────────────────
extract_test_files() {
  local task_file="$1"
  local task_id="$2"

  # Try to find test file from the task section (Test File: line)
  local test_line
  test_line=$(awk -v tid="## $task_id" '
    $0 == tid { found=1; next }
    found && /^## / { exit }
    found && /Test File:/ {
      sub(/.*Test File:[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print
      exit
    }
  ' "$task_file" 2>/dev/null || true)

  if [ -n "$test_line" ] && [ -f "$FEATURE_DIR/$test_line" ]; then
    echo "$FEATURE_DIR/$test_line"
    return
  fi

  # Fallback: search for test files near scope-modified files
  local impl_files
  impl_files=$(awk -v tid="## $task_id" '
    $0 == tid { found=1; next }
    found && /^## / { exit }
    found && /Scope.Modifies:/ { in_scope=1; next }
    in_scope && /^\s+- / {
      sub(/^[[:space:]]+- /, "")
      sub(/[[:space:]]*$/, "")
      print
    }
    in_scope && /^Scope:/ { exit }
  ' "$task_file" 2>/dev/null || true)

  for impl_file in $impl_files; do
    local base
    base=$(basename "$impl_file" | sed 's/\.[^.]*$//')
    local dir
    dir=$(dirname "$impl_file")
    for pattern in "${base}.test.*" "${base}.spec.*" "test_${base}.*"; do
      local found
      found=$(find "$FEATURE_DIR/$dir" -maxdepth 1 -name "$pattern" 2>/dev/null | head -1 || true)
      if [ -n "$found" ]; then
        echo "$found"
        return
      fi
    done
  done
}

# ── Detect expected values from acceptance criteria ─────────────
# Returns lines of "criteria_text|expected_value|value_type"
# value_type: status_code, count, string, boolean, exception, range
extract_expected_values() {
  local criteria_text="$1"

  while IFS= read -v criterion; do
    [ -z "$criterion" ] && continue

    # HTTP status codes: "returns 404", "status 200", "response 500"
    local status_code
    status_code=$(echo "$criterion" | grep -oiE '(returns|status|response|code).*[2345][0-9]{2}' | grep -oE '[2345][0-9]{2}' | head -1 || true)
    if [ -n "$status_code" ]; then
      echo "${criterion}|${status_code}|status_code"
      continue
    fi

    # Count/bound constraints: "max 10 items", "at least 5", "between 1 and 100"
    local max_bound
    max_bound=$(echo "$criterion" | grep -oiE 'max(imum)?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
    if [ -n "$max_bound" ]; then
      echo "${criterion}|${max_bound}|max_count"
      continue
    fi
    local min_bound
    min_bound=$(echo "$criterion" | grep -oiE 'min(imum)?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
    if [ -n "$min_bound" ]; then
      echo "${criterion}|${min_bound}|min_count"
      continue
    fi
    local range_vals
    range_vals=$(echo "$criterion" | grep -oiE 'between[[:space:]]+[0-9]+[[:space:]]+and[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tr '\n' '-' | sed 's/-$//' | head -1 || true)
    if [ -n "$range_vals" ]; then
      echo "${criterion}|${range_vals}|range"
      continue
    fi

    # Boolean expectations: "should be true", "must be false", "returns false"
    if echo "$criterion" | grep -qiE 'should be true|must be true|is true|returns true|is valid|is authorized|is enabled'; then
      echo "${criterion}|true|boolean"
      continue
    fi
    if echo "$criterion" | grep -qiE 'should be false|must be false|is false|returns false|is invalid|is unauthorized|is disabled'; then
      echo "${criterion}|false|boolean"
      continue
    fi

    # Exception/throw patterns: "throws ValidationError", "raises PermissionError"
    local exc
    exc=$(echo "$criterion" | grep -oiE '(throws|raises|exception|error).*[A-Z][a-zA-Z]+' | grep -oE '[A-Z][a-zA-Z]+' | head -1 || true)
    if [ -n "$exc" ]; then
      echo "${criterion}|${exc}|exception"
      continue
    fi

    # String literal expectations: "returns 'success'", 'message "error"'
    local str_val
    str_val=$(echo "$criterion" | grep -oE "(\"[^\"]+\"|'[^']+')|returns [a-zA-Z_][a-zA-Z0-9_]*" | head -1 || true)
    if [ -n "$str_val" ]; then
      local clean_val
      clean_val=$(echo "$str_val" | sed "s/['\"]//g;s/returns //")
      echo "${criterion}|${clean_val}|string"
      continue
    fi

    # Numeric assertions: "equals 42", "is 100", "should be 0"
    local num_val
    num_val=$(echo "$criterion" | grep -oiE '(equals|is|should be|must be|should equal)[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
    if [ -n "$num_val" ]; then
      echo "${criterion}|${num_val}|number"
      continue
    fi

  done <<< "$criteria_text"
}

# ── Validate test assertions against expected values ────────────
validate_assertion() {
  local test_file="$1"
  local expected_val="$2"
  local value_type="$3"
  local criterion="$4"

  case "$value_type" in
    status_code)
      # Check if test asserts the expected HTTP status code
      if grep -qE "(expect|assert|should).*${expected_val}" "$test_file" 2>/dev/null; then
        return 0
      fi
      if grep -qE "(toBe|toEqual|assertEquals|assertEqual|statusCode|status)[[:space:]]*(==|===|:)?[[:space:]]*${expected_val}" "$test_file" 2>/dev/null; then
        return 0
      fi
      return 1
      ;;
    boolean)
      # Check if test asserts true/false
      if grep -qiE "(expect|assert|should).*(true|false)" "$test_file" 2>/dev/null; then
        return 0
      fi
      if grep -qE "(toBe|toEqual|assertEquals|isTrue|isFalse|assertTrue|assertFalse)" "$test_file" 2>/dev/null; then
        return 0
      fi
      return 1
      ;;
    exception)
      # Check if test expects a specific exception
      if grep -qE "(toThrow|toThrowError|expectError|assertThrows|pytest.raises|assertRaises|catchError)" "$test_file" 2>/dev/null; then
        return 0
      fi
      if grep -qiE "${expected_val}" "$test_file" 2>/dev/null; then
        return 0
      fi
      return 1
      ;;
    string|number)
      # Check if test asserts the expected value
      if grep -qE "(expect|assert|should).*(\"${expected_val}\"|'${expected_val}'|${expected_val})" "$test_file" 2>/dev/null; then
        return 0
      fi
      if grep -qE "(toBe|toEqual|assertEquals|assertEqual|assertThat).*(\"${expected_val}\"|'${expected_val}'|${expected_val})" "$test_file" 2>/dev/null; then
        return 0
      fi
      return 1
      ;;
    max_count|min_count)
      # Check if test asserts a count bound
      if grep -qE "(expect|assert|should).*(length|size|count|length\(\)|\.length|\.count).*(>=|<=|>|<|=|==|toBe|toEqual|assertEquals)" "$test_file" 2>/dev/null; then
        return 0
      fi
      return 1
      ;;
    range)
      # Check if test asserts range boundaries
      local low high
      low=$(echo "$expected_val" | cut -d'-' -f1)
      high=$(echo "$expected_val" | cut -d'-' -f2)
      if grep -qE "(expect|assert|should).*(>=|<=|>=|<=).*(>=|<=)" "$test_file" 2>/dev/null; then
        return 0
      fi
      if grep -qE "(toBe|toEqual).*(>=|<=|>|<).*(>=|<=)" "$test_file" 2>/dev/null; then
        return 0
      fi
      return 1
      ;;
  esac
  return 1
}

# ── Main validation logic ───────────────────────────────────────
MISMATCH_COUNT=0
MISMATCHES=""

# Determine which task to validate
if [ -n "$TASK_ID" ]; then
  REVIEW_TASKS="$TASK_ID"
else
  # Find first TODO or IN_PROGRESS task
  REVIEW_TASKS=$(awk '
    /^## TASK-/ {
      tid = $0
      sub(/^## /, "", tid)
    }
    /^Status:/ {
      status = $0
      sub(/^[[:space:]]*Status:[[:space:]]*/, "", status)
      if (status ~ /TODO|IN_PROGRESS/) print tid
    }
  ' "$FEATURE_DIR/tasks.md" 2>/dev/null | head -1 || true)
  if [ -z "$REVIEW_TASKS" ]; then
    echo "VALIDATION=PASS"
    echo "MISMATCH_COUNT=0"
    exit 0
  fi
fi

# Process each task
while IFS= read -v tid; do
  tid=$(echo "$tid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$tid" ] && continue

  # Extract criteria
  criteria=$(extract_criteria "$FEATURE_DIR/tasks.md" "$tid")
  [ -z "$criteria" ] && continue

  # Extract test files
  test_files=$(extract_test_files "$FEATURE_DIR/tasks.md" "$tid")
  [ -z "$test_files" ] && continue

  # Extract expected values from criteria
  expected_values=$(extract_expected_values "$criteria")
  [ -z "$expected_values" ] && continue

  # Validate each expected value against test files
  while IFS= read -v ev_line; do
    [ -z "$ev_line" ] && continue

    local_criteria=$(echo "$ev_line" | sed 's/|[^|]*$//')
    expected_val=$(echo "$ev_line" | awk -F'|' '{print $2}')
    value_type=$(echo "$ev_line" | awk -F'|' '{print $3}')

    validated=false
    while IFS= read -v tf; do
      [ -z "$tf" ] && continue
      if validate_assertion "$tf" "$expected_val" "$value_type" "$local_criteria"; then
        validated=true
        break
      fi
    done <<< "$test_files"

    if [ "$validated" = false ]; then
      MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
      MISMATCHES="${MISMATCHES}MISMATCH-${MISMATCH_COUNT}=${local_criteria} [expected ${value_type}=${expected_val} not found in test assertions]; "
    fi
  done <<< "$expected_values"

  # Check for behavioral criteria without explicit values
  while IFS= read -v criterion; do
    [ -z "$criterion" ] && continue

    # Skip criteria that have explicit expected values (already checked above)
    if echo "$criterion" | grep -qiE '(returns|status|equals|is|throws|max|min|between|true|false|"[^"]+")'; then
      continue
    fi

    # Behavioral criteria: check if test file has a describe/it block covering this behavior
    if [ -n "$test_files" ]; then
      covered=false
      while IFS= read -v tf; do
        [ -z "$tf" ] && continue
        # Extract significant words from criterion
        words=$(echo "$criterion" | grep -oE '\b[a-zA-Z]{4,}\b' | head -5 | tr '\n' '|' | sed 's/|$//' || true)
        if [ -n "$words" ] && grep -qiE "$words" "$tf" 2>/dev/null; then
          covered=true
          break
        fi
      done <<< "$test_files"

      if [ "$covered" = false ]; then
        MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
        MISMATCHES="${MISMATCHES}MISMATCH-${MISMATCH_COUNT}=Behavioral criterion '${criterion}' not covered by test describe/it blocks]; "
      fi
    fi
  done <<< "$criteria"

done <<< "$REVIEW_TASKS"

# ── Output results ──────────────────────────────────────────────
if [ "$MISMATCH_COUNT" -eq 0 ]; then
  echo "VALIDATION=PASS"
else
  echo "VALIDATION=NEEDS_REVIEW"
  echo "$MISMATCHES" | tr ';' '\n' | while IFS= read -v line; do
    [ -n "$line" ] && echo "$line"
  done
fi
echo "MISMATCH_COUNT=${MISMATCH_COUNT}"

exit 0
