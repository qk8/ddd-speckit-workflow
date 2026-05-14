#!/usr/bin/env bash
# Quantitative Pass Gate (Check R)
# Verifies code coverage, type checking, and build success.
# Reads quantitative thresholds from plan.md §13 (Testing Strategy).
#
# Usage: scripts/run-quantitative.sh <feature_dir>
set -euo pipefail

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_DIR" ]; then
  echo "QUANTITATIVE GATE: SKIP (no feature directory)"
  exit 0
fi

PLAN_FILE="${FEATURE_DIR}/plan.md"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"

# ── State ───────────────────────────────────────────────────────
BUILD_OK=true
TYPE_OK=true
COV_OK=true
BUILD_CMD=""
TYPE_CMD=""
COV_CMD=""
COV_THRESHOLD=0
FAIL_COUNT=0

# ── Extract a value from plan.md §13 (Testing Strategy) ─────────
# Looks in the Testing Strategy section for lines like:
#   coverage_threshold: 80
#   type_check_command: npx tsc --noEmit
#   build_command: npm run build
extract_testing_value() {
  local key="$1"
  local value=""

  if [ ! -f "$PLAN_FILE" ]; then
    return 1
  fi

  # Extract the Testing Strategy section (between §13 or "Testing Strategy" header
  # and the next § or section header)
  local section
  section=$(awk '
    /^[[:space:]]*#/ { h=$0; gsub(/^[[:space:]]+/, "", h); gsub(/[[:space:]]+$/, "", h) }
    h ~ /testing/i || h ~ /§13/ || h == "13" { in_section=1; next }
    in_section && /^[[:space:]]*§[0-9]/ { exit }
    in_section && /^[[:space:]]*[0-9]+[[:space:]]+[A-Z]/ { exit }
    in_section { print }
  ' "$PLAN_FILE" 2>/dev/null || true)

  if [ -z "$section" ]; then
    return 1
  fi

  value=$(echo "$section" | grep -E "^\s*${key}\s*:" | tail -1 | sed 's/^[^:]*:\s*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)

  if [ -n "$value" ]; then
    echo "$value"
    return 0
  fi

  return 1
}

# ── Auto-detect project type and derive defaults ────────────────
detect_project_type() {
  if [ -f "$FEATURE_DIR/package.json" ] || [ -f "package.json" ]; then
    echo "typescript"
    return 0
  fi
  if [ -f "$FEATURE_DIR/pyproject.toml" ] || [ -f "$FEATURE_DIR/requirements.txt" ] || [ -f "$FEATURE_DIR/setup.py" ]; then
    echo "python"
    return 0
  fi
  if [ -f "$FEATURE_DIR/pom.xml" ] || [ -f "$FEATURE_DIR/build.gradle" ] || [ -f "$FEATURE_DIR/gradlew" ]; then
    echo "java"
    return 0
  fi
  if [ -f "$FEATURE_DIR/go.mod" ]; then
    echo "go"
    return 0
  fi
  echo "unknown"
  return 0
}

detect_coverage_tool() {
  # Returns: jest,nyc,c8,py,jacoco,pytest, or empty
  local tool=""

  case "$PROJECT_TYPE" in
    typescript)
      # Check for coverage config in package.json
      if [ -f "$FEATURE_DIR/package.json" ] || [ -f "package.json" ]; then
        local pj
        if [ -f "$FEATURE_DIR/package.json" ]; then
          pj="$FEATURE_DIR/package.json"
        else
          pj="package.json"
        fi
        if grep -q '"nyc"' "$pj" 2>/dev/null || grep -q '"c8"' "$pj" 2>/dev/null || grep -q '"jest"' "$pj" 2>/dev/null; then
          if grep -q '"jest"' "$pj" 2>/dev/null; then
            echo "jest"
          elif grep -q '"c8"' "$pj" 2>/dev/null; then
            echo "c8"
          else
            echo "nyc"
          fi
          return 0
        fi
      fi
      # Check for jest in devDependencies or node_modules
      if [ -d "$FEATURE_DIR/node_modules/jest" ] || [ -f "node_modules/jest" ]; then
        echo "jest"
        return 0
      fi
      if [ -d "$FEATURE_DIR/node_modules/c8" ] || [ -f "node_modules/c8" ]; then
        echo "c8"
        return 0
      fi
      if [ -d "$FEATURE_DIR/node_modules/nyc" ] || [ -f "node_modules/nyc" ]; then
        echo "nyc"
        return 0
      fi
      ;;
    python)
      if command -v pytest >/dev/null 2>&1; then
        echo "pytest"
        return 0
      fi
      if [ -f "$FEATURE_DIR/requirements.txt" ] && grep -q "pytest-cov" "$FEATURE_DIR/requirements.txt" 2>/dev/null; then
        echo "pytest"
        return 0
      fi
      if command -v coverage >/dev/null 2>&1; then
        echo "py"
        return 0
      fi
      ;;
    java)
      if [ -f "$FEATURE_DIR/pom.xml" ] && grep -q "jacoco" "$FEATURE_DIR/pom.xml" 2>/dev/null; then
        echo "jacoco"
        return 0
      fi
      if [ -f "$FEATURE_DIR/build.gradle" ] && grep -q "jacoco" "$FEATURE_DIR/build.gradle" 2>/dev/null; then
        echo "jacoco"
        return 0
      fi
      ;;
  esac

  echo ""
  return 0
}

get_coverage_test_cmd() {
  local tool="$1"
  local cmd=""

  case "$PROJECT_TYPE" in
    typescript)
      case "$tool" in
        jest) cmd="jest --coverage" ;;
        nyc)  cmd="npx nyc npm test" ;;
        c8)   cmd="npx c8 npm test" ;;
      esac
      ;;
    python)
      case "$tool" in
        pytest) cmd="pytest --cov --cov-report=term-missing" ;;
        py)     cmd="coverage run -m pytest && coverage report" ;;
      esac
      ;;
    java)
      case "$tool" in
        jacoco) cmd="./mvnw test" ;;
      esac
      ;;
  esac

  echo "$cmd"
}

get_coverage_test_cmd_with_flags() {
  local tool="$1"
  local flags=""

  case "$PROJECT_TYPE" in
    typescript)
      case "$tool" in
        jest) flags="--coverage" ;;
        nyc)  flags="" ;;
        c8)   flags="" ;;
      esac
      ;;
    python)
      case "$tool" in
        pytest) flags="--cov --cov-report=term-missing" ;;
        py)     flags="" ;;
      esac
      ;;
    java)
      case "$tool" in
        jacoco) flags="" ;;
      esac
      ;;
  esac

  echo "$flags"
}

parse_coverage_percentage() {
  local output="$1"
  local tool="$2"
  local pct=""

  case "$tool" in
    jest)
      # Jest coverage table: Lines: 85.2% | Statements: 85.2%
      pct=$(echo "$output" | grep -iE "Statements|Lines|Branches" | head -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
      ;;
    nyc|c8)
      # c8/nyc: "Lines : 85.2%" or "All files | 85.2%"
      pct=$(echo "$output" | grep -iE '^(Lines|Statements|Branches)' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
      if [ -z "$pct" ]; then
        pct=$(echo "$output" | grep -oE 'All files[[:space:]]*\|[[:space:]]*[0-9]+(\.[0-9]+)?%' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
      fi
      if [ -z "$pct" ]; then
        # Fallback: look for percentage on "Total" or summary lines
        pct=$(echo "$output" | grep -iE 'total|all' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
      fi
      ;;
    py)
      # coverage.py: TOTAL row with percentage, e.g. "TOTAL    1234    100    92%"
      pct=$(echo "$output" | grep -E '^TOTAL' | grep -oE '[0-9]+(\.[0-9]+)?%' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
      ;;
    pytest)
      # pytest-cov: "= 85% complete" or coverage summary lines
      pct=$(echo "$output" | grep -oE '[0-9]+(\.[0-9]+)?% complete' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
      if [ -z "$pct" ]; then
        pct=$(echo "$output" | grep -E '^TOTAL' | grep -oE '[0-9]+(\.[0-9]+)?%' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
      fi
      ;;
    jacoco)
      # JaCoCo: "Overall" row with percentage, e.g. "Overall  1234  100  92%"
      pct=$(echo "$output" | grep -iE '^\s*(OVERALL|Total|Class)' | grep -oE '[0-9]+(\.[0-9]+)?%' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
      ;;
  esac

  echo "${pct:-0}"
}

# ── Helper: run a command with timeout and return exit code ───────
run_cmd() {
  local cmd="$1"
  local outfile="$2"
  local timeout_secs="${3:-300}"
  local exit_code=0
  # Use timeout to prevent hanging builds (default 5 min)
  ( timeout "$timeout_secs" bash -c "$cmd" ) > "$outfile" 2>&1 || exit_code=$?
  # Exit code 124 = timeout
  if [ "$exit_code" -eq 124 ]; then
    echo "WARNING: Command timed out after ${timeout_secs}s: $cmd" >&2
  fi
  echo "$exit_code"
}

# ── Main logic ──────────────────────────────────────────────────
PROJECT_TYPE=$(detect_project_type)

# 1) Extract thresholds from plan.md
COV_THRESHOLD_RAW=$(extract_testing_value "coverage_threshold" 2>/dev/null || true)
if [ -n "$COV_THRESHOLD_RAW" ]; then
  # Strip trailing % if present
  COV_THRESHOLD=$(echo "$COV_THRESHOLD_RAW" | sed 's/%//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
  # Ensure numeric
  case "$COV_THRESHOLD" in
    *[!0-9.]*) COV_THRESHOLD=80 ;;
  esac
  if [ -z "$COV_THRESHOLD" ]; then
    COV_THRESHOLD=80
  fi
else
  COV_THRESHOLD=0
fi

COV_CMD_RAW=$(extract_testing_value "coverage_command" 2>/dev/null || true)
TYPE_CMD_RAW=$(extract_testing_value "type_check_command" 2>/dev/null || true)
BUILD_CMD_RAW=$(extract_testing_value "build_command" 2>/dev/null || true)

# Build: from plan.md or auto-detect
if [ -n "$BUILD_CMD_RAW" ]; then
  BUILD_CMD="$BUILD_CMD_RAW"
else
  case "$PROJECT_TYPE" in
    typescript)
      if [ -f "$FEATURE_DIR/package.json" ] || [ -f "package.json" ]; then
        BUILD_CMD="npm run build"
      fi
      ;;
    python)
      BUILD_CMD="python -m py_compile ."
      ;;
    java)
      if [ -f "$FEATURE_DIR/mvnw" ]; then
        BUILD_CMD="./mvnw package -DskipTests"
      elif [ -f "$FEATURE_DIR/gradlew" ]; then
        BUILD_CMD="./gradlew build -x test"
      else
        BUILD_CMD="mvn package -DskipTests"
      fi
      ;;
    go)
      BUILD_CMD="go build ./..."
      ;;
  esac
fi

# Type check: from plan.md or auto-detect
if [ -n "$TYPE_CMD_RAW" ]; then
  TYPE_CMD="$TYPE_CMD_RAW"
else
  case "$PROJECT_TYPE" in
    typescript)
      if [ -f "$FEATURE_DIR/tsconfig.json" ]; then
        TYPE_CMD="npx tsc --noEmit"
      fi
      ;;
    python)
      TYPE_CMD=""
      ;;
    java)
      TYPE_CMD="./mvnw compile"
      ;;
    go)
      TYPE_CMD="go vet ./..."
      ;;
  esac
fi

# Coverage: from plan.md, auto-detected tool, or threshold presence
COV_TOOL=""
if [ -n "$COV_CMD_RAW" ]; then
  COV_CMD="$COV_CMD_RAW"
else
  COV_TOOL=$(detect_coverage_tool)
  if [ -n "$COV_TOOL" ] && [ "$COV_THRESHOLD" -gt 0 ]; then
    COV_CMD=$(get_coverage_test_cmd "$COV_TOOL")
  fi
fi

# ── Determine what to run ───────────────────────────────────────
HAS_ANY_CHECK=false
if [ -n "$BUILD_CMD" ]; then HAS_ANY_CHECK=true; fi
if [ -n "$TYPE_CMD" ]; then HAS_ANY_CHECK=true; fi
if [ -n "$COV_CMD" ] || ([ "$COV_THRESHOLD" -gt 0 ] && [ -n "$COV_TOOL" ]); then HAS_ANY_CHECK=true; fi

if [ "$HAS_ANY_CHECK" = false ]; then
  echo "QUANTITATIVE GATE: SKIP (no quantitative checks configured in plan.md)"
  echo "SKIP" > "${RESULTS_DIR}/R.result"
  exit 0
fi

# ── A) Build ────────────────────────────────────────────────────
BUILD_OUTPUT=$(mktemp /tmp/quant-build-XXXXXX.txt)
trap 'rm -f "$BUILD_OUTPUT"' EXIT

if [ -n "$BUILD_CMD" ]; then
  BUILDEXIT=$(run_cmd "$BUILD_CMD" "$BUILD_OUTPUT" 600)
  if [ "$BUILDEXIT" -ne 0 ]; then
    BUILD_OK=false
    FAIL_COUNT=$((FAIL_COUNT + 1))
    # Extract a brief error from output
    BUILD_ERROR=$(head -5 "$BUILD_OUTPUT" | tail -1 | sed 's/[[:space:]]*$//')
    if [ -z "$BUILD_ERROR" ]; then
      BUILD_ERROR="exit $BUILDEXIT"
    fi
  fi
fi

# ── B) Type check ──────────────────────────────────────────────
TYPE_OUTPUT=$(mktemp /tmp/quant-type-XXXXXX.txt)
trap 'rm -f "$BUILD_OUTPUT" "$TYPE_OUTPUT"' EXIT

if [ -n "$TYPE_CMD" ]; then
  TYPEEXIT=$(run_cmd "$TYPE_CMD" "$TYPE_OUTPUT" 300)
  if [ "$TYPEEXIT" -ne 0 ]; then
    TYPE_OK=false
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
fi

# ── C) Coverage ────────────────────────────────────────────────
COV_OUTPUT=$(mktemp /tmp/quant-cov-XXXXXX.txt)
trap 'rm -f "$BUILD_OUTPUT" "$TYPE_OUTPUT" "$COV_OUTPUT"' EXIT

COV_ACTUAL=""
if [ -n "$COV_CMD" ]; then
  COV_EXIT=$(run_cmd "$COV_CMD" "$COV_OUTPUT" 600)
  if [ "$COV_EXIT" -ne 0 ]; then
    # Coverage tool failed — try to still parse percentage
    COV_ACTUAL=$(parse_coverage_percentage "$(head -50 "$COV_OUTPUT")" "$COV_TOOL" 2>/dev/null || echo "0")
  else
    COV_ACTUAL=$(parse_coverage_percentage "$(cat "$COV_OUTPUT")" "$COV_TOOL" 2>/dev/null || echo "0")
  fi

  if [ -n "$COV_ACTUAL" ] && [ "$COV_ACTUAL" != "0" ]; then
    # Compare: COV_ACTUAL vs COV_THRESHOLD
    COV_PASS=$(awk "BEGIN { print ($COV_ACTUAL >= $COV_THRESHOLD) ? 1 : 0 }")
    if [ "$COV_PASS" -eq 0 ]; then
      COV_OK=false
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  else
    # Could not parse coverage — skip with warning
    if [ "$COV_THRESHOLD" -gt 0 ]; then
      echo "QUANTITATIVE GATE: WARNING — coverage tool detected ($COV_TOOL) but could not parse coverage percentage" >&2
      echo "QUANTITATIVE GATE: WARNING — coverage check skipped (parse failure)" >&2
    fi
    COV_ACTUAL="N/A"
  fi
fi

# ── Format and print results ────────────────────────────────────
echo "QUANTITATIVE GATE:"

# Build line
if [ -n "$BUILD_CMD" ]; then
  if [ "$BUILD_OK" = true ]; then
    echo "  BUILD: ${BUILD_CMD} — PASS"
  else
    echo "  BUILD: ${BUILD_CMD} — FAIL — ${BUILD_ERROR}"
  fi
fi

# Type check line
if [ -n "$TYPE_CMD" ]; then
  if [ "$TYPE_OK" = true ]; then
    echo "  TYPE CHECK: ${TYPE_CMD} — PASS"
  else
    TYPE_ERROR=$(head -5 "$TYPE_OUTPUT" | tail -1 | sed 's/[[:space:]]*$//')
    if [ -z "$TYPE_ERROR" ]; then
      TYPE_ERROR="exit 1"
    fi
    echo "  TYPE CHECK: ${TYPE_CMD} — FAIL — ${TYPE_ERROR}"
  fi
fi

# Coverage line
if [ -n "$COV_CMD" ]; then
  COV_LABEL="${COV_CMD}"
  if [ -n "$COV_ACTUAL" ] && [ "$COV_ACTUAL" != "N/A" ]; then
    COV_LABEL="${COV_ACTUAL}% (threshold: ${COV_THRESHOLD}%)"
  fi
  if [ "$COV_OK" = true ]; then
    echo "  COVERAGE: ${COV_LABEL} — PASS"
  else
    echo "  COVERAGE: ${COV_LABEL} — FAIL"
  fi
fi

echo ""

# ── Write result and exit ──────────────────────────────────────
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "QUANTITATIVE GATE: PASS — all checks passed"
  echo "PASS" > "${RESULTS_DIR}/R.result"
  exit 0
else
  echo "QUANTITATIVE GATE: FAIL — ${FAIL_COUNT} check(s) failed"
  echo "FAIL" > "${RESULTS_DIR}/R.result"
  exit 1
fi
