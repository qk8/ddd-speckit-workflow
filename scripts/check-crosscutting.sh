#!/usr/bin/env bash
# Cross-Cutting Concerns Check (Check N / integration.crosscutting)
# Verifies cross-cutting concerns are properly delegated to middleware/pipes/guards.
#
# Usage: check-crosscutting.sh <feature_dir>
#
# Writes PASS/FAIL to .artifacts/check-results/integration_crosscutting.result

set -euo pipefail

FEATURE_DIR="${1:?Usage: check-crosscutting.sh <feature_dir>}"

ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

echo "CROSSCUTTING: Scanning ${FEATURE_DIR}"

# ── Detect language ──────────────────────────────────────────────
LANGUAGE=""
if [ -f "${FEATURE_DIR}/package.json" ] || [ -f "${FEATURE_DIR}/tsconfig.json" ]; then
  LANGUAGE="typescript"
elif [ -f "${FEATURE_DIR}/requirements.txt" ] || [ -f "${FEATURE_DIR}/pyproject.toml" ]; then
  LANGUAGE="python"
elif [ -f "${FEATURE_DIR}/pom.xml" ] || [ -f "${FEATURE_DIR}/build.gradle" ]; then
  LANGUAGE="java"
elif [ -f "${FEATURE_DIR}/go.mod" ]; then
  LANGUAGE="go"
fi

if [ -z "$LANGUAGE" ]; then
  echo "CROSSCUTTING: SKIP (no recognized language in ${FEATURE_DIR})"
  echo "SKIP" > "${RESULTS_DIR}/integration_crosscutting.result"
  exit 0
fi

# ── Find source files (excluding test files) ─────────────────────
SRC_FILES=""
case "$LANGUAGE" in
  typescript)
    SRC_FILES=$(find "$FEATURE_DIR" -type f \( -name '*.ts' -o -name '*.tsx' \) \
      ! -name '*test*' ! -name '*.spec.*' \
      ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/dist/*' ! -path '*/build/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
  python)
    SRC_FILES=$(find "$FEATURE_DIR" -type f -name '*.py' \
      ! -name '*test*' ! -name '*_test.py' ! -name 'conftest.py' \
      ! -path '*/.venv/*' ! -path '*/venv/*' ! -path '*/__pycache__/*' ! -path '*/.git/*' \
      ! -path '*/.artifacts/*' 2>/dev/null || true)
    ;;
  java)
    SRC_FILES=$(find "$FEATURE_DIR" -type f -name '*.java' \
      ! -name '*Test*' ! -name '*Tests*' \
      ! -path '*/build/*' ! -path '*/target/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
  go)
    SRC_FILES=$(find "$FEATURE_DIR" -type f -name '*.go' \
      ! -name '*_test.go' \
      ! -path '*/vendor/*' ! -path '*/.git/*' ! -path '*/.artifacts/*' \
      2>/dev/null || true)
    ;;
esac

if [ -z "$SRC_FILES" ]; then
  echo "CROSSCUTTING: SKIP (no source files found)"
  echo "SKIP" > "${RESULTS_DIR}/integration_crosscutting.result"
  exit 0
fi

# ── Check for cross-cutting concern violations ───────────────────
# In clean architecture, domain/business logic should NOT directly call:
# - logging frameworks (use injected logger)
# - HTTP clients (should be in infrastructure layer)
# - database drivers (should use repository pattern)
# - authentication middleware (should use guards/pipes)
# - Date.now() / time sources (should use injected time provider)

VIOLATIONS=0
VIOLATION_TYPES=""

case "$LANGUAGE" in
  typescript)
    # Check for direct console.log in non-test source files
    CONSOLE_LOG=$(echo "$SRC_FILES" | xargs grep -n 'console\.\(log\|error\|warn\|debug\)' 2>/dev/null | grep -v 'console\.log.*\/\//' | grep -v 'node_modules' || true)
    if [ -n "$CONSOLE_LOG" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct console.log calls found (should use injected logger)\n"
    fi

    # Check for direct HTTP calls in domain layer
    HTTP_CALLS=$(echo "$SRC_FILES" | xargs grep -n 'axios\.\|fetch(\|http\.\|https\.\|ofetch' 2>/dev/null | grep -v 'node_modules' | grep -v '/infrastructure/' | grep -v '/http/' || true)
    if [ -n "$HTTP_CALLS" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct HTTP calls outside infrastructure layer\n"
    fi

    # Check for direct database driver usage in domain layer
    DB_CALLS=$(echo "$SRC_FILES" | xargs grep -n 'pool\.query\|connection\.execute\|\.execute\|mongoose\.\|prisma\.' 2>/dev/null | grep -v '/infrastructure/' | grep -v '/repository/' || true)
    if [ -n "$DB_CALLS" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct database calls outside infrastructure layer\n"
    fi

    # Check for Date.now() in domain layer
    DATE_NOW=$(echo "$SRC_FILES" | xargs grep -n 'Date\.now()' 2>/dev/null | grep -v '/infrastructure/' | grep -v '/test' || true)
    if [ -n "$DATE_NOW" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct Date.now() calls outside infrastructure layer\n"
    fi
    ;;

  python)
    # Check for direct print() in domain layer
    PRINT_CALL=$(echo "$SRC_FILES" | xargs grep -n '^\s*print\s*(' 2>/dev/null | grep -v '/infrastructure/' | grep -v '/logging/' || true)
    if [ -n "$PRINT_CALL" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct print() calls found (should use injected logger)\n"
    fi

    # Check for direct HTTP calls in domain layer
    HTTP_CALLS=$(echo "$SRC_FILES" | xargs grep -n 'requests\.\|urllib\.\|httpx\.' 2>/dev/null | grep -v '/infrastructure/' | grep -v '/http/' || true)
    if [ -n "$HTTP_CALLS" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct HTTP calls outside infrastructure layer\n"
    fi

    # Check for direct database driver usage
    DB_CALLS=$(echo "$SRC_FILES" | xargs grep -n '\.execute(\|cursor\.\|Session\(\)\|get_db\(' 2>/dev/null | grep -v '/infrastructure/' | grep -v '/repository/' || true)
    if [ -n "$DB_CALLS" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct database calls outside infrastructure layer\n"
    fi
    ;;

  java)
    # Check for direct logging in domain layer
    SYSOUT=$(echo "$SRC_FILES" | xargs grep -n 'System\.\(out\|err\)\.\(print\|println\)' 2>/dev/null | grep -v '/infrastructure/' || true)
    if [ -n "$SYSOUT" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct System.out/err calls found (should use injected logger)\n"
    fi

    # Check for direct HTTP calls in domain layer
    HTTP_CALLS=$(echo "$SRC_FILES" | xargs grep -n 'HttpClient\.\|RestTemplate\.\|WebClient\.' 2>/dev/null | grep -v '/infrastructure/' | grep -v '/http/' || true)
    if [ -n "$HTTP_CALLS" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct HTTP calls outside infrastructure layer\n"
    fi
    ;;

  go)
    # Check for direct log calls in domain layer
    LOG_CALLS=$(echo "$SRC_FILES" | xargs grep -n 'log\.\(Print\|Printf\|Println\|Fatal\|Panic' 2>/dev/null | grep -v '/infrastructure/' | grep -v 'log\.go' || true)
    if [ -n "$LOG_CALLS" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct log calls found (should use injected logger)\n"
    fi

    # Check for direct HTTP calls in domain layer
    HTTP_CALLS=$(echo "$SRC_FILES" | xargs grep -n 'http\.Get\|http\.Post\|http\.Client' 2>/dev/null | grep -v '/infrastructure/' || true)
    if [ -n "$HTTP_CALLS" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_TYPES="${VIOLATION_TYPES}Direct HTTP calls outside infrastructure layer\n"
    fi
    ;;
esac

# ── Report results ───────────────────────────────────────────────
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "CROSSCUTTING: FAIL — ${VIOLATIONS} violation(s) found:"
  echo -e "$VIOLATION_TYPES" | while read -r line; do
    [ -n "$line" ] && echo "  $line"
  done
  echo "FAIL" > "${RESULTS_DIR}/integration_crosscutting.result"
  echo "---" >> "${RESULTS_DIR}/integration_crosscutting.result"
  echo -e "$VIOLATION_TYPES" >> "${RESULTS_DIR}/integration_crosscutting.result"
  exit 1
fi

echo "CROSSCUTTING: PASS — no cross-cutting concern violations found"
echo "PASS" > "${RESULTS_DIR}/integration_crosscutting.result"
exit 0
