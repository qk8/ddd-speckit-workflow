#!/usr/bin/env bash
# Test-Spec Alignment Review — runs between write-test and implement.
# Validates that newly created test files cover acceptance criteria
# and that assertions in test files are backed by criteria.
#
# Usage: verify-test-spec-alignment.sh <feature_dir> [task_id]
#
# Outputs:
#   ALIGNMENT=PASS|NEEDS_REVIEW|FAIL
#   CRITERION-[N]=COVERED|UNCOVERED
#   ASSERTION-[N]=VALID|UNBACKED
#   WARNINGS=... (semicolon-separated)

set -euo pipefail

FEATURE_DIR="${1:?Usage: verify-test-spec-alignment.sh <feature_dir> [task_id]}"
TASK_ID="${2:-}"

TASKS_FILE="${FEATURE_DIR}/tasks.md"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
BATCH_FILE="${ARTIFACTS_DIR}/batch_tasks.txt"

if [ ! -f "$TASKS_FILE" ]; then
  echo "ALIGNMENT=FAIL"
  echo "WARNINGS=No tasks.md found"
  exit 0
fi

# ── Determine which task(s) to review ───────────────────────────
if [ -n "$TASK_ID" ] && [ -f "$TASKS_FILE" ]; then
  # Single task mode
  REVIEW_TASKS="$TASK_ID"
elif [ -f "$BATCH_FILE" ]; then
  # Batch mode — review all tasks in the batch
  REVIEW_TASKS=$(cat "$BATCH_FILE" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '\n' ' ')
else
  # No context — skip silently
  echo "ALIGNMENT=PASS"
  echo "WARNINGS=No task context (single task_id or batch_tasks.txt) available"
  exit 0
fi

ALIGNMENT="PASS"
CRITERION_MAP=""
ASSERTION_MAP=""
CRITERION_N=0
ASSERTION_N=0
WARNINGS=""

# ── Extract acceptance criteria for a task ──────────────────────
extract_criteria() {
  local task_id="$1"
  # Extract the task block, then find Acceptance: section
  awk -v tid="## $task_id" '
    $0 == tid { found=1; next }
    found && /^## TASK-/ { exit }
    found && /^Acceptance:/ { in_acc=1; next }
    in_acc && /^[[:space:]]*[-*]/ {
      gsub(/^[[:space:]]*[-*][[:space:]]+/, "")
      print
    }
    in_acc && /^[[:space:]]*$/ && !/^[-*]/ { exit }
  ' "$TASKS_FILE" 2>/dev/null || true
}

# ── Extract test file path for a task ───────────────────────────
extract_test_file() {
  local task_id="$1"
  awk -v tid="## $task_id" '
    $0 == tid { found=1; next }
    found && /^## TASK-/ { exit }
    found && /^Test file:/ {
      sub(/^Test file:[[:space:]]*/, "")
      print
      exit
    }
  ' "$TASKS_FILE" 2>/dev/null || true
}

# ── Extract all test files touched by git diff ──────────────────
get_new_test_files() {
  cd "$FEATURE_DIR"
  git diff --name-only HEAD 2>/dev/null | grep -iE '\.(test|spec)\.(ts|js|java|py|go|rs)$' || true
  cd - > /dev/null
}

# ── Check if an assertion pattern exists in test files ──────────
has_assertion_near_keyword() {
  local test_files="$1"
  local keyword="$2"

  for tf in $test_files; do
    if [ ! -f "$tf" ]; then
      continue
    fi

    # Find the line with the keyword, then check nearby lines for assertion patterns
    local line_num
    line_num=$(grep -n -i "$keyword" "$tf" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [ -z "$line_num" ]; then
      continue
    fi

    # Check a window of ±10 lines around the keyword for assertion patterns
    local start=$((line_num > 10 ? line_num - 10 : 1))
    local end=$((line_num + 10))
    local window
    window=$(sed -n "${start},${end}p" "$tf" 2>/dev/null || true)

    if echo "$window" | grep -qE 'expect\(|assert\(|assertEquals|assertTrue|assertEqual|toBe|toEqual|assertThat|Assertions\.|Assert\.|self\.assert|unittest\.assert|require\.|t\.Error|t\.Fatalf|t\.Fatal|check\.Equals|assert\.Equal' 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ── Check if an assertion is backed by a criterion ──────────────
is_assertion_backed() {
  local test_file="$1"
  local assertion_keyword="$2"
  local criteria="$3"

  if [ ! -f "$test_file" ]; then
    return 1
  fi

  # Extract assertion descriptions from test file (describe/it/test blocks)
  local test_descriptions
  test_descriptions=$(grep -oE '(describe|it|test|@Test|@DisplayName)\s*\(["'"'"'][^"'"'"']+["'"'"']' "$test_file" 2>/dev/null | sed "s/.*(['\"']//;s/['\"'].*//" || true)

  if [ -z "$test_descriptions" ]; then
    return 1
  fi

  # Check if any test description maps to a criterion
  while IFS= read -v desc; do
    # Check if criterion contains keywords from the test description
    while IFS= read -v criterion; do
      local desc_words
      desc_words=$(echo "$desc" | tr ' -_' '   ' | tr '[:upper:]' '[:lower:]')
      local crit_words
      crit_words=$(echo "$criterion" | tr ' -_' '   ' | tr '[:upper:]' '[:lower:]')

      # Check for shared significant words (3+ chars)
      local shared=0
      for word in $desc_words; do
        if [ ${#word} -ge 3 ] && echo "$crit_words" | grep -qi "$word"; then
          shared=1
          break
        fi
      done
      if [ "$shared" -eq 1 ]; then
        return 0
      fi
    done <<< "$criteria"
  done <<< "$test_descriptions"

  return 1
}

# ── Process each task ──────────────────────────────────────────
for tid in $REVIEW_TASKS; do
  tid=$(echo "$tid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$tid" ] && continue

  # Check if task exists and is in the right state
  if ! grep -q "^## $tid" "$TASKS_FILE" 2>/dev/null; then
    WARNINGS="${WARNINGS}Task $tid not found in tasks.md; "
    continue
  fi

  local_status=$(awk -v tid="## $tid" '
    $0 == tid { found=1; next }
    found && /^Status:/ { print; exit }
  ' "$TASKS_FILE" 2>/dev/null || echo "")

  if echo "$local_status" | grep -qiE "DONE|ABANDONED"; then
    continue  # Only review TODO/IN_PROGRESS tasks
  fi

  test_file=$(extract_test_file "$tid")
  criteria=$(extract_criteria "$tid")

  if [ -z "$criteria" ]; then
    WARNINGS="${WARNINGS}No acceptance criteria for $tid; "
    continue
  fi

  # ── Check criterion coverage ──────────────────────────────
  criterion_idx=0
  while IFS= read -v criterion; do
    [ -z "$criterion" ] && continue
    criterion_idx=$((criterion_idx + 1))

    if [ -n "$test_file" ] && [ -f "$test_file" ]; then
      # Extract keywords from criterion (significant words 4+ chars)
      keywords=$(echo "$criterion" | grep -oE '\b[a-zA-Z]{4,}\b' | tr '\n' '|' | sed 's/|$//' || true)
      if [ -n "$keywords" ]; then
        if grep -qiE "$keywords" "$test_file" 2>/dev/null; then
          # Check for assertion near keyword
          if has_assertion_near_keyword "$test_file" "$(echo "$keywords" | cut -d'|' -f1)"; then
            CRITERION_N=$((CRITERION_N + 1))
            echo "CRITERION-${CRITERION_N}=COVERED"
          else
            CRITERION_N=$((CRITERION_N + 1))
            echo "CRITERION-${CRITERION_N}=UNCOVERED"
            if [ "$ALIGNMENT" = "PASS" ]; then
              ALIGNMENT="NEEDS_REVIEW"
            fi
          fi
        else
          CRITERION_N=$((CRITERION_N + 1))
          echo "CRITERION-${CRITERION_N}=UNCOVERED"
          ALIGNMENT="NEEDS_REVIEW"
        fi
      fi
    else
      # No test file yet — this is expected during write-test phase
      CRITERION_N=$((CRITERION_N + 1))
      echo "CRITERION-${CRITERION_N}=COVERED"
    fi
  done <<< "$criteria"

  # ── Check assertion validation (unbacked assertions) ──────
  if [ -n "$test_file" ] && [ -f "$test_file" ]; then
    # Extract describe/it/test descriptions
    assertions=$(grep -oE '(describe|it|test|@Test)\s*\(["'"'"'][^"'"'"']+["'"'"']' "$test_file" 2>/dev/null | sed "s/.*(['\"']//;s/['\"'].*//" || true)

    while IFS= read -v assertion; do
      [ -z "$assertion" ] && continue
      # Skip top-level describe blocks (not actual test assertions)
      echo "$assertion" | grep -qiE '^(describe|test suite|module|package)' && continue

      ASSERTION_N=$((ASSERTION_N + 1))
      if is_assertion_backed "$test_file" "$assertion" "$criteria"; then
        echo "ASSERTION-${ASSERTION_N}=VALID"
      else
        echo "ASSERTION-${ASSERTION_N}=UNBACKED"
        WARNINGS="${WARNINGS}Assertion '${assertion}' in $tid not backed by criteria; "
        if [ "$ALIGNMENT" = "PASS" ]; then
          ALIGNMENT="NEEDS_REVIEW"
        fi
      fi
    done <<< "$assertions"
  fi
done

# ── Output results ──────────────────────────────────────────────
echo "ALIGNMENT=${ALIGNMENT}"
if [ -n "$WARNINGS" ]; then
  echo "WARNINGS=${WARNINGS}"
fi
