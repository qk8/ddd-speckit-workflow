#!/usr/bin/env bash
# spec-impact.sh — Spec change impact analysis for the DDD Speckit Workflow
#
# Usage: scripts/spec-impact.sh <feature_dir> <old_spec_path> <new_spec_path> [--output <file>]
#
# Analyzes changes between old and new spec.md files and identifies
# which completed tasks are affected.
#
# Bash 3.2 compatible — no jq, no associative arrays.

set -euo pipefail

FEATURE_DIR="${1:?Usage: spec-impact.sh <feature_dir> <old_spec> <new_spec> [--output <file>]}"
OLD_SPEC="${2:?Usage: spec-impact.sh <feature_dir> <old_spec> <new_spec> [--output <file>]}"
NEW_SPEC="${3:?Usage: spec-impact.sh <feature_dir> <old_spec> <new_spec> [--output <file>]}"
OUTPUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT_FILE="${2:-}"; shift ;;
  esac
  shift
done

TASKS_FILE="$FEATURE_DIR/tasks.md"
SPEC_SECTIONS="$FEATURE_DIR/ddd-clean-arch/templates/spec-sections.md"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
mkdir -p "$ARTIFACTS_DIR/spec-impact"

TMPDIR_IMPACT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_IMPACT"' EXIT

# ── Helper: extract section content by §N ────────────────────────
extract_section() {
  local file="$1"
  local section_num="$2"
  local start_pattern="§${section_num}[[:space:]]"
  awk -v pat="$start_pattern" '
    BEGIN { found=0 }
    $0 ~ pat { found=1; next }
    found && /^##?[[:space:]]*§[0-9]+[[:space:]]/ { exit }
    found { print }
  ' "$file" 2>/dev/null
}

# ── Helper: normalize text for comparison ───────────────────────
normalize() {
  tr '[:upper:]' '[:lower:]' | tr -d '[:punct:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'
}

# ── Helper: compute Jaccard similarity ──────────────────────────
jaccard_similarity() {
  local text_a="$1"
  local text_b="$2"
  local norm_a norm_b
  norm_a=$(echo "$text_a" | normalize)
  norm_b=$(echo "$text_b" | normalize)

  if [ "$norm_a" = "$norm_b" ]; then
    echo "1.0"
    return
  fi

  # Tokenize and compute set intersection/union
  local tokens_a tokens_b
  tokens_a=$(echo "$norm_a" | tr ' ' '\n' | sort -u)
  tokens_b=$(echo "$norm_b" | tr ' ' '\n' | sort -u)

  local intersection union
  intersection=$(comm -12 <(echo "$tokens_a") <(echo "$tokens_b") | wc -l | tr -d ' ')
  union=$(echo -e "${tokens_a}\n${tokens_b}" | sort -u | wc -l | tr -d ' ')

  if [ "$union" -eq 0 ]; then
    echo "0.0"
  else
    # Use awk for floating point
    awk -v i="$intersection" -v u="$union" 'BEGIN { printf "%.3f", i/u }'
  fi
}

# ── Step 1: Collect all section numbers ─────────────────────────
SECTIONS_OLD=$(grep -oE '§[0-9]+' "$OLD_SPEC" 2>/dev/null | grep -oE '[0-9]+' | sort -u || true)
SECTIONS_NEW=$(grep -oE '§[0-9]+' "$NEW_SPEC" 2>/dev/null | grep -oE '[0-9]+' | sort -u || true)

# Union of all section numbers
ALL_SECTIONS=$(echo -e "${SECTIONS_OLD}\n${SECTIONS_NEW}" | sort -un | grep -E '^[0-9]+$' || true)

if [ -z "$ALL_SECTIONS" ]; then
  echo "SPEC IMPACT: No sections found in spec files"
  exit 0
fi

# ── Step 2: Diff each section and classify ──────────────────────
CHANGES_FILE="$TMPDIR_IMPACT/changes.txt"
> "$CHANGES_FILE"

CHANGED_COUNT=0

for sec_num in $ALL_SECTIONS; do
  OLD_CONTENT=$(extract_section "$OLD_SPEC" "$sec_num")
  NEW_CONTENT=$(extract_section "$NEW_SPEC" "$sec_num")

  # If section only exists in one file
  if [ -z "$OLD_CONTENT" ] && [ -n "$NEW_CONTENT" ]; then
    echo "§${sec_num} | ADDED | HIGH | New section added" >> "$CHANGES_FILE"
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
    continue
  fi
  if [ -n "$OLD_CONTENT" ] && [ -z "$NEW_CONTENT" ]; then
    echo "§${sec_num} | REMOVED | MEDIUM | Section removed" >> "$CHANGES_FILE"
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
    continue
  fi

  # Both exist — compare content
  SIM=$(jaccard_similarity "$OLD_CONTENT" "$NEW_CONTENT")
  IS_LOW=$(awk -v s="$SIM" 'BEGIN { print (s+0 > 0.85) ? "1" : "0" }')

  if [ "$IS_LOW" = "1" ]; then
    echo "§${sec_num} | CHANGED | LOW | Wording change (similarity: ${SIM})" >> "$CHANGES_FILE"
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
    continue
  fi

  # Classify by severity keywords
  # Combine old and new for keyword analysis
  COMBINED=$(echo -e "${OLD_CONTENT}\n${NEW_CONTENT}")

  # CRITICAL: invariant/rule changes
  IS_CRITICAL=0
  if echo "$NEW_CONTENT" | grep -qiE 'must[[:space:]]+not[[:space:]]+|never[[:space:]]+|required[[:space:]]' 2>/dev/null; then
    if echo "$OLD_CONTENT" | grep -qiE 'must[[:space:]]+not[[:space:]]+|never[[:space:]]+|required[[:space:]]' 2>/dev/null; then
      # Both have critical keywords — check if they changed
      OLD_CRITICAL=$(echo "$OLD_CONTENT" | grep -iE 'must[[:space:]]+not|never|required' 2>/dev/null || true)
      NEW_CRITICAL=$(echo "$NEW_CONTENT" | grep -iE 'must[[:space:]]+not|never|required' 2>/dev/null || true)
      if [ "$OLD_CRITICAL" != "$NEW_CRITICAL" ]; then
        IS_CRITICAL=1
      fi
    else
      IS_CRITICAL=1
    fi
  fi

  # HIGH: behavior changes
  IS_HIGH=0
  if echo "$NEW_CONTENT" | grep -qiE 'returns[[:space:]]|raises[[:space:]]|validates[[:space:]]|rejects[[:space:]]|responds[[:space:]]' 2>/dev/null; then
    if echo "$OLD_CONTENT" | grep -qiE 'returns[[:space:]]|raises[[:space:]]|validates[[:space:]]|rejects[[:space:]]|responds[[:space:]]' 2>/dev/null; then
      OLD_BEHAVIOR=$(echo "$OLD_CONTENT" | grep -iE 'returns |raises |validates |rejects |responds ' 2>/dev/null || true)
      NEW_BEHAVIOR=$(echo "$NEW_CONTENT" | grep -iE 'returns |raises |validates |rejects |responds ' 2>/dev/null || true)
      if [ "$OLD_BEHAVIOR" != "$NEW_BEHAVIOR" ]; then
        IS_HIGH=1
      fi
    else
      IS_HIGH=1
    fi
  fi

  if [ "$IS_CRITICAL" = "1" ]; then
    echo "§${sec_num} | CHANGED | CRITICAL | Invariant/rule changed" >> "$CHANGES_FILE"
  elif [ "$IS_HIGH" = "1" ]; then
    echo "§${sec_num} | CHANGED | HIGH | Behavior changed" >> "$CHANGES_FILE"
  else
    echo "§${sec_num} | CHANGED | MEDIUM | Detail changed" >> "$CHANGES_FILE"
  fi
  CHANGED_COUNT=$((CHANGED_COUNT + 1))
done

if [ "$CHANGED_COUNT" -eq 0 ]; then
  echo "SPEC IMPACT: No changes detected"
  exit 0
fi

# ── Step 3: Map changed sections to affected tasks ──────────────
AFFECTED_FILE="$TMPDIR_IMPACT/affected.txt"
> "$AFFECTED_FILE"

# Parse spec-sections.md for task_type -> §N mapping
if [ -f "$SPEC_SECTIONS" ]; then
  while IFS= read -r line; do
    # Skip comments and empty lines
    echo "$line" | grep -qE '^\s*#' && continue
    echo "$line" | grep -qE '^\s*$' && continue

    # Extract task type (before →)
    TASK_TYPE=$(echo "$line" | sed 's/[[:space:]]*→.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$TASK_TYPE" ] && continue

    # Extract section numbers (after →)
    SECS=$(echo "$line" | grep -oE '§[0-9]+' | grep -oE '[0-9]+' || true)

    for sec_num in $SECS; do
      # Check if this section changed
      if grep -q "^§${sec_num} | CHANGED" "$CHANGES_FILE" 2>/dev/null; then
        CHANGE_TYPE=$(grep "^§${sec_num} | CHANGED" "$CHANGES_FILE" | head -1 | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        CHANGE_DESC=$(grep "^§${sec_num} | CHANGED" "$CHANGES_FILE" | head -1 | awk -F'|' '{print $4}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "${TASK_TYPE}|${sec_num}|${CHANGE_TYPE}|${CHANGE_DESC}" >> "$AFFECTED_FILE"
      fi
    done
  done < "$SPEC_SECTIONS"
fi

# ── Step 4: Find affected DONE tasks ────────────────────────────
CASCADE_REPORT="$TMPDIR_IMPACT/cascade.txt"
> "$CASCADE_REPORT"

if [ -f "$TASKS_FILE" ] && [ -s "$AFFECTED_FILE" ]; then
  # For each task in tasks.md, check if its type matches affected types
  current_task=""
  current_type=""
  current_status=""
  current_ac=""
  in_ac=false

  while IFS= read -r line; do
    if echo "$line" | grep -qE '^## TASK-[0-9]+'; then
      # Process previous task
      if [ -n "$current_task" ] && [ "$current_status" = "DONE" ] && [ -s "$AFFECTED_FILE" ]; then
        # Check if this task's type is in the affected list
        MATCHES=$(grep "^${current_type}|" "$AFFECTED_FILE" 2>/dev/null || true)
        if [ -n "$MATCHES" ]; then
          while IFS='|' read -r match_type match_sec match_severity match_desc; do
            echo "${current_task}|${current_type}|${match_sec}|${match_severity}|${match_desc}" >> "$CASCADE_REPORT"
          done <<< "$MATCHES"
        fi
      fi

      current_task=$(echo "$line" | sed 's/^## //')
      current_type=""
      current_status=""
      in_ac=false
      current_ac=""
      continue
    fi

    if echo "$line" | grep -qE '^Type:' && [ -z "$current_type" ]; then
      current_type=$(echo "$line" | sed 's/^Type:[[:space:]]*//')
      continue
    fi

    if echo "$line" | grep -qE '^Status:'; then
      current_status=$(echo "$line" | sed 's/^Status:[[:space:]]*//')
      continue
    fi

    if echo "$line" | grep -qE '^\[.*\].*- '; then
      in_ac=true
      current_ac="${current_ac}${current_ac:+; }$(echo "$line" | sed 's/^[[:space:]]*//')"
      continue
    fi

    if [ "$in_ac" = true ]; then
      if echo "$line" | grep -qE '^(Do NOT|Built|Test file|Type|Status|Depends|Scope):'; then
        in_ac=false
      else
        current_ac="${current_ac}${current_ac:+; }$(echo "$line" | sed 's/^[[:space:]]*//')"
      fi
    fi
  done < "$TASKS_FILE"

  # Process last task
  if [ -n "$current_task" ] && [ "$current_status" = "DONE" ] && [ -s "$AFFECTED_FILE" ]; then
    MATCHES=$(grep "^${current_type}|" "$AFFECTED_FILE" 2>/dev/null || true)
    if [ -n "$MATCHES" ]; then
      while IFS='|' read -r match_type match_sec match_severity match_desc; do
        echo "${current_task}|${current_type}|${match_sec}|${match_severity}|${match_desc}" >> "$CASCADE_REPORT"
      done <<< "$MATCHES"
    fi
  fi
fi

# ── Step 5: Generate cascade report ─────────────────────────────
REPORT=""
REPORT="SPEC IMPACT CASCADE REPORT
Changed sections: $(cat "$CHANGES_FILE" | awk -F'|' '{printf "%s (%s), ", $1, $3}' | sed 's/, $//')

"

# Group by severity
for severity in CRITICAL HIGH MEDIUM LOW; do
  SEVERITY_TASKS=$(grep "|${severity}|" "$CASCADE_REPORT" 2>/dev/null || true)
  if [ -n "$SEVERITY_TASKS" ]; then
    REPORT="${REPORT}${severity} severity:
"
    while IFS='|' read -r tid ttype tsec tsev tdesc; do
      [ -z "$tid" ] && continue
      REPORT="${REPORT}  ${tid} (${ttype}): \"§${tsec} ${tdesc}\"
"
      # Create affected file for CRITICAL/HIGH
      if [ "$tsev" = "CRITICAL" ] || [ "$tsev" = "HIGH" ]; then
        mkdir -p "$ARTIFACTS_DIR/spec-impact"
        echo "severity: ${tsev}
changed_sections: §${tsec}
description: ${tdesc}" > "$ARTIFACTS_DIR/spec-impact/${tid}.affected"
      fi
    done <<< "$SEVERITY_TASKS"
    REPORT="${REPORT}
"
  fi
done

# ── Step 6: Output ──────────────────────────────────────────────
echo "$REPORT"

if [ -n "$OUTPUT_FILE" ]; then
  echo "$REPORT" > "$OUTPUT_FILE"
fi

# Always write default artifact
echo "$REPORT" > "$ARTIFACTS_DIR/spec-impact-report.txt"

exit 0
