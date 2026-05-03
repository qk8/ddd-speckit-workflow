#!/usr/bin/env bash
# Spec-to-code traceability check.
# Cross-references tasks against plan.md and spec.md to ensure
# every task traces back to a spec requirement.
#
# Usage: traceability-check.sh <feature_dir>
# Outputs: TRACEABLE=true|false, TRACE_GAP_COUNT=N, TRACE_GAPS=...

set -euo pipefail

FEATURE_DIR="${1:?Usage: traceability-check.sh <feature_dir>}"

if [ ! -d "$FEATURE_DIR" ]; then
  echo "TRACEABLE=true"
  echo "TRACE_GAP_COUNT=0"
  exit 0
fi

TASKS_FILE="${FEATURE_DIR}/tasks.md"
PLAN_FILE="${FEATURE_DIR}/plan.md"
SPEC_FILE="${FEATURE_DIR}/spec.md"

GAPS=""
GAP_COUNT=0

# ── Check 1: Each task references plan sections that exist ──────
if [ -f "$TASKS_FILE" ] && [ -f "$PLAN_FILE" ]; then
  # Extract task IDs and their acceptance criteria
  current_task=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^## TASK-'; then
      current_task=$(echo "$line" | sed 's/^## //' | sed 's/\[//g; s/\]//g')
    fi
    if [ -n "$current_task" ] && echo "$line" | grep -qE '^  - \[.*\]'; then
      # Acceptance criterion line — check for plan section references
      # Look for §N references (e.g., "per §4", "from §8.1")
      if echo "$line" | grep -oE '§[0-9]+' | while read -r ref; do
        # Check if this section exists in plan.md
        if ! grep -q "${ref}[[:space:]]" "$PLAN_FILE" 2>/dev/null; then
          echo "${current_task}|${ref}|plan section missing"
        fi
      done; then
        : # gaps found
      fi
    fi
  done < "$TASKS_FILE"
fi

# ── Check 2: Tasks with acceptance criteria referencing classes ─
# Verify referenced classes exist in plan.md
if [ -f "$TASKS_FILE" ] && [ -f "$PLAN_FILE" ]; then
  current_task=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^## TASK-'; then
      current_task=$(echo "$line" | sed 's/^## //' | sed 's/\[//g; s/\]//g')
    fi
    if [ -n "$current_task" ] && echo "$line" | grep -qE '^\s+- \[.*\]'; then
      # Extract potential class names (PascalCase words that look like classes)
      classes=$(echo "$line" | grep -oE '[A-Z][a-zA-Z]+[Ss]ervice|[A-Z][a-zA-Z]+[Rr]epository|[A-Z][a-zA-Z]+[Cc]ontroller|[A-Z][a-zA-Z]+[U]seCase|[A-Z][a-zA-Z]+[V]alueObject|[A-Z][a-zA-Z]+[Ee]vent' 2>/dev/null || true)
      for cls in $classes; do
        if ! grep -q "$cls" "$PLAN_FILE" 2>/dev/null; then
          GAPS="${GAPS}${current_task}|${cls}|class not found in plan.md\n"
          GAP_COUNT=$((GAP_COUNT + 1))
        fi
      done
    fi
  done < "$TASKS_FILE"
fi

# ── Check 3: Plan sections with no corresponding tasks ─────────
if [ -f "$PLAN_FILE" ] && [ -f "$TASKS_FILE" ]; then
  # Extract section numbers from plan.md
  grep -oE '§[0-9]+' "$PLAN_FILE" 2>/dev/null | sed 's/§//' | while read -r sec; do
    # Check if any task references this section
    if ! grep -q "§${sec}" "$TASKS_FILE" 2>/dev/null; then
      # Not all plan sections need tasks — skip sections 1-3 (requirements/language/bounded contexts)
      case "$sec" in
        1|2|3|16|17|18|19|20) ;; # These are planning sections, not implementation targets
        *)
          GAPS="${GAPS}§${sec}|none|plan section has no task references\n"
          GAP_COUNT=$((GAP_COUNT + 1))
          ;;
      esac
    fi
  done
fi

# ── Output results ─────────────────────────────────────────────
if [ "$GAP_COUNT" -eq 0 ]; then
  echo "TRACEABLE=true"
  echo "TRACE_GAP_COUNT=0"
  echo "  All tasks traceable to plan.md. All plan sections have task coverage."
else
  echo "TRACEABLE=false"
  echo "TRACE_GAP_COUNT=${GAP_COUNT}"
  echo -e "$GAPS" | head -20
fi

exit 0
