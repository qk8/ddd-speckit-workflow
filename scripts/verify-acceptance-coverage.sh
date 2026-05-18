#!/usr/bin/env bash
# verify-acceptance-coverage.sh — Deterministic test-acceptance coverage validation
#
# Usage: bash scripts/verify-acceptance-coverage.sh [feature_dir]
#
# Parses tasks.md for DONE tasks' acceptance criteria, searches test files
# for keyword/pattern matches, produces coverage report.
#
# Output format:
#   COVERAGE: TASK-[N] [PASS | NEEDS_REVIEW | MISSING] — [criterion summary]
#   SUMMARY: [N] total | [PASS] | [NEEDS_REVIEW] | [MISSING]
#
# Does NOT need to be perfect — uses keyword matching and regex patterns.
# Flags fewer cases but with higher confidence to avoid false negatives.

set -euo pipefail

FEATURE_DIR="${1:-$(bash scripts/find-first-feature.sh)}"
TASK_ID="${2:-}"
TASKS_FILE="$FEATURE_DIR/tasks.md"

# ── Task-specific TDD evidence mode ──────────────────────────────
# When TASK_ID is provided, check for TDD evidence (red/green phase)
# for that specific task. This is used by the acceptance gate to
# verify behavioral evidence before auto-approving.
if [ -n "$TASK_ID" ] && [ "$TASK_ID" != "unknown" ]; then
  ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
  TDD_EVIDENCE="false"

  # Check for batch_tasks.txt (proves write-test ran before implement)
  HAS_BATCH=false
  if [ -f "${ARTIFACTS_DIR}/batch_tasks.txt" ]; then
    if grep -q "$TASK_ID" "${ARTIFACTS_DIR}/batch_tasks.txt" 2>/dev/null; then
      HAS_BATCH=true
    fi
  fi

  # Check for test output artifacts (proves tests were run)
  HAS_TEST_OUTPUT=false
  if ls "${ARTIFACTS_DIR}/test-output-"* 2>/dev/null | grep -q "$TASK_ID" 2>/dev/null; then
    HAS_TEST_OUTPUT=true
  fi
  # Also check run-new-tests.sh output
  if [ -f "${ARTIFACTS_DIR}/run-new-tests-output.txt" ]; then
    if grep -q "$TASK_ID" "${ARTIFACTS_DIR}/run-new-tests-output.txt" 2>/dev/null; then
      HAS_TEST_OUTPUT=true
    fi
  fi

  # Check for check-results for this task's checks
  HAS_CHECK_RESULTS=false
  if [ -d "${ARTIFACTS_DIR}/check-results" ]; then
    local_result_files=$(ls "${ARTIFACTS_DIR}/check-results/"*.result 2>/dev/null | wc -l || echo 0)
    [ "$local_result_files" -gt 0 ] && HAS_CHECK_RESULTS=true
  fi

  # Check for error-memory entries (proves correction loop ran)
  HAS_ERROR_MEMORY=false
  if [ -f "${ARTIFACTS_DIR}/error-memory.json" ]; then
    if grep -q "$TASK_ID" "${ARTIFACTS_DIR}/error-memory.json" 2>/dev/null; then
      HAS_ERROR_MEMORY=true
    fi
  fi

  # Also check state.json for check_results on this task
  if [ -f "${FEATURE_DIR}/state.json" ]; then
    if jq -e ".tasks[\"$TASK_ID\"].check_results // empty" "${FEATURE_DIR}/state.json" >/dev/null 2>&1; then
      HAS_CHECK_RESULTS=true
    fi
  fi

  # TDD evidence requires: batch/tasks tracked + tests run + checks produced
  if [ "$HAS_BATCH" = true ] && [ "$HAS_TEST_OUTPUT" = true ] && [ "$HAS_CHECK_RESULTS" = true ]; then
    TDD_EVIDENCE="true"
  fi

  echo "TDD_EVIDENCE=$TDD_EVIDENCE"
  echo "  has_batch_tasks=$HAS_BATCH"
  echo "  has_test_output=$HAS_TEST_OUTPUT"
  echo "  has_check_results=$HAS_CHECK_RESULTS"
  echo "  has_error_memory=$HAS_ERROR_MEMORY"
  exit 0
fi

# ── Extract DONE tasks and their acceptance criteria ─────────────
# Uses awk to parse tasks.md in bash 3.2-compatible way.
# Acceptance criteria are lines starting with "  - [" between
# "Acceptance criteria:" header and the next header or task boundary.

extract_criteria() {
  awk '
    /^## TASK-/ {
      if (task_done && task_id != "") {
        # Print all collected criteria for the previous task
        for (i = 0; i < crit_count; i++) {
          print task_id "\t" criteria[i]
        }
      }
      task_id = $0
      sub(/^## /, "", task_id)
      task_done = 0
      crit_count = 0
      in_acceptance = 0
      next
    }
    /^Status: DONE/ { task_done = 1 }
    /^Acceptance criteria:/ { in_acceptance = 1; next }
    in_acceptance && /^  - \[/ {
      # Extract text between [ and ]
      line = $0
      sub(/^  - \[/, "", line)
      sub(/\]$/, "", line)
      # Collapse multi-line by taking first sentence
      sub(/\n.*$/, "", line)
      criteria[crit_count++] = line
    }
    in_acceptance && /^  - [^-]/ && !/^  - \[/ {
      # Continuation line (no bracket) — append to last criterion
      if (crit_count > 0) {
        line = $0
        sub(/^  - /, "", line)
        criteria[crit_count - 1] = criteria[crit_count - 1] " " line
      }
    }
    in_acceptance && /^Do NOT:/ { in_acceptance = 0 }
    in_acceptance && /^###/ { in_acceptance = 0 }
    in_acceptance && /^## TASK-/ { in_acceptance = 0 }
    END {
      # Print last task
      if (task_done && task_id != "") {
        for (i = 0; i < crit_count; i++) {
          print task_id "\t" criteria[i]
        }
      }
    }
  ' "$TASKS_FILE"
}

# ── Find test files in the feature directory ─────────────────────
find_test_files() {
  local feature_dir="$1"
  # Search common test directories; bash 3.2 compatible
  local test_files=""
  for pattern in \
    "$feature_dir"/tests/**/*Test.* \
    "$feature_dir"/tests/**/*test.* \
    "$feature_dir"/spec/**/*spec.* \
    "$feature_dir"/*/*Spec.* \
    "$feature_dir"/*/*spec.* \
    "$feature_dir"/*/*Tests.* \
    "$feature_dir"/*/*tests.* \
    "$feature_dir"/*/*.test.* \
    "$feature_dir"/*/*.spec.* \
    "$feature_dir"/*/*_test.* \
    "$feature_dir"/*/*_tests.*; do
    if [ -f "$pattern" ]; then
      test_files="$test_files $pattern"
    fi
  done
  echo "$test_files"
}

# ── Check if a criterion is covered by test files ────────────────
# Strategy: extract key identifiers from the criterion and search
# test files for matches.
#
# Acceptance criteria format:
#   "calling [ExactClass].[method]([input]) raises/returns [exact output]"
#   "the following test passes: [test description]"
#
# We extract: class names, method names, specific types/exceptions
check_coverage() {
  local task_id="$1"
  local criterion="$2"
  local test_files="$3"

  # Skip external system criteria (cannot check locally)
  if echo "$criterion" | grep -qiE "integrates with|connects to external|calls external|webhook|callback"; then
    echo "NEEDS_REVIEW"
    return
  fi

  # Extract key identifiers from the criterion:
  # 1. Class names (PascalCase words)
  # 2. Method names (camelCase or PascalCase after a dot)
  # 3. Exception/error type names
  local keywords=""

  # Extract class.method patterns: "UserRepository.save"
  local class_method
  class_method=$(echo "$criterion" | grep -oE '[A-Z][a-zA-Z]+\.[a-zA-Z]+' | head -5 || true)
  if [ -n "$class_method" ]; then
    keywords="$class_method"
  fi

  # Extract standalone class/type names (PascalCase)
  local types
  types=$(echo "$criterion" | grep -oE '[A-Z][a-zA-Z]+(Error|Exception|Result|Type|Event|DTO|Request|Response)' | head -5 || true)
  if [ -n "$types" ]; then
    keywords="$keywords $types"
  fi

  # Extract specific behavior keywords
  local behaviors
  behaviors=$(echo "$criterion" | grep -oiE 'raises|returns|throws|creates|deletes|updates|validates|rejects|saves|loads' | head -3 || true)
  if [ -n "$behaviors" ]; then
    keywords="$keywords $behaviors"
  fi

  # Assertion patterns to verify (multi-language)
  local assertion_patterns='expect\(|assert\(|assertEquals|assertTrue|assertEqual|toBe|toEqual|assertThat|Assertions\.|Assert\.|self\.assert|unittest\.assert|require\.|t\.Error|t\.Fatalf|t\.Fatal|check\.Equals|assert\.Equal'

  # Search test files for keyword matches
  local match_count=0
  local total_keywords=0

  for kw in $keywords; do
    [ -z "$kw" ] && continue
    total_keywords=$((total_keywords + 1))
    for tf in $test_files; do
      [ -z "$tf" ] && continue
      if grep -q "$kw" "$tf" 2>/dev/null; then
        match_count=$((match_count + 1))
        # Verify: check that an assertion pattern exists near the keyword
        local line_num
        line_num=$(grep -n "$kw" "$tf" 2>/dev/null | head -1 | cut -d: -f1 || true)
        if [ -n "$line_num" ]; then
          local start=$((line_num > 10 ? line_num - 10 : 1))
          local end=$((line_num + 10))
          local window
          window=$(sed -n "${start},${end}p" "$tf" 2>/dev/null || true)
          if echo "$window" | grep -qE "$assertion_patterns" 2>/dev/null; then
            : # Keyword + assertion found — this is a real test
          else
            : # Keyword found but no assertion nearby — weak coverage
            match_count=$((match_count - 1))
            break
          fi
        fi
        break
      fi
    done
  done

  # Decision logic:
  # - All keywords matched with assertions → PASS
  # - Some keywords matched → NEEDS_REVIEW
  # - No keywords matched → MISSING
  # - No keywords extracted → NEEDS_REVIEW (conservative)
  if [ "$total_keywords" -eq 0 ]; then
    echo "NEEDS_REVIEW"
  elif [ "$match_count" -eq "$total_keywords" ] && [ "$total_keywords" -ge 1 ]; then
    echo "PASS"
  elif [ "$match_count" -gt 0 ]; then
    echo "NEEDS_REVIEW"
  else
    echo "MISSING"
  fi
}

# ── Main ─────────────────────────────────────────────────────────

if [ ! -f "$TASKS_FILE" ]; then
  echo "SKIP: No tasks.md found at $TASKS_FILE"
  exit 0
fi

TEST_FILES=$(find_test_files "$FEATURE_DIR")

# Extract all criteria
CRITERIA=$(extract_criteria)

if [ -z "$CRITERIA" ]; then
  echo "SKIP: No DONE tasks with acceptance criteria found."
  exit 0
fi

TOTAL=0
PASS=0
NEEDS_REVIEW=0
MISSING=0

# Track per-task results for summary
declare -A TASK_RESULTS 2>/dev/null || true
TASK_RESULTS_FILE=$(mktemp)
trap 'rm -f "$TASK_RESULTS_FILE"' EXIT

while IFS=$'\t' read -r task_id criterion; do
  [ -z "$task_id" ] && continue
  [ -z "$criterion" ] && continue

  TOTAL=$((TOTAL + 1))

  # Truncate criterion for display (first 80 chars)
  display=$(echo "$criterion" | cut -c1-80)
  [ ${#criterion} -gt 80 ] && display="$display..."

  result=$(check_coverage "$task_id" "$criterion" "$TEST_FILES")

  case "$result" in
    PASS) PASS=$((PASS + 1)) ;;
    NEEDS_REVIEW) NEEDS_REVIEW=$((NEEDS_REVIEW + 1)) ;;
    MISSING) MISSING=$((MISSING + 1)) ;;
  esac

  echo "COVERAGE: $task_id $result — $display"
  echo "$task_id $result" >> "$TASK_RESULTS_FILE"
done <<< "$CRITERIA"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY: $TOTAL total | $PASS PASS | $NEEDS_REVIEW NEEDS_REVIEW | $MISSING MISSING"

if [ "$MISSING" -gt 0 ]; then
  echo ""
  echo "WARNING: $MISSING acceptance criterion(s) have no test coverage."
  echo "These criteria may not be tested. Review manually."
fi

# Exit 0 if no MISSING (NEEDS_REVIEW is advisory)
if [ "$MISSING" -gt 0 ]; then
  exit 1
fi
exit 0
