#!/usr/bin/env bash
# unified-context.sh — Assemble unified JSON context for a single task
#
# Usage: scripts/unified-context.sh <feature_dir> <task_id> <task_type>
#
# Produces: <feature_dir>/.artifacts/unified-context.json
#
# This replaces reading 8-12 files independently. The JSON contains:
#   - Task details (from tasks.md)
#   - Relevant plan.md sections (FULL text, no truncation)
#   - §16 constraints (previously skipped by prompt-factory.sh)
#   - Layer rules (from CLAUDE.md, only relevant layers)
#   - Test instructions (FULL text, no 40-line truncation)
#   - Error memory (last 5 corrections)
#   - Checkpoint state (from .workflow-state.json)
#
# File size target: < 5KB (vs ~1000+ lines of separate reads)

set -euo pipefail

FEATURE_DIR="${1:?Usage: unified-context.sh <feature_dir> <task_id> <task_type>}"
TASK_ID="${2:?Usage: unified-context.sh <feature_dir> <task_id> <task_type>}"
TASK_TYPE="${3:?Usage: unified-context.sh <feature_dir> <task_id> <task_type>}"

PLAN_FILE="${FEATURE_DIR}/plan.md"
TASKS_FILE="${FEATURE_DIR}/tasks.md"
CLAUDE_MD="${FEATURE_DIR}/CLAUDE.md"
SPEC_SECTIONS_FILE="ddd-clean-arch/templates/spec-sections.md"
TEST_INSTRUCTIONS_DIR="ddd-clean-arch/templates/test-instructions"
WORKFLOW_STATE="${FEATURE_DIR}/.workflow-state.json"
ERROR_MEMORY="${FEATURE_DIR}/.artifacts/error-memory.json"
OUTPUT_DIR="${FEATURE_DIR}/.artifacts"
OUTPUT_FILE="${OUTPUT_DIR}/unified-context.json"
mkdir -p "$OUTPUT_DIR"

# ── Helper: escape a string for JSON ───────────────────────────
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s=$(printf '%s' "$s" | tr -d '\000-\011\013-\037' 2>/dev/null || echo "$s")
  printf '%s' "$s"
}

# ── Helper: extract a section from plan.md by §N number ─────────
extract_section() {
  local file="$1"
  local section="$2"
  local start_pattern="§${section}[[:space:]]"

  awk -v pat="$start_pattern" 'BEGIN { found=0 }
    $0 ~ pat { found=1; next }
    found && /^##?[[:space:]]*§[0-9]+[[:space:]]/ { exit }
    found { print }
  ' "$file"
}

# ── Helper: extract task block from tasks.md ────────────────────
extract_task() {
  local file="$1"
  local tid="$2"
  tid="${tid#TASK-}"
  tid="${tid#\[}"
  tid="${tid%\]}"

  awk -v tid="## TASK-[${tid}]" 'BEGIN { found=0 }
    index($0, tid) > 0 { found=1; print; next }
    found && /^## / { exit }
    found { print }
  ' "$file"
}

# ── Helper: JSON-encode a file's content as a single string ─────
# Replaces newlines with \n for JSON embedding
json_string_from_file() {
  local file="$1"
  if [ -f "$file" ]; then
    sed -n 'p' "$file" | while IFS= read -r line; do
      json_escape "$line"
      printf 'N'  # placeholder for newline
    done | sed 's/N/\\n/g'
  fi
}

# ── Helper: JSON-encode a multi-line string as a single string ──
json_string() {
  local s="$1"
  if [ -n "$s" ]; then
    printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' '\r' | sed 's/\r/\\n/g'
  fi
}

# ── Helper: build a JSON array from pipe-delimited items ────────
json_array_from_delim() {
  local items="$1"
  if [ -z "$items" ]; then
    printf '[]'
    return
  fi
  printf '['
  local first=true
  IFS='|' read -ra arr <<< "$items"
  for item in "${arr[@]}"; do
    item=$(echo "$item" | xargs | sed 's/\[//g;s/\]//g')
    if [ -n "$item" ]; then
      if [ "$first" = false ]; then printf ', '; fi
      printf '"%s"' "$(json_escape "$item")"
      first=false
    fi
  done
  printf ']'
}

# ── Helper: build a JSON array from comma-separated items ───────
json_array_from_csv() {
  local items="$1"
  if [ -z "$items" ]; then
    printf '[]'
    return
  fi
  printf '['
  local first=true
  IFS=',' read -ra arr <<< "$items"
  for item in "${arr[@]}"; do
    item=$(echo "$item" | xargs | sed 's/\[//g;s/\]//g')
    if [ -n "$item" ]; then
      if [ "$first" = false ]; then printf ', '; fi
      printf '"%s"' "$(json_escape "$item")"
      first=false
    fi
  done
  printf ']'
}

# ── 1. Build task JSON ──────────────────────────────────────────
build_task() {
  local status="TODO"
  local title=""
  local depends_on_raw=""
  local scope_creates=""
  local scope_modifies=""
  local criteria=""
  local do_not=""

  if [ -f "$TASKS_FILE" ]; then
    local task_block
    task_block=$(extract_task "$TASKS_FILE" "$TASK_ID")

    while IFS= read -r line; do
      case "$line" in
        "## TASK-"*)
          title=$(echo "$line" | sed 's/^## TASK-\[[0-9]*\]: //;s/^## TASK-\[[0-9]*\] //;s/^## TASK-[0-9]* //')
          ;;
        "Status:"*) status=$(echo "$line" | sed 's/^Status:[[:space:]]*//') ;;
        "Depends on:"*) depends_on_raw=$(echo "$line" | sed 's/^Depends on:[[:space:]]*//') ;;
        "Scope:"*) scope_creates=$(echo "$line" | sed 's/^Scope:[[:space:]]*//;s/^Creates[[:space:]]*//') ;;
        "Creates:"*) scope_creates=$(echo "$line" | sed 's/^Creates:[[:space:]]*//') ;;
        "Modifies:"*) scope_modifies=$(echo "$line" | sed 's/^Modifies:[[:space:]]*//') ;;
        "Do NOT"*) do_not=$(echo "$line" | sed 's/^Do NOT[[:space:]]*:[[:space:]]*//') ;;
      esac
      # Extract numbered acceptance criteria
      if echo "$line" | grep -qE '^[[:space:]]*[0-9]+\.'; then
        local criterion
        criterion=$(echo "$line" | sed 's/^[[:space:]]*[0-9]*\.[[:space:]]*//')
        if [ -n "$criterion" ]; then
          if [ -n "$criteria" ]; then
            criteria="${criteria}|${criterion}"
          else
            criteria="$criterion"
          fi
        fi
      fi
    done <<< "$task_block"
  fi

  printf '  "task": {\n'
  printf '    "id": "%s",\n' "$TASK_ID"
  printf '    "title": "%s",\n' "$(json_escape "$title")"
  printf '    "status": "%s",\n' "$status"
  printf '    "type": "%s",\n' "$TASK_TYPE"
  printf '    "depends_on": %s,\n' "$(json_array_from_csv "$depends_on_raw")"
  printf '    "scope": {"creates": %s, "modifies": %s},\n' \
    "$(json_array_from_csv "$scope_creates")" \
    "$(json_array_from_csv "$scope_modifies")"
  printf '    "acceptance_criteria": %s,\n' "$(json_array_from_delim "$criteria")"
  printf '    "do_not": %s\n' "$(json_array_from_delim "$do_not")"
  printf '  }'
}

# ── 2. Build plan sections JSON ─────────────────────────────────
build_plan_sections() {
  if [ ! -f "$PLAN_FILE" ] || [ ! -f "$SPEC_SECTIONS_FILE" ]; then
    printf '  "plan_sections": [],\n  "plan_sections_included": []'
    return
  fi

  local section_map
  section_map=$(awk -v ttype="  ${TASK_TYPE} " 'BEGIN { found=0 }
    $0 ~ ttype {
      found=1
      idx = index($0, "→")
      if (idx > 0) print substr($0, idx+1)
      exit
    }
  ' "$SPEC_SECTIONS_FILE" 2>/dev/null || true)

  if [ -z "$section_map" ]; then
    printf '  "plan_sections": [],\n  "plan_sections_included": []'
    return
  fi

  local section_nums
  section_nums=$(echo "$section_map" | grep -oE '§[0-9]+' | sed 's/§//' || true)

  if [ -z "$section_nums" ]; then
    printf '  "plan_sections": [],\n  "plan_sections_included": []'
    return
  fi

  printf '  "plan_sections": ['
  local first=true
  local included=""

  for sec_num in $section_nums; do
    local sec_title
    sec_title=$(awk -v pat="§${sec_num}[[:space:]]" '
      $0 ~ pat { sub(/.*§[0-9]+[[:space:]]/, ""); print; exit }
    ' "$PLAN_FILE" 2>/dev/null || echo "Section ${sec_num}")

    local sec_content
    sec_content=$(extract_section "$PLAN_FILE" "$sec_num")

    if [ -n "$sec_content" ]; then
      if [ "$first" = false ]; then printf ','; fi
      printf '\n    {"section": "§%s", "title": "%s", "content": "%s"}' \
        "$sec_num" \
        "$(json_escape "$sec_title")" \
        "$(json_string "$sec_content")"
      if [ -n "$included" ]; then included="${included}, "; fi
      included="${included}\"§${sec_num}\""
      first=false
    fi
  done

  printf '\n  ],\n  "plan_sections_included": [%s]' "$included"
}

# ── 3. Build constraints JSON ───────────────────────────────────
build_constraints() {
  if [ ! -f "$PLAN_FILE" ]; then
    printf '  "constraints": {"source": "§16", "rules": []}'
    return
  fi

  local constraints_content
  constraints_content=$(extract_section "$PLAN_FILE" "16")

  if [ -z "$constraints_content" ]; then
    printf '  "constraints": {"source": "§16", "rules": []}'
    return
  fi

  local rules=""
  local first=true

  while IFS= read -r line; do
    if echo "$line" | grep -qE '^[[:space:]]*(Never|[0-9]+\.|-)[[:space:]]'; then
      local rule
      rule=$(echo "$line" | sed 's/^[[:space:]]*[-0-9.]*[[:space:]]*//')
      if [ -n "$rule" ]; then
        if [ "$first" = false ]; then rules="${rules}, "; fi
        rules="${rules}\"$(json_escape "$rule")\""
        first=false
      fi
    fi
  done <<< "$constraints_content"

  if [ -z "$rules" ]; then
    printf '  "constraints": {"source": "§16", "rules": ["%s"]}' "$(json_escape "$constraints_content" | head -c 100)"
  else
    printf '  "constraints": {"source": "§16", "rules": [%s]}' "$rules"
  fi
}

# ── 4. Build layer rules JSON ───────────────────────────────────
build_layer_rules() {
  if [ ! -f "$CLAUDE_MD" ]; then
    printf '  "layer_rules": {}'
    return
  fi

  local layer_content
  layer_content=$(awk '
    /^## Layer rules/ { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$CLAUDE_MD" 2>/dev/null || true)

  if [ -z "$layer_content" ]; then
    printf '  "layer_rules": {}'
    return
  fi

  printf '  "layer_rules": {'
  local current_layer=""
  local current_rules=""
  local first_layer=true

  while IFS= read -r line; do
    if echo "$line" | grep -qE '^[A-Za-z]+ layer:'; then
      if [ -n "$current_layer" ] && [ -n "$current_rules" ]; then
        if [ "$first_layer" = false ]; then printf ','; fi
        printf '\n    "%s": [%s]' "$(json_escape "$current_layer")" "$current_rules"
        first_layer=false
      fi
      current_layer=$(echo "$line" | sed 's/:$//')
      current_rules=""
    elif echo "$line" | grep -qE '^[[:space:]]+- ' && [ -n "$current_layer" ]; then
      local rule
      rule=$(echo "$line" | sed 's/^[[:space:]]+- //')
      if [ -n "$current_rules" ]; then current_rules="${current_rules}, "; fi
      current_rules="${current_rules}\"$(json_escape "$rule")\""
    fi
  done <<< "$layer_content"

  if [ -n "$current_layer" ] && [ -n "$current_rules" ]; then
    if [ "$first_layer" = false ]; then printf ','; fi
    printf '\n    "%s": [%s]' "$(json_escape "$current_layer")" "$current_rules"
  fi

  printf '\n  }'
}

# ── 5. Build test instructions JSON ─────────────────────────────
build_test_instructions() {
  local test_file="${TEST_INSTRUCTIONS_DIR}/${TASK_TYPE}.md"
  local template_content=""
  local template_source="none"

  if [ -f "$test_file" ]; then
    template_content=$(json_string "$(cat "$test_file")")
    template_source="${TEST_INSTRUCTIONS_DIR}/${TASK_TYPE}.md"
  fi

  local plan_subsection=""
  local plan_content=""
  if [ -f "$PLAN_FILE" ]; then
    case "$TASK_TYPE" in
      backend-domain)   plan_subsection="unit_tests" ;;
      backend-infra)    plan_subsection="integration_tests" ;;
      backend-api)      plan_subsection="api_tests" ;;
      shared)           plan_subsection="contract_testing" ;;
      integration)      plan_subsection="integration_tests" ;;
      frontend-data)    plan_subsection="unit_tests" ;;
      frontend-feature) plan_subsection="e2e_tests" ;;
      e2e)              plan_subsection="e2e_tests" ;;
      *)                plan_subsection="unit_tests" ;;
    esac
    # Extract subsection from §13
    local section13
    section13=$(extract_section "$PLAN_FILE" "13" 2>/dev/null || true)
    if [ -n "$section13" ]; then
      plan_content=$(echo "$section13" | sed -n "/${plan_subsection}/,/^[[:space:]]*$/p" | head -30 || true)
    fi
  fi

  printf '  "test_instructions": {\n'
  printf '    "template_source": "%s",\n' "$template_source"
  printf '    "plan_section": {\n'
  printf '      "section": "§13",\n'
  printf '      "subsection": "%s",\n' "$plan_subsection"
  printf '      "content": "%s"\n' "$(json_escape "$plan_content")"
  printf '    },\n'
  printf '    "template_content": "%s"\n' "$template_content"
  printf '  }'
}

# ── 6. Build error memory JSON ──────────────────────────────────
build_error_memory() {
  if [ ! -f "$ERROR_MEMORY" ]; then
    printf '  "error_memory": {"corrections": [], "drift_patterns": []}'
    return
  fi

  local corrections_json=""
  corrections_json=$(awk '
    BEGIN { in_corr=0 }
    /"task"/ { in_corr=1; task=""; type=""; desc=""; fix="" }
    in_corr && /"type"/ { gsub(/.*"type": *"/, ""); gsub(/".*/, ""); type=$0 }
    in_corr && /"description"/ { gsub(/.*"description": *"/, ""); gsub(/".*/, ""); desc=$0 }
    in_corr && /"fix"/ { gsub(/.*"fix": *"/, ""); gsub(/".*/, ""); fix=$0 }
    in_corr && /}/ {
      if (count <= 5) {
        if (count > 0) printf ", "
        printf "{\"task\":\"%s\",\"type\":\"%s\",\"description\":\"%s\",\"fix\":\"%s\"}", task, type, desc, fix
      }
      count++
      in_corr=0
    }
  ' "$ERROR_MEMORY" 2>/dev/null || true)

  local drift_json=""
  drift_json=$(awk '
    BEGIN { in_drift=0 }
    /"pattern"/ { in_drift=1; pat=""; desc="" }
    in_drift && /"description"/ { gsub(/.*"description": *"/, ""); gsub(/".*/, ""); desc=$0 }
    in_drift && /}/ {
      if (count <= 5) {
        if (count > 0) printf ", "
        printf "{\"pattern\":\"%s\",\"description\":\"%s\"}", pat, desc
      }
      count++
      in_drift=0
    }
  ' "$ERROR_MEMORY" 2>/dev/null || true)

  printf '  "error_memory": {"corrections": [%s], "drift_patterns": [%s]}' "$corrections_json" "$drift_json"
}

# ── 7. Build checkpoint JSON ────────────────────────────────────
build_checkpoint() {
  local task_status="UNKNOWN"

  if [ -f "$WORKFLOW_STATE" ]; then
    task_status=$(awk -v tid="${TASK_ID#TASK-}" '
      /TASK-\[?[0-9]+\]?/ { gsub(/\[|\]/, ""); if ($2 == "TASK-" tid || $2 == tid) found=1 }
      found && /^Status:/ { print; exit }
    ' "$WORKFLOW_STATE" 2>/dev/null || echo "UNKNOWN")
  fi

  printf '  "checkpoint": {"task_status": "%s", "checks": {}, "completed_at": ""}' "$task_status"
}

# ── Assemble final JSON ─────────────────────────────────────────
{
  printf '{\n'
  printf '  "version": 1,\n'
  printf '  "meta": {\n'
  printf '    "feature_dir": "%s",\n' "$(json_escape "$FEATURE_DIR")"
  printf '    "task_id": "%s",\n' "$TASK_ID"
  printf '    "task_type": "%s",\n' "$TASK_TYPE"
  printf '    "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '    "source_plan": "plan.md"\n'
  printf '  },\n'

  build_task
  printf ',\n'

  build_plan_sections
  printf ',\n'

  build_constraints
  printf ',\n'

  build_layer_rules
  printf ',\n'

  build_test_instructions
  printf ',\n'

  build_error_memory
  printf ',\n'

  build_checkpoint
  printf '\n}\n'
} > "$OUTPUT_FILE"

# ── Print summary ───────────────────────────────────────────────
LINE_COUNT=$(wc -l < "$OUTPUT_FILE" | xargs)
FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | xargs)
echo "UNIFIED CONTEXT: ${TASK_ID} (${TASK_TYPE}) → ${OUTPUT_FILE} (${LINE_COUNT} lines, ${FILE_SIZE} bytes)"
