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
TASKS_FILE="$FEATURE_DIR/tasks.md"

if [ ! -f "$TASKS_FILE" ]; then
  echo "SKIP: No tasks.md found at $TASKS_FILE"
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
        break
      fi
    done
  done

  # Decision logic:
  # - All keywords matched → PASS
  # - Some keywords matched → NEEDS_REVIEW
  # - No keywords matched → MISSING
  # - No keywords extracted → NEEDS_REVIEW (conservative)
  if [ "$total_keywords" -eq 0 ]; then
    echo "NEEDS_REVIEW"
  elif [ "$match_count" -eq "$total_keywords" ] && [ "$total_keywords" -ge 2 ]; then
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
