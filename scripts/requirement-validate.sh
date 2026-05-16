#!/usr/bin/env bash
# requirement-validate.sh — Validate final output against project-brief.md requirements.
#
# Parses project-brief.md sections §3 (What does this system do?) and §5 (Hard constraints).
# For each requirement, checks if corresponding implementation exists in the codebase.
# Produces requirement-validation.md report with PASS/FAIL per requirement.
#
# Usage: scripts/requirement-validate.sh <feature_dir>
#
# Output: .artifacts/requirement-validation.md with per-requirement PASS/FAIL

set -euo pipefail

FEATURE_DIR="${1:?Usage: requirement-validate.sh <feature_dir>}"
BRIEF_FILE="$FEATURE_DIR/project-brief.md"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
REPORT_FILE="$ARTIFACTS_DIR/requirement-validation.md"
mkdir -p "$ARTIFACTS_DIR"

if [ ! -f "$BRIEF_FILE" ]; then
  echo "ERROR: project-brief.md not found at $BRIEF_FILE" >&2
  exit 1
fi

# ── Parse requirements from project-brief.md ─────────────────────
# Section 3: "What does this system do?" — numbered list items
# Section 5: "Hard constraints" — numbered list items
#
# We extract numbered items from these sections.

declare -a req_ids=()
declare -a req_texts=()
declare -a req_sections=()
declare -a req_results=()
declare -a req_evidence=()

current_section=""
in_section=false

while IFS= read -r line; do
  # Detect section headers
  if echo "$line" | grep -qE '^##?\s+3[.)]\s+(What does|System|does this)'; then
    current_section="system-function"
    in_section=true
    continue
  fi
  if echo "$line" | grep -qE '^##?\s+5[.)]\s+(Hard|hard|Constraint|constraint)'; then
    current_section="hard-constraint"
    in_section=true
    continue
  fi
  # New section header ends the current one
  if echo "$line" | grep -qE '^#{1,3}\s+' && [ "$in_section" = true ]; then
    # Check if it's a numbered section header (3.x or 5.x)
    if ! echo "$line" | grep -qE '^#{1,3}\s+[35][.)]'; then
      in_section=false
      current_section=""
    fi
  fi

  if [ "$in_section" = true ]; then
    # Match numbered items: "1. ...", "1) ...", "- 1. ...", "- 1) ..."
    if echo "$line" | grep -qE '^\s*[-]?\s*[0-9]+[.)]\s+'; then
      req_num=$(echo "$line" | grep -oE '[0-9]+' | head -1)
      req_text=$(echo "$line" | sed 's/^\s*[-]?\s*[0-9]\+[.)]\s*//')
      req_ids+=("$req_num")
      req_texts+=("$req_text")
      req_sections+=("$current_section")
    fi
  fi
done < "$BRIEF_FILE"

TOTAL=${#req_ids[@]}
PASSED=0
FAILED=0

# ── Check each requirement against codebase ──────────────────────
for i in "${!req_ids[@]}"; do
  rid="${req_ids[$i]}"
  rtext="${req_texts[$i]}"
  rsection="${req_sections[$i]}"

  # Extract key terms from the requirement (first 3-5 words, lowercase)
  key_terms=$(echo "$rtext" | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z]{3,}' | head -5 | tr '\n' '|' | sed 's/|$//')

  evidence=""
  result="FAIL"

  if [ -n "$key_terms" ]; then
    # Search for key terms in code files (non-test, non-doc)
    matches=$(find "$FEATURE_DIR" -type f \( -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.tsx' -o -name '*.jsx' -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.rb' -o -name '*.php' -o -name '*.cs' -o -name '*.kt' \) ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/__tests__/*' ! -path '*/test/*' ! -path '*/tests/*' ! -path '*/.artifacts/*' -exec grep -liE "$key_terms" {} + 2>/dev/null || true)

    match_count=$(echo "$matches" | grep -cE '.' 2>/dev/null || echo 0)

    if [ "$match_count" -gt 0 ]; then
      result="PASS"
      # Collect up to 3 evidence files
      evidence=$(echo "$matches" | head -3 | tr '\n' '; ' | sed 's/;$//')
      PASSED=$((PASSED + 1))
    else
      FAILED=$((FAILED + 1))
      evidence="(no matching files found)"
    fi
  else
    FAILED=$((FAILED + 1))
    evidence="(could not extract searchable terms)"
  fi

  req_results+=("$result")
  req_evidence+=("$evidence")
done

# ── Write report ─────────────────────────────────────────────────
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

cat > "$REPORT_FILE" <<EOF
# Requirement Validation Report
Generated: $TIMESTAMP

## Summary
- Total requirements: $TOTAL
- Passed: $PASSED
- Failed: $FAILED
- Overall: $([ "$FAILED" -eq 0 ] && echo "PASS" || echo "FAIL")

## Details

EOF

for i in "${!req_ids[@]}"; do
  echo "### Requirement ${req_ids[$i]} [$(${echo "${req_results[$i]}" | tr '[:lower:]' '[:upper:]'} )]" >> "$REPORT_FILE"
  echo "- **Section**: ${req_sections[$i]}" >> "$REPORT_FILE"
  echo "- **Requirement**: ${req_texts[$i]}" >> "$REPORT_FILE"
  echo "- **Evidence**: ${req_evidence[$i]}" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
done

echo "Overall: $([ "$FAILED" -eq 0 ] && echo "PASS" || echo "FAIL — $FAILED requirements have no corresponding implementation evidence")"

# Output to stdout
echo "=== REQUIREMENT VALIDATION ==="
echo "  Total: $TOTAL | Passed: $PASSED | Failed: $FAILED"
echo "  Overall: $([ "$FAILED" -eq 0 ] && echo "PASS" || echo "FAIL")"
echo "  Report: $REPORT_FILE"

# Exit 0 if all passed, 1 if any failed
if [ "$FAILED" -eq 0 ]; then
  exit 0
else
  exit 1
fi
