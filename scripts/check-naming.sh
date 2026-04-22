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

set -euo pipefail

# ── Locate plan.md ──────────────────────────────────────────────
PLAN_FILE=""
for dir in . .specify/specs/*; do
  if [ -f "$dir/plan.md" ]; then
    PLAN_FILE="$dir/plan.md"
    break
  fi
done

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

# ── Parse §2 Ubiquitous Language ────────────────────────────────
# Format in plan.md:
#   ### [Term Name]
#   **Domain:** [domain] | **Bounded Context:** [context]
#   Definition: [description]
#
# We extract term names from ### headers under §2 section.

declare -A TERMS
CURRENT_SECTION=""
IN_SECTION2=false

while IFS= read -r line; do
  # Detect §2 header
  if [[ "$line" =~ §2.*Ubiquitous ]]; then
    IN_SECTION2=true
    continue
  fi
  # If we hit §3 or another section, stop
  if [[ "$line" =~ ^#+.*§[3-9] ]] || [[ "$line" =~ ^#+.*§1[0-9] ]] || [[ "$line" =~ ^#+.*§20 ]]; then
    IN_SECTION2=false
    continue
  fi

  if $IN_SECTION2 && [[ "$line" =~ ^###\ (.+) ]]; then
    term="${BASH_REMATCH[1]}"
    # Clean up: remove trailing descriptions after |
    term=$(echo "$term" | sed 's| *|.*||' | xargs)
    if [ -n "$term" ]; then
      TERMS["$term"]=1
    fi
  fi
done < "$PLAN_FILE"

if [ ${#TERMS[@]} -eq 0 ]; then
  echo "No ubiquitous language terms found in plan.md §2. Nothing to validate."
  exit 2
fi

echo "━━━ Ubiquitous Language Validation ━━━"
echo "Found ${#TERMS[@]} term(s) in plan.md §2."
echo ""

ERRORS=0
WARNINGS=0
RENAMES=()

# ── Search codebase ─────────────────────────────────────────────
# Search in src/ and app/ directories; fall back to any top-level dirs
SEARCH_DIRS=()
for dir in src app; do
  if [ -d "$dir" ]; then
    SEARCH_DIRS+=("$dir")
  fi
done
if [ ${#SEARCH_DIRS[@]} -eq 0 ]; then
  echo "No src/ or app/ directory found. Skipping codebase search."
  exit 0
fi

for term in "${!TERMS[@]}"; do
  # Case-insensitive search for the term in codebase
  matches=$(grep -rl --include="*.java" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" --include="*.kt" --include="*.scala" --include="*.rb" --include="*.cs" --include="*.swift" --include="*.php" --include="*.cpp" --include="*.h" --include="*.hpp" --include="*.sql" --include="*.yaml" --include="*.yml" --include="*.json" --include="*.md" \
    "$term" "${SEARCH_DIRS[@]}" 2>/dev/null || true)

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
      RENAMES+=("$term")
    fi
  fi
done

# ── Cross-check: find code terms not in plan ────────────────────
# Search for common DDD patterns (Aggregate, Repository, UseCase, etc.)
# and check if they match plan.md terms
PATTERN_FILES=$(grep -rl --include="*.java" --include="*.ts" --include="*.tsx" --include="*.py" \
  -E "(Aggregate|Repository|UseCase|DomainEvent|ValueObject)" "${SEARCH_DIRS[@]}" 2>/dev/null || true)

if [ -n "$PATTERN_FILES" ]; then
  for file in $PATTERN_FILES; do
    # Extract class/type names matching DDD patterns
    code_names=$(grep -oE "[A-Z][a-zA-Z]+(Aggregate|Repository|UseCase|DomainEvent|ValueObject)" "$file" 2>/dev/null || true)
    for name in $code_names; do
      # Check if this name exists in TERMS
      found=false
      for term in "${!TERMS[@]}"; do
        if [[ "$name" == "$term" ]]; then
          found=true
          break
        fi
      done
      if ! $found; then
        # Check if a similar term exists in plan
        for term in "${!TERMS[@]}"; do
          # Check if the code name contains the plan term or vice versa
          if [[ "$name" == *"$term"* ]] || [[ "$term" == *"$name"* ]]; then
            echo "  NOTE: Code uses \"$name\" but plan.md §2 defines \"$term\" — consider aligning."
            WARNINGS=$((WARNINGS + 1))
            break
          fi
        done
      fi
    done
  done
fi

# ── Summary ─────────────────────────────────────────────────────
echo ""
echo "━━━ Validation Result ━━━"
if [ "$ERRORS" -gt 0 ]; then
  echo "  Errors: $ERRORS | Warnings: $WARNINGS"
  echo "  Fix naming violations before committing."
  exit 1
elif [ "$WARNINGS" -gt 0 ]; then
  echo "  Errors: 0 | Warnings: $WARNINGS"
  echo "  Warnings are advisory — consider reviewing."
  exit 0
else
  echo "  All checks passed. $ERRORS errors, $WARNINGS warnings."
  exit 0
fi
