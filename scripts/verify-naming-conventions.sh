#!/usr/bin/env bash
# Naming Conventions Check (Check V / code_quality.naming)
# Verifies naming conventions follow language/project standards.
#
# Usage: verify-naming-conventions.sh <feature_dir>
#
# Writes PASS/FAIL to .artifacts/check-results/code_quality_naming.result

set -euo pipefail

FEATURE_DIR="${1:?Usage: verify-naming-conventions.sh <feature_dir>}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

echo "NAMING: Scanning ${FEATURE_DIR}"

# ── Detect language from project files ───────────────────────────
LANGUAGE=""
if [ -f "${FEATURE_DIR}/package.json" ]; then
  LANGUAGE="typescript"
elif [ -f "${FEATURE_DIR}/tsconfig.json" ]; then
  LANGUAGE="typescript"
elif [ -f "${FEATURE_DIR}/requirements.txt" ] || [ -f "${FEATURE_DIR}/setup.py" ] || [ -f "${FEATURE_DIR}/pyproject.toml" ]; then
  LANGUAGE="python"
elif [ -f "${FEATURE_DIR}/pom.xml" ] || [ -f "${FEATURE_DIR}/build.gradle" ] || [ -f "${FEATURE_DIR}/build.gradle.kts" ]; then
  LANGUAGE="java"
elif [ -f "${FEATURE_DIR}/go.mod" ]; then
  LANGUAGE="go"
fi

if [ -z "$LANGUAGE" ]; then
  echo "NAMING: SKIP (no recognized language in ${FEATURE_DIR})"
  echo "SKIP" > "${RESULTS_DIR}/code_quality_naming.result"
  exit 0
fi

echo "NAMING: Language detected: ${LANGUAGE}"

# ── Find source files ────────────────────────────────────────────
case "$LANGUAGE" in
  typescript)
    SRC_FILES=$(find "$FEATURE_DIR" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) \
      ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/dist/*' ! -path '*/build/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
  python)
    SRC_FILES=$(find "$FEATURE_DIR" -type f -name '*.py' \
      ! -path '*/.venv/*' ! -path '*/venv/*' ! -path '*/__pycache__/*' ! -path '*/.git/*' \
      ! -path '*/.artifacts/*' ! -name 'conftest.py' ! -name 'setup.py' \
      2>/dev/null || true)
    ;;
  java)
    SRC_FILES=$(find "$FEATURE_DIR" -type f -name '*.java' \
      ! -path '*/build/*' ! -path '*/target/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
  go)
    SRC_FILES=$(find "$FEATURE_DIR" -type f -name '*.go' \
      ! -path '*/vendor/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
esac

if [ -z "$SRC_FILES" ]; then
  echo "NAMING: SKIP (no source files found)"
  echo "SKIP" > "${RESULTS_DIR}/code_quality_naming.result"
  exit 0
fi

VIOLATIONS=0
VIOLATION_LIST=""

# ── TypeScript naming conventions ────────────────────────────────
if [ "$LANGUAGE" = "typescript" ]; then
  # Check for PascalCase class/interface/enum names (should not start with lowercase)
  # This is a simplified check — real convention enforcement is done by tsc/eslint
  # We check for obvious violations: constants that should be UPPER_SNAKE_CASE
  # and variables that should not be snake_case

  # Check for function declarations that might violate camelCase
  # (e.g., function my_function_name { — snake_case function names)
  SNAKE_FUNCS=$(echo "$SRC_FILES" | xargs grep -nE '^\s*(export\s+)?(async\s+)?function\s+[a-z_]+_[a-z]' 2>/dev/null || true)
  if [ -n "$SNAKE_FUNCS" ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}Snake-case function names found (should be camelCase)\n"
  fi

  # Check for class names that don't start with uppercase
  LOWER_CLASSES=$(echo "$SRC_FILES" | xargs grep -nE '^\s*(export\s+)?class\s+[a-z]' 2>/dev/null || true)
  if [ -n "$LOWER_CLASSES" ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}Lowercase class names found (should be PascalCase)\n"
  fi
fi

# ── Python naming conventions ───────────────────────────────────
if [ "$LANGUAGE" = "python" ]; then
  # Check for camelCase function names (should be snake_case)
  CAMEL_FUNCS=$(echo "$SRC_FILES" | xargs grep -nE '^\s*def\s+[a-z]+[A-Z]' 2>/dev/null || true)
  if [ -n "$CAMEL_FUNCS" ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}camelCase function names found (should be snake_case)\n"
  fi

  # Check for camelCase variable names (should be snake_case)
  CAMEL_VARS=$(echo "$SRC_FILES" | xargs grep -nE '^\s*(const|let|var)\s+[a-z]+[A-Z]' 2>/dev/null || true)
  if [ -n "$CAMEL_VARS" ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}camelCase variable names found (should be snake_case)\n"
  fi

  # Check for class names that don't use PascalCase
  LOWER_CLASSES=$(echo "$SRC_FILES" | xargs grep -nE '^\s*class\s+[a-z]' 2>/dev/null || true)
  if [ -n "$LOWER_CLASSES" ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}Lowercase class names found (should be PascalCase)\n"
  fi
fi

# ── Java naming conventions ──────────────────────────────────────
if [ "$LANGUAGE" = "java" ]; then
  # Check for snake_case method names (should be camelCase)
  SNAKE_METHODS=$(echo "$SRC_FILES" | xargs grep -nE 'public\s+.*\s+[a-z]+_[a-z]+\s*\(' 2>/dev/null || true)
  if [ -n "$SNAKE_METHODS" ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}Snake-case method names found (should be camelCase)\n"
  fi

  # Check for class names that don't use PascalCase
  LOWER_CLASSES=$(echo "$SRC_FILES" | xargs grep -nE '^\s*(public|private|protected)?\s*(abstract|final)?\s*class\s+[a-z]' 2>/dev/null || true)
  if [ -n "$LOWER_CLASSES" ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}Lowercase class names found (should be PascalCase)\n"
  fi
fi

# ── Go naming conventions ────────────────────────────────────────
if [ "$LANGUAGE" = "go" ]; then
  # Check for exported identifiers that don't start with uppercase
  # In Go, exported names must start with uppercase
  LOWER_EXPORTS=$(echo "$SRC_FILES" | xargs grep -nE '^\s*(func|var|const)\s+[a-z]' 2>/dev/null || true)
  if [ -n "$LOWER_EXPORTS" ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
    VIOLATION_LIST="${VIOLATION_LIST}Lowercase exported names found (exported identifiers must start with uppercase)\n"
  fi
fi

# ── Report results ───────────────────────────────────────────────
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "NAMING: FAIL — ${VIOLATIONS} violation(s) found:"
  echo -e "$VIOLATION_LIST" | while read -r line; do
    [ -n "$line" ] && echo "  $line"
  done
  echo "FAIL" > "${RESULTS_DIR}/code_quality_naming.result"
  echo "---" >> "${RESULTS_DIR}/code_quality_naming.result"
  echo -e "$VIOLATION_LIST" >> "${RESULTS_DIR}/code_quality_naming.result"
  exit 1
fi

echo "NAMING: PASS — no naming convention violations found"
echo "PASS" > "${RESULTS_DIR}/code_quality_naming.result"
exit 0
