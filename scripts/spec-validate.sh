#!/usr/bin/env bash
# spec-validate.sh — Deterministic structural validation of spec.md
#
# Usage: bash scripts/spec-validate.sh <feature_dir>
#
# Checks spec.md for:
#   1. Contradictions: same concept with conflicting requirements
#   2. Ambiguous terms: should, may, ideally, approximately, roughly
#   3. Missing sections: Acceptance Criteria, Constraints, Edge Cases
#   4. Acceptance criteria without expected outcomes
#   5. Cross-references to undefined concepts
#
# Output: SPEC_VALID=PASS|NEEDS_REVIEW with specific issues listed
# Always exits 0 (advisory, enforced by phase gate)

set -euo pipefail

FEATURE_DIR="${1:?Usage: spec-validate.sh <feature_dir>}"
SPEC_FILE="$FEATURE_DIR/spec.md"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

RESULT_FILE="$ARTIFACTS_DIR/spec-validation-result.txt"

if [ ! -f "$SPEC_FILE" ]; then
  echo "SPEC_VALID=NEEDS_REVIEW — spec.md not found"
  echo "SPEC_VALID=NEEDS_REVIEW" > "$RESULT_FILE"
  echo "ISSUES: spec.md does not exist" >> "$RESULT_FILE"
  exit 0
fi

ISSUES=""
ISSUE_COUNT=0

# ── Helper: append issue ────────────────────────────────────────
add_issue() {
  local severity="$1" category="$2" message="$3"
  ISSUES="${ISSUES}${ISSUES:+
}[$severity] $category: $message"
  ISSUE_COUNT=$(( ISSUE_COUNT + 1 ))
}

# ── 1. Check for ambiguous terms ────────────────────────────────
# These terms indicate uncertainty that should be resolved before implementation.
AMBIGUOUS_TERMS="should|may|ideally|approximately|roughly|preferably|tbd|TODO|FIXME"
LINE_NUM=0
while IFS= read -r line; do
  LINE_NUM=$(( LINE_NUM + 1 ))
  if echo "$line" | grep -iqE "(^|[^a-zA-Z])($AMBIGUOUS_TERMS)([^a-zA-Z]|$)" 2>/dev/null; then
    # Skip lines that are already definitive (e.g., "must not", "required")
    if echo "$line" | grep -qiE "(must not|required to|cannot|impossible)" 2>/dev/null; then
      continue
    fi
    # Extract the ambiguous term
    term=$(echo "$line" | grep -oiE "(^|[^a-zA-Z])(should|may|ideally|approximately|roughly|preferably|tbd|TODO|FIXME)([^a-zA-Z]|$)" 2>/dev/null | head -1 | tr -d ' ' || true)
    [ -n "$term" ] && add_issue "WARNING" "AMBIGUOUS_TERM" "Line $LINE_NUM: '$term' — replace with definitive requirement"
  fi
done < "$SPEC_FILE"

# ── 2. Check for missing required sections ──────────────────────
REQUIRED_SECTIONS="Acceptance Criteria|Acceptance Criteria|Acceptance|constraints|Constraints|edge cases|Edge Cases|non-functional|Non-Functional"
for section in "Acceptance Criteria" "Acceptance" "Constraints" "Edge Cases" "non-functional" "Non-Functional"; do
  if ! grep -qi "$section" "$SPEC_FILE" 2>/dev/null; then
    add_issue "ERROR" "MISSING_SECTION" "Required section '$section' not found"
  fi
done

# ── 3. Check for acceptance criteria without expected outcomes ──
# Criteria that describe behavior but don't specify expected result.
# Pattern: "handles [error/situation]" without "returns/expects/should return"
if grep -qiE "^\s*[-*]\s+handles?\s+(error|exception|failure|invalid|missing|empty)" "$SPEC_FILE" 2>/dev/null; then
  while IFS= read -r line; do
    # Check if this line also has an expected outcome
    if ! echo "$line" | grep -qiE "(return|expect|response|status|output|result|throw|raise|reject|denied|40[0-9]|500|error\s+(message|response))" 2>/dev/null; then
      # Get line number
      lnum=$(grep -niE -- "^\s*[-*]\s+handles?\s+(error|exception|failure|invalid|missing|empty)" "$SPEC_FILE" 2>/dev/null | grep -F -- "$line" | head -1 | cut -d: -f1 || true)
      [ -n "$lnum" ] && add_issue "WARNING" "INCOMPLETE_CRITERION" "Line $lnum: '$(echo "$line" | sed 's/^[[:space:]]*//')' — missing expected outcome"
    fi
  done < <(grep -iE "^\s*[-*]\s+handles?\s+(error|exception|failure|invalid|missing|empty)" "$SPEC_FILE" 2>/dev/null || true)
fi

# ── 4. Check for contradictions: conflicting numeric requirements ──
# Extract all numeric constraints and check for conflicts.
# Pattern: "must be < N" vs "can be up to M" where M > N
NUMERIC_LINES=$(grep -iE '(max|maximum|limit|at most|up to|not exceed|less than|below|under)\s+[0-9]+' "$SPEC_FILE" 2>/dev/null || true)
if [ -n "$NUMERIC_LINES" ]; then
  # Collect all numeric values and their constraint type
  TYPE_COUNT=0
  while IFS= read -r nline; do
    # Determine constraint type
    ctype="unknown"
    echo "$nline" | grep -qiE '(max|maximum|limit|at most|up to|not exceed)' && ctype="upper"
    echo "$nline" | grep -qiE '(less than|below|under)' && ctype="lower"
    # Extract number
    num=$(echo "$nline" | grep -oE '[0-9]+' | tail -1)
    [ -n "$num" ] && case "$num" in ''|*[!0-9]*) num=0 ;; esac
    if [ "$ctype" = "upper" ]; then
      UPPER_VALS="${UPPER_VALS:+$UPPER_VALS }$num"
    elif [ "$ctype" = "lower" ]; then
      LOWER_VALS="${LOWER_VALS:+$LOWER_VALS }$num"
    fi
    TYPE_COUNT=$(( TYPE_COUNT + 1 ))
  done <<< "$NUMERIC_LINES"

  # Compare upper vs lower bounds for contradictions
  if [ -n "${UPPER_VALS:-}" ] && [ -n "${LOWER_VALS:-}" ]; then
    for ub in $UPPER_VALS; do
      for lb in $LOWER_VALS; do
        if [ "$lb" -le "$ub" ] 2>/dev/null; then
          add_issue "WARNING" "POTENTIAL_CONTRADICTION" "Upper bound $ub may conflict with lower bound $lb"
        fi
      done
    done
  fi
fi

# ── 5. Check for cross-references to undefined sections ─────────
if grep -qE '(see|refer|also|cf)\s+(section|Section|§|clause)' "$SPEC_FILE" 2>/dev/null; then
  while IFS= read -r ref_line; do
    # Extract referenced section name
    ref=$(echo "$ref_line" | grep -oiE '(section|Section|§)\s+[a-zA-Z0-9 ]+' 2>/dev/null | head -1 || true)
    if [ -n "$ref" ]; then
      # Normalize: remove "section" prefix, trim
      ref_name=$(echo "$ref" | sed -E 's/^(section|Section|§)\s+//i' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
      # Check if this section exists as a heading
      if ! grep -qE -- "^#{1,3}.*${ref_name}" "$SPEC_FILE" 2>/dev/null; then
        lnum=$(echo "$ref_line" | head -1 | cut -d: -f1)
        add_issue "WARNING" "BROKEN_REFERENCE" "Line $lnum: '$ref' — referenced section may not exist"
      fi
    fi
  done < <(grep -iE '(see|refer|also|cf)\s+(section|Section|§|clause)' "$SPEC_FILE" 2>/dev/null || true)
fi

# ── 6. Check for overly long paragraphs (readability) ───────────
# Paragraphs > 10 lines may indicate sections that need decomposition.
PARA_LENGTH=0
MAX_PARA_LENGTH=10
while IFS= read -r line; do
  if [ -z "$line" ]; then
    if [ "$PARA_LENGTH" -gt "$MAX_PARA_LENGTH" ]; then
      add_issue "WARNING" "LONG_PARAGRAPH" "Paragraph of $PARA_LENGTH lines exceeds $MAX_PARA_LENGTH-line limit — consider breaking into subsections"
    fi
    PARA_LENGTH=0
  else
    PARA_LENGTH=$(( PARA_LENGTH + 1 ))
  fi
done < "$SPEC_FILE"
# Handle last paragraph (no trailing newline)
if [ "$PARA_LENGTH" -gt "$MAX_PARA_LENGTH" ]; then
  add_issue "WARNING" "LONG_PARAGRAPH" "Final paragraph of $PARA_LENGTH lines exceeds $MAX_PARA_LENGTH-line limit"
fi

# ── Output result ───────────────────────────────────────────────
if [ "$ISSUE_COUNT" -eq 0 ]; then
  RESULT="PASS"
  echo "SPEC_VALID=PASS"
  echo "No issues found."
else
  RESULT="NEEDS_REVIEW"
  echo "SPEC_VALID=NEEDS_REVIEW"
  echo "Found $ISSUE_COUNT issue(s):"
  echo "$ISSUES"
fi

cat > "$RESULT_FILE" <<EOF
SPEC_VALID=$RESULT
ISSUE_COUNT=$ISSUE_COUNT
$(echo "$ISSUES" | sed 's/^/ISSUES=/')
EOF

exit 0
