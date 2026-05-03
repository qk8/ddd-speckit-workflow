#!/usr/bin/env bash
# Cross-task API surface consistency check.
# Scans all implemented files for method signature inconsistencies
# that may indicate API drift between tasks.
#
# Usage: api-surface-check.sh <feature_dir>
# Outputs: API_CONSISTENT=true|false, API_CONFLICT_COUNT=N, API_CONFLICT_DETAILS=...

set -euo pipefail

FEATURE_DIR="${1:?Usage: api-surface-check.sh <feature_dir>}"

if [ ! -d "$FEATURE_DIR" ]; then
  echo "API_CONSISTENT=true"
  echo "API_CONFLICT_COUNT=0"
  exit 0
fi

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
mkdir -p "$ARTIFACTS_DIR"

RESULTS_FILE="${ARTIFACTS_DIR}/api-surface-check.result"
VIOLATIONS=0
DETAILS=""

# ── Extract method signatures from Java files ───────────────────
extract_java_methods() {
  local file="$1"
  # Match public/protected/private method declarations
  grep -E '^\s*(public|protected|private)\s+\w+.*\(' "$file" 2>/dev/null | \
    sed 's/^\s*//' | \
    sed 's/\s*{.*$//' | \
    sed 's/\s*;.*$//' | \
    sed 's/\s*$//'
}

# ── Extract function signatures from TypeScript/JS files ────────
extract_ts_functions() {
  local file="$1"
  # Match function declarations, arrow functions, method definitions
  grep -E '(^\s*(async\s+)?function\s+|^\s*(public|private|protected)?\s*\w+\s*\(|\w+\s*=\s*(async\s+)?\(|^\s*\w+\s*:\s*async?\s*\()' "$file" 2>/dev/null | \
    sed 's/^\s*//' | \
    sed 's/[:{].*$//' | \
    sed 's/\s*$//'
}

# ── Extract function signatures from Python files ───────────────
extract_py_functions() {
  local file="$1"
  grep -E '^\s*def\s+' "$file" 2>/dev/null | \
    sed 's/^\s*//' | \
    sed 's/:\s*.*$//' | \
    sed 's/\s*$//'
}

# ── Collect all signatures by file ──────────────────────────────
SIGNATURES_FILE=$(mktemp)
trap 'rm -f "$SIGNATURES_FILE"' EXIT

find "$FEATURE_DIR" -type f \( -name '*.java' -o -name '*.ts' -o -name '*.js' -o -name '*.py' \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/test*' ! -path '*/spec*' 2>/dev/null | \
  while read -r file; do
    ext="${file##*.}"
    case "$ext" in
      java) extract_java_methods "$file" | while read -r sig; do echo "JAVA|$(basename "$file")|$sig"; done ;;
      ts|js) extract_ts_functions "$file" | while read -r sig; do echo "TS|$(basename "$file")|$sig"; done ;;
      py) extract_py_functions "$file" | while read -r sig; do echo "PY|$(basename "$file")|$sig"; done ;;
    esac
  done > "$SIGNATURES_FILE"

# ── Detect conflicts: same method name, different signatures ────
# Extract method name (word before '(') and group by it
CONFLICTS_FILE=$(mktemp)
trap 'rm -f "$SIGNATURES_FILE" "$CONFLICTS_FILE"' EXIT

# Get unique method names per file
awk -F'|' '{
  sig = $3
  # Extract method name: word before first (
  match(sig, /[a-zA-Z_][a-zA-Z0-9_]*\(/)
  if (RSTART > 0) {
    name = substr(sig, RSTART, RLENGTH-1)
    print name "|" $2 "|" sig
  }
}' "$SIGNATURES_FILE" | sort -t'|' -k1,1 -k2,2 > "$CONFLICTS_FILE"

# Find method names that appear in multiple files with different signatures
awk -F'|' '
{
  name = $1
  file = $2
  sig = $3
  if (name in seen_files) {
    if (seen_files[name] != file) {
      # Same method in different files — check if signatures differ
      if (sig != signatures[name]) {
        conflicts[name] = file ":" sig
      }
    }
  } else {
    seen_files[name] = file
    signatures[name] = sig
  }
}
END {
  for (name in conflicts) {
    print name "|" conflicts[name]
  }
}' "$CONFLICTS_FILE" > "${CONFLICTS_FILE}.conflicts"

VIOLATION_COUNT=$(wc -l < "${CONFLICTS_FILE}.conflicts" | xargs)

if [ "$VIOLATION_COUNT" -gt 0 ]; then
  VIOLATIONS=$VIOLATION_COUNT
  DETAILS=$(awk -F'|' '{printf "  %s: %s differs from base signature\\n", $1, $2}' "${CONFLICTS_FILE}.conflicts" | head -20)
fi

# Write results
{
  echo "API_CONSISTENT=false"
  echo "API_CONFLICT_COUNT=${VIOLATIONS}"
  if [ -n "$DETAILS" ]; then
    echo "API_CONFLICT_DETAILS='${DETAILS}'"
  fi
} > "$RESULTS_FILE"

echo "API SURFACE CHECK: $VIOLATIONS conflict(s) found"
if [ -n "$DETAILS" ]; then
  echo "$DETAILS"
fi

if [ "$VIOLATIONS" -eq 0 ]; then
  echo "  All API surfaces consistent."
fi

exit 0
