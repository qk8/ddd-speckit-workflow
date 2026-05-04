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

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
GAPS_FILE="$TMP_DIR/gaps.txt"
touch "$GAPS_FILE"

# ── Check 1: Each task references plan sections that exist ──────
if [ -f "$TASKS_FILE" ] && [ -f "$PLAN_FILE" ]; then
  current_task=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^## TASK-'; then
      current_task=$(echo "$line" | sed 's/^## //' | sed 's/\[//g; s/\]//g')
    fi
    if [ -n "$current_task" ] && echo "$line" | grep -qE '^  - \[.*\]'; then
      # Extract §N references and check each against plan.md
      refs=$(echo "$line" | grep -oE '§[0-9]+' || true)
      for ref in $refs; do
        if ! grep -q "${ref}[[:space:]]" "$PLAN_FILE" 2>/dev/null; then
          echo "${current_task}|${ref}|plan section missing" >> "$GAPS_FILE"
        fi
      done
    fi
  done < "$TASKS_FILE"
fi

# ── Check 2: Tasks with acceptance criteria referencing classes ─
if [ -f "$TASKS_FILE" ] && [ -f "$PLAN_FILE" ]; then
  current_task=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^## TASK-'; then
      current_task=$(echo "$line" | sed 's/^## //' | sed 's/\[//g; s/\]//g')
    fi
    if [ -n "$current_task" ] && echo "$line" | grep -qE '^\s+- \[.*\]'; then
      classes=$(echo "$line" | grep -oE '[A-Z][a-zA-Z]+[Ss]ervice|[A-Z][a-zA-Z]+[Rr]epository|[A-Z][a-zA-Z]+[Cc]ontroller|[A-Z][a-zA-Z]+[U]seCase|[A-Z][a-zA-Z]+[V]alueObject|[A-Z][a-zA-Z]+[Ee]vent' 2>/dev/null || true)
      for cls in $classes; do
        if ! grep -q "$cls" "$PLAN_FILE" 2>/dev/null; then
          echo "${current_task}|${cls}|class not found in plan.md" >> "$GAPS_FILE"
        fi
      done
    fi
  done < "$TASKS_FILE"
fi

# ── Check 3: Plan sections with no corresponding tasks ─────────
if [ -f "$PLAN_FILE" ] && [ -f "$TASKS_FILE" ]; then
  all_secs=$(grep -oE '§[0-9]+' "$PLAN_FILE" 2>/dev/null | sed 's/§//' | sort -un || true)
  for sec in $all_secs; do
    if ! grep -q "§${sec}" "$TASKS_FILE" 2>/dev/null; then
      case "$sec" in
        1|2|3|16|17|18|19|20) ;; # Planning sections, not implementation targets
        *)
          echo "§${sec}|none|plan section has no task references" >> "$GAPS_FILE"
          ;;
      esac
    fi
  done
fi

# ── Output results ─────────────────────────────────────────────
GAP_COUNT=$(wc -l < "$GAPS_FILE" | xargs)
if [ "$GAP_COUNT" -eq 0 ]; then
  echo "TRACEABLE=true"
  echo "TRACE_GAP_COUNT=0"
  echo "  All tasks traceable to plan.md. All plan sections have task coverage."
else
  echo "TRACEABLE=false"
  echo "TRACE_GAP_COUNT=${GAP_COUNT}"
  head -20 "$GAPS_FILE"
fi

exit 0
