#!/usr/bin/env bash
# prompt-factory.sh — Targeted context extraction for Claude prompts
#
# Usage: scripts/prompt-factory.sh <feature_dir> <task_id> <task_type>
#
# Produces a minimal prompt file at:
#   .artifacts/prompts/<task_id>/context.md
#
# Contains ONLY:
#   - Acceptance criteria from tasks.md for this task
#   - Relevant plan.md sections (extracted via section grep)
#   - Test instructions for this task type
#   - Applicable constraints from plan.md §16
#
# Does NOT include:
#   - CLAUDE.md (human reference only)
#   - Unrelated plan.md sections
#   - Other tasks from tasks.md

set -euo pipefail

FEATURE_DIR="${1:?Usage: prompt-factory.sh <feature_dir> <task_id> <task_type>}"
TASK_ID="${2:?Usage: prompt-factory.sh <feature_dir> <task_id> <task_type>}"
TASK_TYPE="${3:?Usage: prompt-factory.sh <feature_dir> <task_id> <task_type>}"

PLAN_FILE="${FEATURE_DIR}/plan.md"
TASKS_FILE="${FEATURE_DIR}/tasks.md"
SPEC_SECTIONS_FILE="ddd-clean-arch/templates/spec-sections.md"
TEST_INSTRUCTIONS_DIR="ddd-clean-arch/templates/test-instructions"
OUTPUT_DIR="${FEATURE_DIR}/.artifacts/prompts/${TASK_ID}"
mkdir -p "$OUTPUT_DIR"

OUTPUT_FILE="${OUTPUT_DIR}/context.md"

# ── Helper: extract a section from plan.md by §N number ─────────
# Usage: extract_section <plan_file> <section_number>
# Example: extract_section "$PLAN_FILE" "4"
# Extracts from "§4 ..." header to the next "§N ..." header
extract_section() {
  local file="$1"
  local section="$2"
  local start_pattern="§${section}[[:space:]]"

  awk -v pat="$start_pattern" 'BEGIN { found=0 }
    $0 ~ pat { found=1; next }
    found && /^§[0-9]+[[:space:]]/ { exit }
    found { print }
  ' "$file"
}

# ── Helper: extract a task block from tasks.md ──────────────────
# Usage: extract_task <tasks_file> <task_id>
# Strips brackets from task_id (TASK-[3] → 3, TASK-3 → 3)
extract_task() {
  local file="$1"
  local tid="$2"
  # Strip brackets: TASK-[3] → 3, TASK-3 → 3
  tid="${tid#TASK-}"
  tid="${tid#\[}"
  tid="${tid%\]}"

  # Use index() instead of regex matching — mawk cannot handle [N] in -v vars
  awk -v tid="## TASK-[${tid}]" 'BEGIN { found=0 }
    index($0, tid) > 0 { found=1; print; next }
    found && /^## / { exit }
    found { print }
  ' "$file"
}

# ── Helper: extract constraints from plan.md §16 ────────────────
extract_constraints() {
  local file="$1"
  extract_section "$file" "16"
}

# ── Read spec-sections.md mapping for this task type ────────────
SECTION_MAP=""
if [ -f "$SPEC_SECTIONS_FILE" ]; then
  # Extract the line for this task type from spec-sections.md
  SECTION_MAP=$(awk -v ttype="  ${TASK_TYPE} " 'BEGIN { found=0 }
    $0 ~ ttype {
      found=1
      idx = index($0, "→")
      if (idx > 0) {
        print substr($0, idx+1)
      }
      exit
    }
    END { if (!found) exit }
  ' "$SPEC_SECTIONS_FILE" 2>/dev/null || true)
fi

# ── Build the context file ──────────────────────────────────────
{
  echo "# TASK CONTEXT — ${TASK_ID} (${TASK_TYPE})"
  echo ""

  # ── Task details ──────────────────────────────────────────────
  echo "## TASK DETAILS"
  if [ -f "$TASKS_FILE" ]; then
    # Extract task block, skip the ## header line, skip Status/Type/Depends on lines
    # (Type and Depends on are added below from the map)
    extract_task "$TASKS_FILE" "$TASK_ID" | { grep -v "^## " || true; } | { grep -v "^Status:" || true; } | { grep -v "^Type:" || true; } | { grep -v "^Depends on:" || true; } | head -20
    # Include Type and Depends on explicitly
    echo "Type: ${TASK_TYPE}"
    deps=$(awk -v tid="## TASK-[${TASK_ID#TASK-}]" 'BEGIN { found=0 }
      index($0, tid) > 0 { found=1; next }
      found && /^## / { exit }
      found && /^Depends on:/ { print; exit }
    ' "$TASKS_FILE" 2>/dev/null || true)
    if [ -n "$deps" ]; then
      echo "$deps"
    fi
  else
    echo "  (tasks.md not found)"
  fi
  echo ""

  # ── Relevant plan.md sections ─────────────────────────────────
  echo "## RELEVANT PLAN SECTIONS"

  # Parse section map and extract each section
  # The map format is like: "§2, §4 (aggregate in scope only), §6 domain rules, ..."
  # We need to extract the §N numbers
  if [ -n "$SECTION_MAP" ] && [ -f "$PLAN_FILE" ]; then
    # Extract all §N references
    echo "$SECTION_MAP" | { grep -oE '§[0-9]+' || true; } | sed 's/§//' | while read -r sec_num; do
      echo "### §${sec_num}"
      extract_section "$PLAN_FILE" "$sec_num" | head -30
      echo ""
    done
  fi

  # ── Test instructions ─────────────────────────────────────────
  echo "## TEST INSTRUCTIONS"
  local_test_instr="${TEST_INSTRUCTIONS_DIR}/${TASK_TYPE}.md"
  if [ -f "$local_test_instr" ]; then
    head -40 "$local_test_instr"
  else
    echo "  (no test instructions for type '${TASK_TYPE}')"
  fi
  echo ""

  # ── Constraints ───────────────────────────────────────────────
  echo "## CONSTRAINTS (§16)"
  if [ -f "$PLAN_FILE" ]; then
    extract_constraints "$PLAN_FILE" | head -20
  else
    echo "  (plan.md not found)"
  fi
  echo ""

} > "$OUTPUT_FILE"

# ── Print summary ───────────────────────────────────────────────
LINE_COUNT=$(wc -l < "$OUTPUT_FILE" | xargs)
echo "PROMPT FACTORY: ${TASK_ID} (${TASK_TYPE}) → ${OUTPUT_FILE} (${LINE_COUNT} lines)"
echo "  Sections extracted: ${SECTION_MAP:-none}"
