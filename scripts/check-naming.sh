#!/usr/bin/env bash
# Usage: ./scripts/check-naming.sh
# Validates that ubiquitous language terms from plan.md §2 are used consistently
# in the codebase. Can be used as a pre-commit hook.
#
# Checks:
#   1. Terms defined in §2 exist in code (case-insensitive)
#   2. No code uses terms that differ from §2 definitions
#   3. (Optional) --fix: suggests renames for mismatched terms
#
# Exit codes:
#   0 — All checks passed
#   1 — Errors found (naming violations)
#   2 — Plan.md not found or no terms defined
#
# Bash 3.2-compatible: no associative arrays (declare -A).
# Uses temp files with one term per line.

set -euo pipefail

# ── Locate plan.md ──────────────────────────────────────────────
PLAN_FILE=$(bash scripts/find-file.sh plan.md)

if [ -z "$PLAN_FILE" ]; then
  echo "No plan.md found. Skipping naming validation."
  exit 2
fi

FIX_MODE=false
for arg in "$@"; do
  if [ "$arg" = "--fix" ]; then
    FIX_MODE=true
  fi
done

# ── Temp files for bash 3.2 compatibility ───────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
TERMS_FILE="$TMP_DIR/terms.txt"
touch "$TERMS_FILE"

# ── Parse §2 Ubiquitous Language ────────────────────────────────
# Format in plan.md:
#   ### [Term Name]
#   **Domain:** [domain] | **Bounded Context:** [context]
#   Definition: [description]
#
# We extract term names from ### headers under §2 section.

CURRENT_SECTION=""
IN_SECTION2=false

while IFS= read -r line; do
  # Detect §2 header
  if echo "$line" | grep -q '§2.*Ubiquitous'; then
    IN_SECTION2=true
    continue
  fi
  # If we hit §3 or another section, stop (handles up to §30)
  if echo "$line" | grep -qE '^#+.*§([3-9]|1[0-9]|2[0-9]|30)'; then
    IN_SECTION2=false
    continue
  fi

  if $IN_SECTION2 && echo "$line" | grep -qE '^###\ (.+)'; then
    term=$(echo "$line" | sed 's/^### *//' | sed 's/ *|.*//' | xargs)
    if [ -n "$term" ]; then
      echo "$term" >> "$TERMS_FILE"
    fi
  fi
done < "$PLAN_FILE"

term_count=$(wc -l < "$TERMS_FILE" | xargs)

if [ "$term_count" -eq 0 ]; then
  echo "No ubiquitous language terms found in plan.md §2. Nothing to validate."
  exit 2
fi

echo "━━━ Ubiquitous Language Validation ━━━"
echo "Found $term_count term(s) in plan.md §2."
echo ""

ERRORS=0
WARNINGS=0
RENAMES_FILE="$TMP_DIR/renames.txt"
touch "$RENAMES_FILE"

# ── Search codebase ─────────────────────────────────────────────
# Search in src/ and app/ directories; fall back to any top-level dirs
source scripts/search-dirs.sh
source scripts/filetypes.sh
if [ ${#SEARCH_DIRS[@]} -eq 0 ]; then
  echo "No src/ or app/ directory found. Skipping codebase search."
  exit 0
fi

# ── Helper: check if term exists in TERMS_FILE ──────────────────
term_exists() {
  grep -qxF "$1" "$TERMS_FILE"
}

# ── Helper: check if term contains any TERMS entry ──────────────
term_contains_term() {
  local candidate="$1"
  while IFS= read -r t; do
    case "$candidate" in
      *"$t"*) return 0 ;;
    esac
  done < "$TERMS_FILE"
  return 1
}

# ── Helper: check if any TERM contains candidate ────────────────
candidate_contains_term() {
  local candidate="$1"
  while IFS= read -r t; do
    case "$t" in
      *"$candidate"*) return 0 ;;
    esac
  done < "$TERMS_FILE"
  return 1
}

while IFS= read -r term; do
  # Escape regex special characters in term before using in grep
  escaped_term=$(printf '%s\n' "$term" | sed 's/[[\.*^$()+?{|]/\\&/g')
  # Case-insensitive search for the term in codebase
  matches=$(grep -rl "${FILETYPES_PATTERNS[@]}" "$escaped_term" "${SEARCH_DIRS[@]}" 2>/dev/null || true)

  if [ -z "$matches" ]; then
    echo "  WARNING: §2 \"$term\" — not found in codebase (may be planned but not yet implemented)."
    WARNINGS=$((WARNINGS + 1))
    continue
  fi

  # Check for potential mismatches — look for similar but different names
  # This catches cases where term is "PaymentReceipt" but code uses "PaymentSlip"
  # We search for partial matches that could indicate wrong naming
  found_correct=false
  for match_file in $matches; do
    if grep -q "$term" "$match_file" 2>/dev/null; then
      found_correct=true
      break
    fi
  done

  if ! $found_correct; then
    echo "  ERROR: §2 \"$term\" — term not found in any file despite grep match (possible partial match only)."
    echo "         Affected files:"
    for match_file in $matches; do
      echo "           - $match_file"
    done
    ERRORS=$((ERRORS + 1))

    if $FIX_MODE; then
      echo "$term" >> "$RENAMES_FILE"
    fi
  fi
done < "$TERMS_FILE"

# ── Cross-check: find code terms not in plan ────────────────────
# Search for common DDD patterns (Aggregate, Repository, UseCase, etc.)
# and check if they match plan.md terms
PATTERN_FILES=$(grep -rl "${FILETYPES_PATTERNS[@]}" \
  -E "(Aggregate|Repository|UseCase|DomainEvent|ValueObject)" "${SEARCH_DIRS[@]}" 2>/dev/null || true)

if [ -n "$PATTERN_FILES" ]; then
  for file in $PATTERN_FILES; do
    # Extract class/type names matching DDD patterns
    code_names=$(grep -oE "[A-Z][a-zA-Z]+(Aggregate|Repository|UseCase|DomainEvent|ValueObject)" "$file" 2>/dev/null || true)
    for name in $code_names; do
      # Check if this name exists in TERMS
      found=false
      while IFS= read -r term; do
        if [ "$name" = "$term" ]; then
          found=true
          break
        fi
      done < "$TERMS_FILE"
      if ! $found; then
        # Check if a similar term exists in plan
        while IFS= read -r term; do
          # Check if the code name contains the plan term or vice versa
          case "$name" in
            *"$term"*)
              echo "  NOTE: Code uses \"$name\" but plan.md §2 defines \"$term\" — consider aligning."
              WARNINGS=$((WARNINGS + 1))
              break
              ;;
            *)
              case "$term" in
                *"$name"*)
                  echo "  NOTE: Code uses \"$name\" but plan.md §2 defines \"$term\" — consider aligning."
                  WARNINGS=$((WARNINGS + 1))
                  break
                  ;;
              esac
              ;;
          esac
        done < "$TERMS_FILE"
      fi
    done
  done
fi

# ── Summary ─────────────────────────────────────────────────────
source scripts/print-result.sh \
  "Errors: $ERRORS | Warnings: $WARNINGS" \
  "Fix naming violations before committing." \
  "Errors: 0 | Warnings: $WARNINGS — Warnings are advisory — consider reviewing." \
  "All checks passed. $ERRORS errors, $WARNINGS warnings."
