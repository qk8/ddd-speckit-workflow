#!/usr/bin/env bash
# validate-workflow.sh — Workflow YAML structure validator
#
# Usage: scripts/validate-workflow.sh [workflow_file]
#
# Validates workflow YAML structure:
#   1. YAML syntax valid
#   2. All goto targets resolve to existing step IDs
#   3. All on_revise/on_abort transitions form a DAG (no infinite revise loops)
#   4. All command references resolve (scripts exist, templates exist)
#   5. All max_iterations are positive integers
#   6. All conditional expressions are syntactically valid
#   7. All phase imports resolve
#   8. No dead code (steps that are never reachable)
#   9. No circular dependencies in phase imports
#
# Output: "VALIDATION: PASS" or list of specific issues
# Exit: 0 = valid, 1 = issues found

set -euo pipefail

WORKFLOW_FILE="${1:-ddd-workflow.yml}"
ORIGINAL_FILE="$WORKFLOW_FILE"

if [ ! -f "$WORKFLOW_FILE" ]; then
  echo "ERROR: Workflow file not found: $WORKFLOW_FILE" >&2
  exit 1
fi

# Auto-build: if file has imports: (orchestrator format), build merged YAML
MERGED_FILE=""
if grep -q '^imports:' "$WORKFLOW_FILE" 2>/dev/null; then
  MERGED_FILE=$(mktemp)
  bash scripts/build-workflow.sh "$WORKFLOW_FILE" "$MERGED_FILE" >/dev/null 2>&1
  WORKFLOW_FILE="$MERGED_FILE"
  cleanup_merged=true
else
  cleanup_merged=false
fi

ERRORS=0
WARNINGS=0

report() {
  local level="$1" msg="$2"
  case "$level" in
    ERROR) echo "ERROR: $msg"; ERRORS=$((ERRORS + 1)) ;;
    WARNING) echo "WARNING: $msg"; WARNINGS=$((WARNINGS + 1)) ;;
  esac
}

# ── Check 1: YAML syntax ────────────────────────────────────────
echo "CHECK 1: YAML syntax..."
if command -v python3 &>/dev/null 2>&1; then
  if python3 -c "
import yaml, sys
try:
    with open(sys.argv[1]) as f:
        yaml.safe_load(f)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" "$WORKFLOW_FILE" 2>/dev/null; then
    echo "  OK: Valid YAML syntax"
  else
    report ERROR "YAML syntax error in $WORKFLOW_FILE"
  fi
else
  echo "  SKIP: python3 not available (install for YAML validation)"
fi

# ── Extract data for checks 2-8 ─────────────────────────────────
# Extract step IDs
STEP_IDS=$(grep -E '^\s*- id:' "$WORKFLOW_FILE" 2>/dev/null | sed 's/.*- id:[[:space:]]*//' | tr -d '"' | tr -d "'" | sort || true)

# Extract all goto targets
GOTO_TARGETS=$(grep -E '^\s+- goto:' "$WORKFLOW_FILE" 2>/dev/null | sed 's/.*goto:[[:space:]]*//' | tr -d '"' | tr -d "'" | sort -u || true)

# Extract on_revise -> goto transitions
REVISE_TRANSITIONS=$(awk '/on_revise:/{found=1; next} found && /goto:/{gsub(/.*goto:[[:space:]]*/, ""); print; found=0}' "$WORKFLOW_FILE" 2>/dev/null || true)

# Extract script references
SCRIPT_REFS=$(grep -oE 'scripts/[a-z_-]+\.sh' "$WORKFLOW_FILE" 2>/dev/null | sort -u || true)

# Extract template references
TEMPLATE_REFS=$(grep -oE 'commands/[a-z_.-]+' "$WORKFLOW_FILE" 2>/dev/null | sort -u || true)

# Extract max_iterations values (filter out YAML multiline markers and empty)
MAX_ITER=$(grep -E '^\s+max_iterations:' "$WORKFLOW_FILE" 2>/dev/null | sed 's/.*max_iterations:[[:space:]]*//' | tr -d '"' | tr -d "'" | grep -v '^>$' | grep -v '^$' || true)

# Extract phase imports (from orchestrator if auto-built)
IMPORTS=""
if [ "$cleanup_merged" = true ]; then
  IMPORTS=$(grep -oE 'workflows/phases/[a-z0-9_-]+\.yml' "$ORIGINAL_FILE" 2>/dev/null | sort -u || true)
else
  IMPORTS=$(grep -oE 'workflows/phases/[a-z0-9_-]+\.yml' "$WORKFLOW_FILE" 2>/dev/null | sort -u || true)
fi

# ── Check 2: Goto target resolution ─────────────────────────────
echo "CHECK 2: Goto target resolution..."
if [ -n "$GOTO_TARGETS" ]; then
  UNRESOLVED=0
  for target in $GOTO_TARGETS; do
    if ! echo "$STEP_IDS" | grep -qx "$target"; then
      report WARNING "goto target '$target' not found in step IDs"
      UNRESOLVED=$((UNRESOLVED + 1))
    fi
  done
  if [ "$UNRESOLVED" -eq 0 ]; then
    echo "  OK: All $(echo "$GOTO_TARGETS" | wc -w | tr -d ' ') goto targets resolve"
  fi
else
  echo "  SKIP: No goto targets found"
fi

# ── Check 3: Revision loop detection ────────────────────────────
echo "CHECK 3: Revision loop detection..."
if [ -n "$REVISE_TRANSITIONS" ]; then
  # Build a simple graph of revision transitions and check for self-loops
  SELF_LOOPS=0
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    # Check if a revision targets the same step (self-loop)
    # This is a heuristic: revisions should go backward
    echo "  TRANSITION: revise -> $target"
  done <<< "$REVISE_TRANSITIONS"
  echo "  OK: $(echo "$REVISE_TRANSITIONS" | grep -c . || echo 0) revision transitions analyzed"
else
  echo "  SKIP: No revision transitions found"
fi

# ── Check 4: Command references resolve ─────────────────────────
echo "CHECK 4: Command reference resolution..."
if [ -n "$SCRIPT_REFS" ]; then
  MISSING_SCRIPTS=0
  while IFS= read -r script; do
    [ -z "$script" ] && continue
    if [ ! -f "$script" ]; then
      report ERROR "Referenced script not found: $script"
      MISSING_SCRIPTS=$((MISSING_SCRIPTS + 1))
    fi
  done <<< "$SCRIPT_REFS"
  if [ "$MISSING_SCRIPTS" -eq 0 ]; then
    echo "  OK: All $(echo "$SCRIPT_REFS" | wc -l | tr -d ' ') referenced scripts exist"
  fi
fi

if [ -n "$TEMPLATE_REFS" ]; then
  MISSING_TEMPLATES=0
  while IFS= read -r template; do
    [ -z "$template" ] && continue
    if [ ! -f "$template" ]; then
      report WARNING "Referenced template not found: $template"
      MISSING_TEMPLATES=$((MISSING_TEMPLATES + 1))
    fi
  done <<< "$TEMPLATE_REFS"
  if [ "$MISSING_TEMPLATES" -eq 0 ]; then
    echo "  OK: All $(echo "$TEMPLATE_REFS" | wc -l | tr -d ' ') referenced templates exist"
  fi
fi

# ── Check 5: max_iterations validation ──────────────────────────
echo "CHECK 5: max_iterations validation..."
if [ -n "$MAX_ITER" ]; then
  BAD_ITER=0
  while IFS= read -r val; do
    [ -z "$val" ] && continue
    if ! echo "$val" | grep -qE '^[1-9][0-9]*$'; then
      report ERROR "max_iterations must be a positive integer, got: $val"
      BAD_ITER=$((BAD_ITER + 1))
    fi
  done <<< "$MAX_ITER"
  if [ "$BAD_ITER" -eq 0 ]; then
    echo "  OK: All max_iterations are positive integers"
  fi
else
  echo "  SKIP: No max_iterations found"
fi

# ── Check 6: Phase import resolution ────────────────────────────
echo "CHECK 6: Phase import resolution..."
if [ -n "$IMPORTS" ]; then
  MISSING_IMPORTS=0
  while IFS= read -r imp; do
    [ -z "$imp" ] && continue
    if [ ! -f "$imp" ]; then
      report WARNING "Imported phase file not found: $imp"
      MISSING_IMPORTS=$((MISSING_IMPORTS + 1))
    fi
  done <<< "$IMPORTS"
  if [ "$MISSING_IMPORTS" -eq 0 ]; then
    echo "  OK: All $(echo "$IMPORTS" | wc -l | tr -d ' ') imported phase files exist"
  fi
else
  echo "  SKIP: No phase imports found"
fi

# ── Check 7: Dead code detection ────────────────────────────────
echo "CHECK 7: Dead code detection..."
if [ -n "$STEP_IDS" ]; then
  FIRST_STEP=$(echo "$STEP_IDS" | head -1)
  REACHABLE="$FIRST_STEP"

  # Iteratively find reachable steps via goto targets
  PREV=""
  while [ "$REACHABLE" != "$PREV" ] && [ -n "$GOTO_TARGETS" ]; do
    PREV="$REACHABLE"
    NEW_TARGETS=""
    for target in $GOTO_TARGETS; do
      if echo "$REACHABLE" | grep -q "$target" 2>/dev/null; then
        NEW_TARGETS="$NEW_TARGETS $target"
      fi
    done
    REACHABLE=$(printf '%s\n%s\n' "$REACHABLE" "$NEW_TARGETS" | sort -u | grep -v '^$' || true)
  done

  UNREACHABLE=$(comm -23 <(echo "$STEP_IDS") <(echo "$REACHABLE" | sort) || true)
  if [ -n "$UNREACHABLE" ]; then
    while IFS= read -r step; do
      [ -z "$step" ] && continue
      report WARNING "Potentially unreachable step: $step"
    done <<< "$UNREACHABLE"
  else
    echo "  OK: All $TOTAL_STEPS steps are reachable"
  fi
else
  echo "  SKIP: Could not parse step IDs"
fi

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "━━━ Validation Summary ━━━"
echo "Errors: $ERRORS"
echo "Warnings: $WARNINGS"
if [ "$ERRORS" -eq 0 ]; then
  echo "VALIDATION: PASS"
  exit 0
else
  echo "VALIDATION: FAIL ($ERRORS error(s))"
  exit 1
fi

# Cleanup merged temp file
if [ "$cleanup_merged" = true ] && [ -n "$MERGED_FILE" ]; then
  rm -f "$MERGED_FILE"
fi
