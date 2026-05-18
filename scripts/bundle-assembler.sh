#!/usr/bin/env bash
# bundle-assembler.sh — Assemble phase-scoped knowledge bundles
#
# Usage: bundle-assembler.sh <phase> <task_id> <feature_dir> [--max-lines N] [--output FILE]
#
# Phases: clarify, spec, plan, tasks, implement, verify, code-review
#
# Produces: <feature_dir>/.artifacts/bundles/<phase>-<task_id>.md
#
# The LLM reads ONE file, not 10+.

set -euo pipefail

# ── Argument parsing ────────────────────────────────────────────
VALID_PHASES="clarify spec plan tasks implement verify code-review"
PHASE="${1:?Usage: bundle-assembler.sh <phase> <task_id> <feature_dir> [--max-lines N] [--output FILE]}"
TASK_ID="${2:?Usage: bundle-assembler.sh <phase> <task_id> <feature_dir>}"
FEATURE_DIR="${3:?Usage: bundle-assembler.sh <phase> <task_id> <feature_dir>}"
MAX_LINES=200
OUTPUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --max-lines) MAX_LINES="${2:?}"; shift ;;
    --output) OUTPUT_FILE="${2:?}"; shift ;;
  esac
  shift
done

# Validate phase
VALID=false
for p in $VALID_PHASES; do
  [ "$p" = "$PHASE" ] && VALID=true
done
if [ "$VALID" = false ]; then
  echo "ERROR: Unknown phase '$PHASE'. Valid: $VALID_PHASES" >&2
  exit 1
fi

# Defaults
MAX_PER_SECTION=$(( MAX_LINES / 4 ))
[ "$MAX_PER_SECTION" -lt 10 ] && MAX_PER_SECTION=10
OUTPUT_DIR="${FEATURE_DIR}/.artifacts/bundles"
mkdir -p "$OUTPUT_DIR"
[ -z "$OUTPUT_FILE" ] && OUTPUT_FILE="${OUTPUT_DIR}/${PHASE}-${TASK_ID}.md"

# Ensure output directory exists (handles --output to arbitrary paths)
mkdir -p "$(dirname "$OUTPUT_FILE")"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
STATE_FILE="${FEATURE_DIR}/state.json"
PLAN_FILE="${FEATURE_DIR}/plan.md"
TASKS_FILE="${FEATURE_DIR}/tasks.md"
CLAUDE_MD="${FEATURE_DIR}/CLAUDE.md"
PROJECT_BRIEF="${FEATURE_DIR}/project-brief.md"
SPEC_FILE="${FEATURE_DIR}/.specify/specs/*/spec.md"
SPEC_SECTIONS="${BASE_DIR}/ddd-clean-arch/templates/spec-sections.md"
PRESET_YML="${BASE_DIR}/ddd-clean-arch/preset.yml"
TEST_INSTR_DIR="${BASE_DIR}/ddd-clean-arch/templates/test-instructions"
GUIDE_CORRECTION="${BASE_DIR}/ddd-clean-arch/guides/correction-loop.md"
GUIDE_TASK_SEL="${BASE_DIR}/ddd-clean-arch/guides/task-selection.md"
FAILURE_MODES="${BASE_DIR}/docs/failure-modes.md"
IMPACT_REPORT="${FEATURE_DIR}/.artifacts/impact-report.txt"

# ── Helpers ─────────────────────────────────────────────────────
jq_q() {
  [ -f "$STATE_FILE" ] && jq -r "$@" "$STATE_FILE" 2>/dev/null || true
}

jq_q_file() {
  [ -f "$1" ] && jq -r "$2" "$1" 2>/dev/null || true
}

extract_section() {
  local file="$1" section="$2" cap="${3:-0}"
  [ ! -f "$file" ] && return
  awk -v pat="§${section}[[:space:]]" -v cap="$cap" '
    BEGIN { found=0; lines=0 }
    $0 ~ pat { found=1; next }
    found && /^§[0-9]+[[:space:]]/ { exit }
    found && /^##?[[:space:]]+§[0-9]+[[:space:]]/ { exit }
    found { lines++; if (cap > 0 && lines > cap) exit; print }
  ' "$file"
}

extract_section_title() {
  local file="$1" section="$2"
  [ ! -f "$file" ] && return
  awk -v pat="§${section}[[:space:]]" '$0 ~ pat { sub(/.*§[0-9]+[[:space:]]/, ""); print; exit }' "$file"
}

maybe_file() {
  [ -f "$1" ] && cat "$1" || echo "  (not found: $1)"
}

read_last_n_lines() {
  local file="$1" n="${2:-30}"
  [ -f "$file" ] && tail -n "$n" "$file" || echo "  (not found: $file)"
}

spec_for_type() {
  # Extract spec.md path for a feature
  local fdir="$1"
  local spec_path
  spec_path=$(find "$fdir/.specify/specs" -name "spec.md" 2>/dev/null | head -1)
  echo "${spec_path:-}"
}

# ── Get spec-sections mapping for task type ─────────────────────
get_section_nums() {
  local ttype="$1"
  [ ! -f "$SPEC_SECTIONS" ] && return
  awk -v ttype="  ${ttype} " '
    BEGIN { found=0; collecting=0 }
    !found && $0 ~ ttype {
      found=1; idx=index($0,"→")
      if(idx>0) print substr($0,idx+1)
      collecting=1; next
    }
    found && collecting {
      if (/→/) { collecting=0; next }
      if (/^[[:space:]]/) { print; next }
      collecting=0
    }
  ' "$SPEC_SECTIONS" 2>/dev/null | grep -oE '§[0-9]+' | sed 's/§//' | sort -un || true
}

# ── Context rotation (implement phase only) ─────────────────────
if [ "$PHASE" = "implement" ]; then
  bash scripts/context-rotate.sh "$FEATURE_DIR" 2>/dev/null || true
fi

# ── Output header ──────────────────────────────────────────────
{
echo "# Bundle: ${PHASE} / ${TASK_ID}"
echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# ── Phase builders ──────────────────────────────────────────────
case "$PHASE" in

clarify)
  echo "## Project Brief"
  maybe_file "$PROJECT_BRIEF"
  echo ""
  local_spec=$(spec_for_type "$FEATURE_DIR")
  if [ -n "$local_spec" ]; then
    echo "## Spec"
    cat "$local_spec"
    echo ""
  fi
  echo "## Spec Sections Reference"
  maybe_file "$SPEC_SECTIONS"
  ;;

spec)
  echo "## Project Brief"
  maybe_file "$PROJECT_BRIEF"
  echo ""
  local_spec=$(spec_for_type "$FEATURE_DIR")
  if [ -n "$local_spec" ]; then
    echo "## Existing Spec"
    cat "$local_spec"
    echo ""
  else
    echo "## Existing Spec"
    echo "  (none — first spec)"
    echo ""
  fi
  echo "## CLAUDE.md (Layer Rules, Conventions)"
  maybe_file "$CLAUDE_MD"
  echo ""
  echo "## Spec Sections Reference"
  maybe_file "$SPEC_SECTIONS"
  ;;

plan)
  echo "## Project Brief"
  maybe_file "$PROJECT_BRIEF"
  echo ""
  local_spec=$(spec_for_type "$FEATURE_DIR")
  if [ -n "$local_spec" ]; then
    echo "## Spec"
    cat "$local_spec"
    echo ""
  fi
  echo "## CLAUDE.md"
  maybe_file "$CLAUDE_MD"
  echo ""
  echo "## Spec Sections Reference"
  maybe_file "$SPEC_SECTIONS"
  echo ""
  echo "## Preset Config"
  if [ -f "$PRESET_YML" ]; then
    echo '```yaml'
    head -60 "$PRESET_YML"
    echo '```'
  else
    echo "  (not found)"
  fi
  echo ""
  echo "## Failure Mode Catalog"
  maybe_file "$FAILURE_MODES"
  ;;

tasks)
  echo "## Plan.md"
  if [ -f "$PLAN_FILE" ]; then
    head -80 "$PLAN_FILE"
    echo "  ... (see full plan.md for complete content)"
  else
    echo "  (not found)"
  fi
  echo ""
  echo "## CLAUDE.md"
  maybe_file "$CLAUDE_MD"
  echo ""
  echo "## Spec Sections Reference"
  maybe_file "$SPEC_SECTIONS"
  echo ""
  echo "## Preset Config"
  if [ -f "$PRESET_YML" ]; then
    echo '```yaml'
    head -60 "$PRESET_YML"
    echo '```'
  else
    echo "  (not found)"
  fi
  ;;

implement)
  # ── Task details from state.json ────────────────────────────
  echo "## Task"
  local_ttype=""
  if [ -f "$STATE_FILE" ]; then
    local_title=$(jq_q ".tasks[\"$TASK_ID\"].title // \"(unknown)\"" 2>/dev/null || echo "(unknown)")
    local_ttype=$(jq_q ".tasks[\"$TASK_ID\"].type // \"(unknown)\"" 2>/dev/null || echo "(unknown)")
    local_status=$(jq_q ".tasks[\"$TASK_ID\"].status // \"TODO\"" 2>/dev/null || echo "TODO")
    local_depends=$(jq_q ".tasks[\"$TASK_ID\"].depends_on // [] | join(\", \")" 2>/dev/null || echo "")
    local_creates=$(jq_q ".tasks[\"$TASK_ID\"].scope.creates // [] | join(\", \")" 2>/dev/null || echo "")
    local_modifies=$(jq_q ".tasks[\"$TASK_ID\"].scope.modifies // [] | join(\", \")" 2>/dev/null || echo "")
    echo "Title: ${local_title}"
    echo "Type: ${local_ttype}"
    echo "Status: ${local_status}"
    echo "Depends: [${local_depends}]"
    echo "Scope: Creates: [${local_creates}], Modifies: [${local_modifies}]"
  else
    echo "Title: (unknown)"
    echo "Type: (unknown)"
    echo "Status: TODO"
    echo "Depends: []"
    echo "Scope: Creates: [], Modifies: []"
  fi
  echo ""

  # ── Acceptance criteria ─────────────────────────────────────
  echo "## Acceptance Criteria"
  if [ -f "$STATE_FILE" ]; then
    jq_q ".tasks[\"$TASK_ID\"].acceptance_criteria // [] | to_entries[] | \"\(.key + 1). \(.value)\"" 2>/dev/null | while IFS= read -r line; do
      echo "$line"
    done
  fi
  if [ -f "$TASKS_FILE" ]; then
    # Fallback: parse from tasks.md if state.json has no criteria
    awk -v tid="## ${TASK_ID}" '
      index($0, tid) { found=1; next }
      found && /^## / { exit }
      found && /^[[:space:]]*[0-9]+\./ { gsub(/^[[:space:]]*[0-9]+\.[[:space:]]*/, ""); print }
    ' "$TASKS_FILE" 2>/dev/null
  fi
  echo ""

  # ── Do NOT ──────────────────────────────────────────────────
  echo "## Do NOT"
  if [ -f "$STATE_FILE" ]; then
    jq_q ".tasks[\"$TASK_ID\"].do_not // [] | .[] | \"- \" + ." 2>/dev/null
  fi
  if [ -f "$TASKS_FILE" ]; then
    awk -v tid="## ${TASK_ID}" '
      index($0, tid) { found=1; next }
      found && /^## / { exit }
      found && /^Do NOT/ { skip=1; next }
      found && skip && /^-/ { gsub(/^-[[:space:]]*/, ""); print }
      found && skip && !/^[-[:space:]]/ { skip=0 }
    ' "$TASKS_FILE" 2>/dev/null
  fi
  echo ""

  # ── Plan sections (via spec-sections mapping) ───────────────
  if [ -f "$PLAN_FILE" ] && [ -n "$local_ttype" ] && [ "$local_ttype" != "(unknown)" ]; then
    echo "## Plan Sections (relevant to ${local_ttype})"
    section_nums=$(get_section_nums "$local_ttype")
    for sec_num in $section_nums; do
      sec_title=$(extract_section_title "$PLAN_FILE" "$sec_num")
      echo "### §${sec_num} ${sec_title}"
      extract_section "$PLAN_FILE" "$sec_num" "$MAX_PER_SECTION"
      echo ""
    done
    # Always include §16 (constraints) — full, never truncated
    echo "### §16 Constraints"
    extract_section "$PLAN_FILE" "16" 0
    echo ""
  fi

  # ── Layer rules ─────────────────────────────────────────────
  echo "## Layer Rules"
  if [ -f "$CLAUDE_MD" ]; then
    awk '/^## Layer rules/{found=1; next} found && /^## /{exit} found{print}' "$CLAUDE_MD" 2>/dev/null
  fi
  echo ""

  # ── Test instructions ───────────────────────────────────────
  echo "## Test Instructions"
  local_test_file=""
  [ -n "$local_ttype" ] && [ "$local_ttype" != "(unknown)" ] && local_test_file="${TEST_INSTR_DIR}/${local_ttype}.md"
  if [ -n "$local_test_file" ] && [ -f "$local_test_file" ]; then
    cat "$local_test_file"
  else
    echo "  (no test instructions for type '${local_ttype:-unknown}')"
  fi
  echo ""

  # ── Error memory ────────────────────────────────────────────
  echo "## Error Memory (last 5 corrections)"
  if [ -f "$STATE_FILE" ]; then
    jq_q '.history[] | select(.phase == "verify" or .phase == "implement") | "- \(.task): \(.result) (iteration \(.iteration // "?"))"' 2>/dev/null | tail -5
  fi
  if [ -f "${FEATURE_DIR}/.artifacts/error-memory.json" ]; then
    # Fallback: parse from legacy error-memory.json
    awk '
      /"task"/ { in_corr=1; task=""; desc=""; fix="" }
      in_corr && /"type"/ { gsub(/.*"type": *"/, ""); gsub(/".*/, ""); type=$0 }
      in_corr && /"description"/ { gsub(/.*"description": *"/, ""); gsub(/".*/, ""); desc=$0 }
      in_corr && /"fix"/ { gsub(/.*"fix": *"/, ""); gsub(/".*/, ""); fix=$0 }
      in_corr && /}/ {
        if (count <= 5) printf "- %s: %s — %s\n", task, desc, fix
        count++
        in_corr=0
      }
    ' "${FEATURE_DIR}/.artifacts/error-memory.json" 2>/dev/null
  fi
  echo ""

  # ── Previous check results ──────────────────────────────────
  echo "## Previous Check Results"
  if [ -f "$STATE_FILE" ]; then
    jq_q ".tasks[\"$TASK_ID\"].check_results // {} | to_entries[] | \"\(.key): \(.value)\"" 2>/dev/null
  fi
  # Fallback: read from .result files
  if [ -d "${FEATURE_DIR}/.artifacts/check-results" ]; then
    for rf in "${FEATURE_DIR}/.artifacts/check-results"/*.result; do
      [ -f "$rf" ] || continue
      cid=$(basename "$rf" .result)
      result=$(head -1 "$rf" 2>/dev/null || echo "UNKNOWN")
      echo "$cid: $result"
    done
  fi
  echo ""

  # ── Preset config ───────────────────────────────────────────
  echo "## Preset Config"
  if [ -f "$PRESET_YML" ]; then
    awk '/^check_profiles:/{found=1; next} found && /^[a-z]/{exit} found{print}' "$PRESET_YML" 2>/dev/null | head -20
    echo ""
    awk '/^routing_critical:/{found=1; next} found && /^[a-z]/{exit} found{print}' "$PRESET_YML" 2>/dev/null | head -5
  else
    echo "  (not found)"
  fi
  echo ""

  # ── Guides ──────────────────────────────────────────────────
  echo "## Guides"
  echo "### Correction Loop (summary)"
  read_last_n_lines "$GUIDE_CORRECTION" 30
  echo ""
  echo "### Task Selection (summary)"
  read_last_n_lines "$GUIDE_TASK_SEL" 20
  echo ""

  # ── Impact summary ──────────────────────────────────────────
  echo "## Impact Summary"
  maybe_file "$IMPACT_REPORT"
  ;;

verify)
  echo "## CLAUDE.md"
  maybe_file "$CLAUDE_MD"
  echo ""

  echo "## Plan.md Relevant Sections"
  if [ -f "$PLAN_FILE" ]; then
    head -80 "$PLAN_FILE"
    echo "  ... (see full plan.md for complete content)"
  else
    echo "  (not found)"
  fi
  echo ""

  echo "## Tasks (DONE only)"
  if [ -f "$STATE_FILE" ]; then
    jq_q '.tasks | to_entries[] | select(.value.status == "DONE") | "## \(.key): \(.value.title)\nStatus: \(.value.status)\nType: \(.value.type)\nScope:\n  Creates: \(.value.scope.creates | join(", "))\n  Modifies: \(.value.scope.modifies | join(", "))\n"' 2>/dev/null
  elif [ -f "$TASKS_FILE" ]; then
    awk '/^## TASK/{
      gsub(/^## /, ""); tid=$0
    }
    /^Status: DONE$/{ print "## " tid; status=1; next }
    status && /^Status:/{ status=0 }
    status{ print }' "$TASKS_FILE" 2>/dev/null
  fi
  echo ""

  echo "## Spec Companion Files"
  for f in "${FEATURE_DIR}/docs/spec/api-contract.yaml" "${FEATURE_DIR}/docs/spec/backend-interfaces."*; do
    [ -f "$f" ] && echo "### $(basename "$f")" && cat "$f" && echo ""
  done
  ;;

code-review)
  echo "## Task"
  if [ -f "$STATE_FILE" ]; then
    local_title=$(jq_q ".tasks[\"$TASK_ID\"].title // \"(unknown)\"" 2>/dev/null || echo "(unknown)")
    local_ttype=$(jq_q ".tasks[\"$TASK_ID\"].type // \"(unknown)\"" 2>/dev/null || echo "(unknown)")
    local_creates=$(jq_q ".tasks[\"$TASK_ID\"].scope.creates // [] | join(\", \")" 2>/dev/null || echo "")
    local_modifies=$(jq_q ".tasks[\"$TASK_ID\"].scope.modifies // [] | join(\", \")" 2>/dev/null || echo "")
    local_files=$(jq_q ".tasks[\"$TASK_ID\"].files_modified // [] | join(\", \")" 2>/dev/null || echo "")
    echo "Title: ${local_title}"
    echo "Type: ${local_ttype}"
    echo "Scope: Creates: [${local_creates}], Modifies: [${local_modifies}]"
    echo "Files modified: [${local_files}]"
  else
    echo "  (state.json not found)"
  fi
  echo ""

  echo "## Layer Rules"
  if [ -f "$CLAUDE_MD" ]; then
    awk '/^## Layer rules/{found=1; next} found && /^## /{exit} found{print}' "$CLAUDE_MD" 2>/dev/null
  fi
  echo ""

  echo "## Check Results"
  if [ -f "$STATE_FILE" ]; then
    jq_q ".tasks[\"$TASK_ID\"].check_results // {} | to_entries[] | \"\(.key): \(.value)\"" 2>/dev/null
  fi
  echo ""

  echo "## Files Modified"
  if [ -f "$STATE_FILE" ]; then
    jq_q ".tasks[\"$TASK_ID\"].files_modified // [] | .[]" 2>/dev/null
  fi
  ;;

esac
} > "${OUTPUT_FILE}.tmp"

# Enforce hard total cap with critical-section protection.
# Protected sections (must not be truncated):
#   - §16 Constraints (architectural constraints)
#   - Layer Rules (clean architecture enforcement)
#   - Error Memory (learned corrections from past tasks)
# If the bundle exceeds MAX_LINES, truncate lower-priority sections first
# rather than cutting protected sections mid-content.
if [ "$(wc -l < "${OUTPUT_FILE}.tmp" | xargs)" -gt "$MAX_LINES" ]; then
  # Section 16 is always at the end of the implement block (after line ~300).
  # Strategy: keep the last MAX_LINES lines, which preserves section 16
  # and everything after it. Drop the earliest (least critical) content first.
  head -n "$MAX_LINES" "${OUTPUT_FILE}.tmp" > "${OUTPUT_FILE}.tmp2"

  # Verify all protected sections are preserved.
  local needs_fix=false
  if ! grep -q '§16' "${OUTPUT_FILE}.tmp2" 2>/dev/null; then
    needs_fix=true
  fi
  if ! grep -q '## Layer Rules' "${OUTPUT_FILE}.tmp2" 2>/dev/null; then
    needs_fix=true
  fi
  if ! grep -q '## Error Memory' "${OUTPUT_FILE}.tmp2" 2>/dev/null; then
    needs_fix=true
  fi

  if [ "$needs_fix" = true ]; then
    # Rebuild: keep first N lines, then re-append truncated protected sections
    truncate_at=$((MAX_LINES - 3))
    [ "$truncate_at" -lt 1 ] && truncate_at=1
    head -n "$truncate_at" "${OUTPUT_FILE}.tmp" > "${OUTPUT_FILE}.tmp2"
    echo "" >> "${OUTPUT_FILE}.tmp2"

    # Re-append §16 if truncated
    if ! grep -q '§16' "${OUTPUT_FILE}.tmp2" 2>/dev/null; then
      s16_start=$(grep -n '### §16 Constraints' "${OUTPUT_FILE}.tmp" | head -1 | cut -d: -f1 || echo 0)
      if [ "$s16_start" -gt 0 ] 2>/dev/null; then
        sed -n "${s16_start},\$p" "${OUTPUT_FILE}.tmp" >> "${OUTPUT_FILE}.tmp2"
        echo "" >> "${OUTPUT_FILE}.tmp2"
      fi
    fi

    # Re-append Layer Rules if truncated
    if ! grep -q '## Layer Rules' "${OUTPUT_FILE}.tmp2" 2>/dev/null; then
      lr_start=$(grep -n '## Layer Rules' "${OUTPUT_FILE}.tmp" | head -1 | cut -d: -f1 || echo 0)
      lr_end=$(grep -n '## Test Instructions' "${OUTPUT_FILE}.tmp" | head -1 | cut -d: -f1 || echo 0)
      if [ "$lr_start" -gt 0 ] 2>/dev/null && [ "$lr_end" -gt 0 ] 2>/dev/null; then
        sed -n "${lr_start},${lr_end}p" "${OUTPUT_FILE}.tmp" >> "${OUTPUT_FILE}.tmp2"
        echo "" >> "${OUTPUT_FILE}.tmp2"
      fi
    fi

    # Re-append Error Memory if truncated
    if ! grep -q '## Error Memory' "${OUTPUT_FILE}.tmp2" 2>/dev/null; then
      em_start=$(grep -n '## Error Memory' "${OUTPUT_FILE}.tmp" | head -1 | cut -d: -f1 || echo 0)
      em_end=$(grep -n '## Previous Check Results' "${OUTPUT_FILE}.tmp" | head -1 | cut -d: -f1 || echo 0)
      if [ "$em_start" -gt 0 ] 2>/dev/null && [ "$em_end" -gt 0 ] 2>/dev/null; then
        sed -n "${em_start},${em_end}p" "${OUTPUT_FILE}.tmp" >> "${OUTPUT_FILE}.tmp2"
        echo "" >> "${OUTPUT_FILE}.tmp2"
      fi
    fi
  fi

  echo "--- (truncated — see original bundle for full content) ---" >> "${OUTPUT_FILE}.tmp2"
  mv "${OUTPUT_FILE}.tmp2" "${OUTPUT_FILE}.tmp"
fi

mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"

LINE_COUNT=$(wc -l < "$OUTPUT_FILE" | xargs)
echo "BUNDLE: ${PHASE}/${TASK_ID} → ${OUTPUT_FILE} (${LINE_COUNT} lines)"
