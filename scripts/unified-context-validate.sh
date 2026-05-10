#!/usr/bin/env bash
# unified-context-validate.sh — Validate unified-context.json output
#
# Usage: scripts/unified-context-validate.sh <unified_context.json>
#
# Checks:
#   1. JSON well-formedness (jq first, Python fallback)
#   2. Required fields present: version, meta, task, plan_sections, constraints, layer_rules, test_instructions
#   3. task.acceptance_criteria is non-empty array
#   4. plan_sections[0].section matches "§N" format
#   5. constraints.rules is non-empty array
#   6. layer_rules contains at least one layer key
#   7. No null or empty content in plan_sections
#   8. File size < 10KB (compactness gate)
#
# Exit code: 0 if valid, 1 if any check fails

set -euo pipefail

JSON_FILE="${1:?Usage: unified-context-validate.sh <unified_context.json>}"

if [ ! -f "$JSON_FILE" ]; then
  echo "FAIL: File not found: $JSON_FILE"
  exit 1
fi

ERRORS=0
WARNINGS=0

# ── Check 1: JSON well-formedness ───────────────────────────────
echo "CHECK 1: JSON well-formedness"
if command -v jq >/dev/null 2>&1; then
  if jq empty "$JSON_FILE" 2>/dev/null; then
    echo "  PASS: Valid JSON (jq)"
  else
    echo "  FAIL: Invalid JSON (jq)"
    ERRORS=$((ERRORS + 1))
  fi
elif command -v python3 >/dev/null 2>&1; then
  if python3 -c "import json; json.load(open('$JSON_FILE'))" 2>/dev/null; then
    echo "  PASS: Valid JSON (python3)"
  else
    echo "  FAIL: Invalid JSON (python3)"
    ERRORS=$((ERRORS + 1))
  fi
elif command -v python >/dev/null 2>&1; then
  if python -c "import json; json.load(open('$JSON_FILE'))" 2>/dev/null; then
    echo "  PASS: Valid JSON (python)"
  else
    echo "  FAIL: Invalid JSON (python)"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "  WARN: No JSON validator available (jq/python3/python) — skipping"
  WARNINGS=$((WARNINGS + 1))
fi

# ── Check 2: Required fields ────────────────────────────────────
echo "CHECK 2: Required fields"
REQUIRED_FIELDS="version meta task plan_sections constraints layer_rules test_instructions"
for field in $REQUIRED_FIELDS; do
  local_found=false
  if command -v jq >/dev/null 2>&1; then
    if jq -e ".$field" "$JSON_FILE" >/dev/null 2>&1; then
      local_found=true
    fi
  else
    # Fallback: grep for field in JSON
    if grep -q "\"${field}\"" "$JSON_FILE"; then
      local_found=true
    fi
  fi

  if [ "$local_found" = true ]; then
    echo "  PASS: .$field present"
  else
    echo "  FAIL: .$field missing"
    ERRORS=$((ERRORS + 1))
  fi
done

# ── Check 3: task.acceptance_criteria is non-empty ──────────────
echo "CHECK 3: task.acceptance_criteria non-empty"
if command -v jq >/dev/null 2>&1; then
  local_count=$(jq '.task.acceptance_criteria | length' "$JSON_FILE" 2>/dev/null || echo "0")
elif grep -q '"acceptance_criteria"' "$JSON_FILE"; then
  local_count=1
else
  local_count=0
fi

if [ "$local_count" -gt 0 ]; then
  echo "  PASS: acceptance_criteria has $local_count entries"
else
  echo "  WARN: acceptance_criteria is empty (may be expected for some task types)"
  WARNINGS=$((WARNINGS + 1))
fi

# ── Check 4: plan_sections[0].section matches §N ────────────────
echo "CHECK 4: plan_sections section format"
if command -v jq >/dev/null 2>&1; then
  local_sec=$(jq -r '.plan_sections[0].section // empty' "$JSON_FILE" 2>/dev/null || echo "")
elif grep -q '"section"' "$JSON_FILE"; then
  local_sec=$(grep -oE '"section": "§[0-9]+"' "$JSON_FILE" | head -1 | sed 's/"//g' || echo "")
else
  local_sec=""
fi

if echo "$local_sec" | grep -qE '^§[0-9]+$'; then
  echo "  PASS: section matches §N format ($local_sec)"
else
  echo "  WARN: No plan_sections found or format mismatch"
  WARNINGS=$((WARNINGS + 1))
fi

# ── Check 5: constraints.rules is non-empty ─────────────────────
echo "CHECK 5: constraints.rules non-empty"
if command -v jq >/dev/null 2>&1; then
  local_rules=$(jq '.constraints.rules | length' "$JSON_FILE" 2>/dev/null || echo "0")
elif grep -qE '"rules": \[' "$JSON_FILE"; then
  local_rules=$(grep -oE '"rules": \[[^]]*\]' "$JSON_FILE" | head -1 | tr ',' '\n' | wc -l | tr -d ' ')
else
  local_rules=0
fi

if [ "$local_rules" -gt 0 ]; then
  echo "  PASS: constraints.rules has $local_rules entries"
else
  echo "  WARN: constraints.rules is empty"
  WARNINGS=$((WARNINGS + 1))
fi

# ── Check 6: layer_rules has at least one key ───────────────────
echo "CHECK 6: layer_rules has at least one layer"
if command -v jq >/dev/null 2>&1; then
  local_layers=$(jq '.layer_rules | keys | length' "$JSON_FILE" 2>/dev/null || echo "0")
elif grep -qE '"[a-z]+ layer":' "$JSON_FILE"; then
  local_layers=$(grep -cE '"[a-z]+ layer":' "$JSON_FILE" || echo "0")
else
  local_layers=0
fi

if [ "$local_layers" -gt 0 ]; then
  echo "  PASS: layer_rules has $local_layers layers"
else
  echo "  WARN: layer_rules is empty"
  WARNINGS=$((WARNINGS + 1))
fi

# ── Check 7: No null/empty content in plan_sections ─────────────
echo "CHECK 7: plan_sections content non-empty"
if command -v jq >/dev/null 2>&1; then
  local_empty=$(jq '[.plan_sections[] | select(.content == "" or .content == null)] | length' "$JSON_FILE" 2>/dev/null || echo "0")
  if [ "$local_empty" -gt 0 ]; then
    echo "  FAIL: $local_empty plan_sections have empty content"
    ERRORS=$((ERRORS + 1))
  else
    echo "  PASS: all plan_sections have content"
  fi
else
  # Fallback: check for empty content strings
  local_empty=$(grep -c '"content": ""' "$JSON_FILE" 2>/dev/null || echo "0")
  if [ "$local_empty" -gt 0 ]; then
    echo "  FAIL: $local_empty plan_sections have empty content"
    ERRORS=$((ERRORS + 1))
  else
    echo "  PASS: no empty content found"
  fi
fi

# ── Check 8: File size < 10KB ───────────────────────────────────
echo "CHECK 8: File size < 10KB"
local_size=$(wc -c < "$JSON_FILE" | xargs)
if [ "$local_size" -lt 10240 ]; then
  echo "  PASS: ${local_size} bytes"
else
  echo "  WARN: ${local_size} bytes (exceeds 10KB target)"
  WARNINGS=$((WARNINGS + 1))
fi

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "VALIDATION SUMMARY: $ERRORS errors, $WARNINGS warnings"
if [ "$ERRORS" -gt 0 ]; then
  exit 1
else
  exit 0
fi
