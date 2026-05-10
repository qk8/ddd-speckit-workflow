#!/usr/bin/env bash
# impact-analysis.sh — Cross-task file dependency analysis
#
# Usage: scripts/impact-analysis.sh <feature_dir> <task_id> <task_type> [--show-tests]
#
# Checks if files being modified by a task were also touched by past or future tasks.
# This is the #1 source of silent cascading bugs — one task changes an interface,
# another task's implementation silently breaks.
#
# Bash 3.2 compatible — no jq, no associative arrays.

set -euo pipefail

FEATURE_DIR="${1:?Usage: impact-analysis.sh <feature_dir> <task_id> <task_type> [--show-tests]}"
TASK_ID="${2:?Usage: impact-analysis.sh <feature_dir> <task_id> <task_type> [--show-tests]}"
TASK_TYPE="${3:?Usage: impact-analysis.sh <feature_dir> <task_id> <task_type> [--show-tests]}"
SHOW_TESTS=false

while [ $# -gt 0 ]; do
  case "$1" in
    --show-tests) SHOW_TESTS=true ;;
  esac
  shift
done

TRACKING_DIR="$FEATURE_DIR/.artifacts/created-files"
TASKS_FILE="$FEATURE_DIR/tasks.md"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

TMPDIR_IMPACT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_IMPACT"' EXIT

# File to accumulate results
RESULTS_FILE="$TMPDIR_IMPACT/results.txt"
> "$RESULTS_FILE"

# ── Step 1: Parse all task tracking files (past file touches) ────
# Create a mapping file: filepath -> task_order|task_id
PAST_MAP="$TMPDIR_IMPACT/past_map.txt"
> "$PAST_MAP"

if [ -d "$TRACKING_DIR" ]; then
  order=0
  for tracking_file in "$TRACKING_DIR"/*.files; do
    [ -f "$tracking_file" ] || continue
    tracking_basename=$(basename "$tracking_file" .files)
    order=$((order + 1))
    while IFS= read -r filepath; do
      [ -z "$filepath" ] && continue
      echo "${order}|${tracking_basename}|${filepath}" >> "$PAST_MAP"
    done < "$tracking_file"
  done
fi

# ── Step 2: Parse future task scope from tasks.md ───────────────
FUTURE_MAP="$TMPDIR_IMPACT/future_map.txt"
> "$FUTURE_MAP"

if [ -f "$TASKS_FILE" ]; then
  current_task=""
  current_type=""
  in_scope=false
  in_creates=false
  in_modifies=false

  while IFS= read -r line; do
    # Detect task header
    if echo "$line" | grep -qE '^## TASK-[0-9]+'; then
      # Save previous task's scope
      if [ -n "$current_task" ]; then
        echo "${current_task}|${current_type}|${in_creates}|${in_modifies}" >> "$TMPDIR_IMPACT/task_scope_order.txt"
      fi
      current_task=$(echo "$line" | sed 's/^## //')
      current_type=""
      in_scope=false
      in_creates=false
      in_modifies=false
      continue
    fi

    # Detect task type
    if echo "$line" | grep -qE '^Type:' && [ -z "$current_type" ]; then
      current_type=$(echo "$line" | sed 's/^Type:[[:space:]]*//')
      continue
    fi

    # Detect scope section
    if echo "$line" | grep -qE '^Scope:'; then
      in_scope=true
      in_creates=false
      in_modifies=false
      continue
    fi

    if [ "$in_scope" = true ]; then
      if echo "$line" | grep -qE '^Creates:'; then
        in_creates=true
        in_modifies=false
        continue
      fi
      if echo "$line" | grep -qE '^Modifies:'; then
        in_modifies=true
        in_creates=false
        continue
      fi
      if echo "$line" | grep -qE '^(Acceptance|Do NOT|Built|Test file|Type|Status|Depends):' && ! echo "$line" | grep -qE '^Scope:'; then
        # End of scope section
        if [ -n "$current_task" ]; then
          echo "${current_task}|${current_type}|${in_creates}|${in_modifies}" >> "$TMPDIR_IMPACT/task_scope_order.txt"
        fi
        in_scope=false
        in_creates=false
        in_modifies=false
        continue
      fi

      # Extract file paths from Creates/Modifies lines
      if [ "$in_creates" = true ] || [ "$in_modifies" = true ]; then
        # Handle comma-separated or one-per-line file paths
        echo "$line" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | while IFS= read -r fpath; do
          if echo "$fpath" | grep -qE '\.(ts|tsx|js|jsx|py|go|java|rs|rb|cs|kt|php|swift|sql|yaml|yml|json|md|html|css|scss)$' 2>/dev/null; then
            echo "${current_task}|${current_type}|${fpath}" >> "$FUTURE_MAP"
          fi
        done
      fi
    fi
  done < "$TASKS_FILE"

  # Don't forget the last task
  if [ -n "$current_task" ]; then
    echo "${current_task}|${current_type}|${in_creates}|${in_modifies}" >> "$TMPDIR_IMPACT/task_scope_order.txt"
  fi
fi

# ── Step 3: Get target task's files ─────────────────────────────
TARGET_FILES="$TMPDIR_IMPACT/target_files.txt"
> "$TARGET_FILES"

# From tracking file
if [ -f "$TRACKING_DIR/${TASK_ID}.files" ]; then
  cat "$TRACKING_DIR/${TASK_ID}.files" >> "$TARGET_FILES"
fi

# From tasks.md scope (if task not yet implemented)
if [ -f "$TASKS_FILE" ]; then
  awk -v tid="## $TASK_ID" '
    $0 == tid { found=1; in_scope=0; next }
    found && /^Type:/ { in_scope=1; next }
    found && /^Scope:/ { in_scope=1; next }
    found && in_scope && /^Creates:/ { in_creates=1; in_modifies=0; next }
    found && in_scope && /^Modifies:/ { in_modifies=1; in_creates=0; next }
    found && in_scope && /^Acceptance:/ { in_scope=0; in_creates=0; in_modifies=0 }
    found && in_scope && /^Do NOT:/ { in_scope=0; in_creates=0; in_modifies=0 }
    found && in_scope && /^Built:/ { in_scope=0; in_creates=0; in_modifies=0 }
    found && in_scope && /^Test file:/ { in_scope=0; in_creates=0; in_modifies=0 }
    found && in_scope && (in_creates || in_modifies) {
      gsub(/^[[:space:]]*/, "")
      gsub(/[[:space:]]*$/, "")
      if ($0 ~ /\.(ts|tsx|js|jsx|py|go|java|rs|rb|cs|kt|php|swift|sql|yaml|yml|json|html|css|scss)$/) {
        print
      }
    }
  ' "$TASKS_FILE" >> "$TARGET_FILES" 2>/dev/null || true
fi

# Deduplicate target files
sort -u "$TARGET_FILES" -o "$TARGET_FILES"

# ── Step 4: Compute impact per file ─────────────────────────────
REPORT="$TMPDIR_IMPACT/report.txt"
> "$REPORT"

HIGH_RISK=false
FILE_COUNT=0

while IFS= read -r target_file; do
  [ -z "$target_file" ] && continue
  FILE_COUNT=$((FILE_COUNT + 1))

  # Find past tasks that touched this file
  PAST_TASKS=""
  PAST_COUNT=0
  if [ -s "$PAST_MAP" ]; then
    PAST_TASKS=$(grep "|${target_file}$" "$PAST_MAP" 2>/dev/null | sort -t'|' -k1 -n | awk -F'|' '{print $2}' | tr '\n' ', ' | sed 's/,$//' || true)
    PAST_COUNT=$(grep -c "|${target_file}$" "$PAST_MAP" 2>/dev/null || echo 0)
  fi

  # Find future tasks that will touch this file
  FUTURE_TASKS=""
  FUTURE_COUNT=0
  if [ -s "$FUTURE_MAP" ]; then
    FUTURE_TASKS=$(grep "|${target_file}$" "$FUTURE_MAP" 2>/dev/null | awk -F'|' '{print $1}' | sort -u | tr '\n' ', ' | sed 's/,$//' || true)
    FUTURE_COUNT=$(grep -c "|${target_file}$" "$FUTURE_MAP" 2>/dev/null || echo 0)
  fi

  # Deduplicate (remove self)
  if [ -n "$PAST_TASKS" ]; then
    PAST_TASKS=$(echo "$PAST_TASKS" | tr ',' '\n' | grep -v "^${TASK_ID}$" | tr '\n' ', ' | sed 's/,$//' || true)
  fi
  if [ -n "$FUTURE_TASKS" ]; then
    FUTURE_TASKS=$(echo "$FUTURE_TASKS" | tr ',' '\n' | grep -v "^${TASK_ID}$" | tr '\n' ', ' | sed 's/,$//' || true)
  fi

  # Compute risk
  CROSS_COUNT=$((PAST_COUNT + FUTURE_COUNT))
  if [ "$CROSS_COUNT" -eq 0 ]; then
    RISK="LOW"
  elif [ "$CROSS_COUNT" -le 2 ]; then
    RISK="MEDIUM"
  else
    RISK="HIGH"
  fi

  # Special: any past AND any future overlap → escalate to HIGH
  if [ "$PAST_COUNT" -gt 0 ] && [ "$FUTURE_COUNT" -gt 0 ]; then
    RISK="HIGH"
  fi

  if [ "$RISK" = "HIGH" ]; then
    HIGH_RISK=true
  fi

  # Find test files (heuristic)
  TEST_FILES=""
  if [ "$SHOW_TESTS" = true ]; then
    # Extract basename without extension
    base=$(basename "$target_file")
    name_no_ext="${base%.*}"
    ext="${base##*.}"

    # Look for test files with same basename in test directories
    test_candidates=$(find "$FEATURE_DIR" -type f \( -name "${name_no_ext}.test.${ext}" -o -name "${name_no_ext}.spec.${ext}" -o -name "${name_no_ext}Test.${ext}" -o -name "${name_no_ext}_test.${ext}" \) \
      ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' 2>/dev/null || true)
    if [ -n "$test_candidates" ]; then
      TEST_FILES=$(echo "$test_candidates" | sed "s|^${FEATURE_DIR}/||" | tr '\n' ', ' | sed 's/,$//')
    fi
  fi

  # Format past/future display
  past_display="none"
  if [ -n "$PAST_TASKS" ]; then
    past_display="$PAST_TASKS"
  fi

  future_display="none"
  if [ -n "$FUTURE_TASKS" ]; then
    future_display="$FUTURE_TASKS"
  fi

  echo "  $target_file" >> "$REPORT"
  echo "    Past: $past_display ($PAST_COUNT)" >> "$REPORT"
  echo "    Future: $future_display ($FUTURE_COUNT)" >> "$REPORT"
  if [ -n "$TEST_FILES" ]; then
    echo "    Tests: $TEST_FILES" >> "$REPORT"
  fi
  echo "    Risk: $RISK ($CROSS_COUNT overlapping tasks)" >> "$REPORT"
  echo "" >> "$REPORT"

done < "$TARGET_FILES"

# ── Step 5: Output report ───────────────────────────────────────
OUTPUT=""
if [ "$FILE_COUNT" -eq 0 ]; then
  OUTPUT="IMPACT ANALYSIS: $TASK_ID — no files in scope"
else
  OUTPUT="IMPACT ANALYSIS: $TASK_ID ($TASK_TYPE)"
  OUTPUT="$OUTPUT
  Files analyzed: $FILE_COUNT"
  if [ -s "$REPORT" ]; then
    OUTPUT="$OUTPUT
$(cat "$REPORT")"
  fi
  if [ "$HIGH_RISK" = true ]; then
    OUTPUT="$OUTPUT
HIGH risk files require explicit confirmation before proceeding."
  fi
fi

# Write to artifact
echo "$OUTPUT" > "$ARTIFACTS_DIR/impact-report.txt"

# Print to stdout
echo "$OUTPUT"

exit 0
