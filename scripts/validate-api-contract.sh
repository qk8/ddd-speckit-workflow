#!/usr/bin/env bash
# Usage: ./scripts/validate-api-contract.sh
# Validates that API endpoints in codebase match docs/spec/api-contract.yaml.
# Used as Check [K] in speckit.implement.
#
# Checks:
#   1. Every endpoint defined in api-contract.yaml exists in code
#   2. HTTP methods match (case-insensitive)
#
# Output: PASS or DRIFT: [details]
# Exit code: 0 = PASS, 1 = DRIFT DETECTED

set -euo pipefail

# ── YAML indentation levels for OpenAPI paths section parser ────
INDENT_PATH=2
INDENT_METHOD=4
INDENT_RESPONSES=8
INDENT_STATUS=12

# ── Resolve to repository root ──────────────────────────────────
REPO_ROOT="$(bash scripts/repo-root.sh)"
cd "$REPO_ROOT"

# ── Locate api-contract.yaml ────────────────────────────────────
CONTRACT_FILE=""
for dir in . .specify/specs/*; do
  if [ -f "$dir/../docs/spec/api-contract.yaml" ]; then
    CONTRACT_FILE="$dir/../docs/spec/api-contract.yaml"
    break
  elif [ -f "$dir/docs/spec/api-contract.yaml" ]; then
    CONTRACT_FILE="$dir/docs/spec/api-contract.yaml"
    break
  fi
done

if [ -z "$CONTRACT_FILE" ] || [ ! -f "$CONTRACT_FILE" ]; then
  echo "api-contract.yaml not found. Skipping contract validation."
  exit 0
fi

echo "━━━ API Contract Enforcement ━━━"
echo "Contract file: $CONTRACT_FILE"
echo ""

ERRORS=0

# ── Parse endpoints from api-contract.yaml ──────────────────────
# Extract: method, path, and response status codes
# Simple YAML parser for OpenAPI paths section
CURRENT_PATH=""
CURRENT_METHOD=""
RESPONSE_CODES=()
ENDPOINTS=()

in_paths=false
in_path=false
in_method=false
in_responses=false
in_status=false

while IFS= read -r line; do
  # Detect paths section
  if [[ "$line" == "paths:" ]]; then
    in_paths=true
    continue
  fi

  if ! $in_paths; then
    continue
  fi

  # Detect new path item (indented with $INDENT_PATH spaces)
  if [[ "$line" =~ ^[[:space:]]{$INDENT_PATH}(/[a-zA-Z0-9_{}./-]+): ]]; then
    # Save previous endpoint
    if [ -n "$CURRENT_PATH" ] && [ -n "$CURRENT_METHOD" ]; then
      ENDPOINTS+=("$CURRENT_METHOD|$CURRENT_PATH|$(IFS=,; echo "${RESPONSE_CODES[*]}")")
    fi
    CURRENT_PATH="${BASH_REMATCH[1]}"
    CURRENT_METHOD=""
    RESPONSE_CODES=()
    in_path=true
    in_method=false
    in_responses=false
    continue
  fi

  # Detect method (indented with $INDENT_METHOD spaces): get:, post:, put:, delete:, patch:
  if [[ "$line" =~ ^[[:space:]]{$INDENT_METHOD}(get|post|put|delete|patch): ]]; then
    # Save previous method
    if [ -n "$CURRENT_METHOD" ]; then
      ENDPOINTS+=("$CURRENT_METHOD|$CURRENT_PATH|$(IFS=,; echo "${RESPONSE_CODES[*]}")")
    fi
    CURRENT_METHOD="${BASH_REMATCH[1]}"
    RESPONSE_CODES=()
    in_method=true
    in_responses=false
    continue
  fi

  # Detect responses section (indented with $INDENT_RESPONSES spaces)
  if [[ "$line" =~ ^[[:space:]]{$INDENT_RESPONSES}responses: ]] && $in_method; then
    in_responses=true
    in_status=false
    continue
  fi

  # Detect status code (indented with $INDENT_STATUS spaces): "200:" or "201:"
  if [[ "$line" =~ ^[[:space:]]{$INDENT_STATUS}([0-9]{3}): ]] && $in_responses; then
    RESPONSE_CODES+=("${BASH_REMATCH[1]}")
    continue
  fi

done < "$CONTRACT_FILE"

# Don't forget the last endpoint
if [ -n "$CURRENT_PATH" ] && [ -n "$CURRENT_METHOD" ]; then
  ENDPOINTS+=("$CURRENT_METHOD|$CURRENT_PATH|$(IFS=,; echo "${RESPONSE_CODES[*]}")")
fi

if [ ${#ENDPOINTS[@]} -eq 0 ]; then
  echo "No endpoints found in api-contract.yaml. Nothing to validate."
  exit 0
fi

echo "Found ${#ENDPOINTS[@]} endpoint(s) in api-contract.yaml."
echo ""

# ── Search codebase for route handlers ──────────────────────────
# Java: @RequestMapping, @GetMapping, @PostMapping, @PutMapping, @DeleteMapping
# TypeScript: app.get, app.post, app.put, app.delete, app.patch
# Python: @app.route, @router.get, @router.post, etc.

declare -A CODE_ENDPOINTS

SEARCH_PATTERNS=(
  # Java annotations
  '@RequestMapping'
  '@GetMapping'
  '@PostMapping'
  '@PutMapping'
  '@DeleteMapping'
  '@PatchMapping'
  # TypeScript/JavaScript
  '\.get\('
  '\.post\('
  '\.put\('
  '\.delete\('
  '\.patch\('
  # Python
  '@app\.route'
  '@router\.get'
  '@router\.post'
  '@router\.put'
  '@router\.delete'
  '@router\.patch'
)

source scripts/search-dirs.sh

if [ ${#SEARCH_DIRS[@]} -gt 0 ]; then
  for pattern in "${SEARCH_PATTERNS[@]}"; do
    matches=$(grep -rn "$pattern" "${SEARCH_DIRS[@]}" 2>/dev/null || true)
    if [ -n "$matches" ]; then
      while IFS= read -r match_line; do
        # Extract path from annotation or function call
        path=$(echo "$match_line" | grep -oE "'/[^']+'" | tr -d "'" || true)
        if [ -z "$path" ]; then
          path=$(echo "$match_line" | grep -oE '"[^"]+"' | tr -d '"' || true)
        fi
        if [ -n "$path" ]; then
          # Determine method from the pattern
          method=""
          if echo "$pattern" | grep -qi "get"; then method="get"
          elif echo "$pattern" | grep -qi "post"; then method="post"
          elif echo "$pattern" | grep -qi "put"; then method="put"
          elif echo "$pattern" | grep -qi "delete"; then method="delete"
          elif echo "$pattern" | grep -qi "patch"; then method="patch"
          elif echo "$pattern" | grep -qi "requestmapping"; then method="any"
          fi
          CODE_ENDPOINTS["${method^^}|${path}"]=1
        fi
      done <<< "$matches"
    fi
  done
fi

# ── Compare contract vs code ────────────────────────────────────
for endpoint in "${ENDPOINTS[@]}"; do
  IFS='|' read -r method path codes <<< "$endpoint"

  # Check if this endpoint exists in code
  found=false
  # Try lowercase method
  if [ -n "${CODE_ENDPOINTS["${method,,}|${path}"]+x}" ]; then
    found=true
  fi
  # Try uppercase method
  if [ -n "${CODE_ENDPOINTS["${method^^}|${path}"]+x}" ]; then
    found=true
  fi

  if ! $found; then
    echo "  DRIFT: ${method^^} $path — defined in contract but not found in codebase."
    ERRORS=$((ERRORS + 1))
  fi
done

# ── Summary ─────────────────────────────────────────────────────
source scripts/print-result.sh \
  "DRIFT DETECTED: $ERRORS endpoint(s) mismatch." \
  "Fix endpoints to match api-contract.yaml, or update the contract." \
  "none" \
  "PASS — All endpoints in codebase match api-contract.yaml."
