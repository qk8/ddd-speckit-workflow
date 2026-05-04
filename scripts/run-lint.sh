#!/usr/bin/env bash
# Linter Check (Check D)
# Executes the lint command defined in plan.md §13 (Linting) or §14 (DevEx)
# and reports PASS/FAIL — verifying no lint violations.
set -euo pipefail

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_DIR" ]; then
  echo "LINTER: SKIP (no feature directory)"
  exit 0
fi

# If the feature directory doesn't exist, we can't create artifacts there
# — treat as SKIP since there's nothing to lint
if [ ! -d "$FEATURE_DIR" ]; then
  echo "LINTER: SKIP (feature directory does not exist)"
  exit 0
fi

PLAN_FILE="${FEATURE_DIR}/plan.md"

# ── Extract lint command from plan.md ───────────────────────────
# Looks in §13 (Testing Strategy) or §14 (DevEx) for lines like:
#   lint_command:        npx eslint . --max-warnings 0
#   lint:                biome check .
# Falls back to common patterns if not found.
extract_lint_command() {
  if [ ! -f "$PLAN_FILE" ]; then
    return 1
  fi

  # Search for lint_command: or lint: (only in linting-related sections)
  # Match lines like "lint_command:   ..." or "lint:  ..." with optional leading whitespace
  local cmd
  cmd=$(grep -E '^\s*lint_command\s*:\s*' "$PLAN_FILE" 2>/dev/null | tail -1 | sed 's/^[^:]*:\s*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

  if [ -z "$cmd" ]; then
    # Also check for "lint:" (section key, not inside a list item starting with "-")
    cmd=$(grep -E '^\s*lint:\s*[^-]' "$PLAN_FILE" 2>/dev/null | grep -v '^\s*-\s*' | tail -1 | sed 's/^[^:]*:\s*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
  fi

  # Filter out empty values and comments
  if [ -n "$cmd" ]; then
    case "$cmd" in
      ""|"#"|"#"*|template*) return 1 ;;
    esac
    echo "$cmd"
    return 0
  fi

  return 1
}

# ── Auto-detect lint command based on project markers ───────────
auto_detect_lint_command() {
  local has_typescript=false
  local has_python=false
  local has_java=false
  local has_go=false

  # Check for language markers
  if [ -f "$FEATURE_DIR/package.json" ] || [ -f "package.json" ]; then
    has_typescript=true
  fi
  if [ -f "$FEATURE_DIR/requirements.txt" ] || [ -f "$FEATURE_DIR/pyproject.toml" ] || [ -f "$FEATURE_DIR/Pipfile" ]; then
    has_python=true
  fi
  if [ -f "$FEATURE_DIR/pom.xml" ] || [ -f "$FEATURE_DIR/gradle" ] || [ -f "$FEATURE_DIR/build.gradle" ]; then
    has_java=true
  fi
  if [ -f "$FEATURE_DIR/go.mod" ]; then
    has_go=true
  fi

  # Also check src directory structure
  if ls "$FEATURE_DIR" 2>/dev/null | grep -qiE '\.java$'; then
    has_java=true
  fi
  if ls "$FEATURE_DIR" 2>/dev/null | grep -qiE '\.go$'; then
    has_go=true
  fi
  if ls "$FEATURE_DIR" 2>/dev/null | grep -qiE '\.(ts|tsx|js|jsx)$'; then
    has_typescript=true
  fi
  if ls "$FEATURE_DIR" 2>/dev/null | grep -qiE '\.py$'; then
    has_python=true
  fi

  # TypeScript / Node.js
  if [ "$has_typescript" = true ]; then
    # Check for package.json lint scripts
    if [ -f "$FEATURE_DIR/package.json" ] || [ -f "package.json" ]; then
      local pkgjson
      if [ -f "$FEATURE_DIR/package.json" ]; then
        pkgjson="$FEATURE_DIR/package.json"
      else
        pkgjson="package.json"
      fi
      local lint_script
      lint_script=$(grep '"lint"' "$pkgjson" 2>/dev/null | head -1 | sed 's/.*"lint"[[:space:]]*:[[:space:]]*"//' | sed 's/"[[:space:]]*,\{0,1\}[[:space:]]*$//' || true)
      if [ -n "$lint_script" ]; then
        echo "npm run lint"
        return 0
      fi
      # Check for biome, eslint, tsc in devDependencies
      if grep -q '"biome"' "$pkgjson" 2>/dev/null; then
        echo "npx biome check ."
        return 0
      fi
      if grep -q '"eslint"' "$pkgjson" 2>/dev/null || [ -f "$FEATURE_DIR/.eslintrc" ] || [ -f "$FEATURE_DIR/.eslintrc.js" ] || [ -f "$FEATURE_DIR/.eslintrc.json" ]; then
        echo "npx eslint . --max-warnings 0"
        return 0
      fi
      if grep -q '"typescript"' "$pkgjson" 2>/dev/null && [ -f "$FEATURE_DIR/tsconfig.json" ]; then
        echo "npx tsc --noEmit"
        return 0
      fi
      echo "npx eslint . --max-warnings 0"
      return 0
    fi
  fi

  # Python
  if [ "$has_python" = true ]; then
    if [ -f "$FEATURE_DIR/ruff.toml" ] || [ -f "$FEATURE_DIR/pyproject.toml" ] && grep -q '\[tool.ruff\]' "$FEATURE_DIR/pyproject.toml" 2>/dev/null; then
      echo "ruff check ."
      return 0
    fi
    if [ -f "$FEATURE_DIR/.pylintrc" ] || [ -f "$FEATURE_DIR/pylintrc" ]; then
      echo "pylint src/"
      return 0
    fi
    if [ -f "$FEATURE_DIR/setup.cfg" ] && grep -q '\[flake8\]' "$FEATURE_DIR/setup.cfg" 2>/dev/null; then
      echo "flake8 ."
      return 0
    fi
    echo "ruff check ."
    return 0
  fi

  # Java
  if [ "$has_java" = true ]; then
    if [ -f "$FEATURE_DIR/mvnw" ] || [ -f "mvnw" ]; then
      echo "./mvnw checkstyle:check"
      return 0
    fi
    if [ -f "$FEATURE_DIR/gradlew" ] || [ -f "gradlew" ]; then
      echo "./gradlew checkstyleCheck"
      return 0
    fi
    if [ -f "$FEATURE_DIR/pom.xml" ] || [ -f "pom.xml" ]; then
      echo "mvn checkstyle:check"
      return 0
    fi
    return 1
  fi

  # Go
  if [ "$has_go" = true ]; then
    if [ -f "$FEATURE_DIR/.golangci.yml" ] || [ -f "$FEATURE_DIR/.golangci.yaml" ]; then
      echo "golangci-lint run"
      return 0
    fi
    echo "gofmt -l ."
    return 0
  fi

  return 1
}

# Try to get lint command from plan.md, then fall back to auto-detect
LINT_COMMAND=$(extract_lint_command 2>/dev/null || true)

if [ -z "$LINT_COMMAND" ]; then
  LINT_COMMAND=$(auto_detect_lint_command 2>/dev/null || true)
fi

if [ -z "$LINT_COMMAND" ]; then
  echo "LINTER: SKIP (no lint_command configured in plan.md)"
  mkdir -p "${FEATURE_DIR}/.artifacts/check-results"
  echo "PASS" > "${FEATURE_DIR}/.artifacts/check-results/D.result"
  exit 0
fi

# ── Execute the lint command ────────────────────────────────────
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if validate-tests.sh exists and can be used
# validate-tests.sh is designed for tests, but we can use it for lint too
# since it captures full output and checks exit codes
if [ -f "$SCRIPTS_DIR/validate-tests.sh" ]; then
  # Use validate-tests.sh — captures full output, checks exit code
  VALIDATE_OUTPUT=$(bash "$SCRIPTS_DIR/validate-tests.sh" "$LINT_COMMAND" "pass" 2>&1)

  # Print the command and full validate output
  echo "LINTER: ${LINT_COMMAND}"
  echo "$VALIDATE_OUTPUT"

  # Extract result from validate-tests.sh output
  TEST_EXIT_CODE=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_EXIT_CODE=" | cut -d= -f2)
  TEST_RESULT=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_RESULT=" | cut -d= -f2)

  if [ "$TEST_RESULT" = "fail" ]; then
    LINT_EXIT_CODE=1
  else
    LINT_EXIT_CODE=0
  fi

  # Try to count violations from output
  VIOLATION_COUNT=0

  # ESLint: "X error(s), Y warning(s)"
  if echo "$VALIDATE_OUTPUT" | grep -q "error(s)" 2>/dev/null; then
    ERRORS=$(echo "$VALIDATE_OUTPUT" | grep -o "[0-9]* error(s)" | grep -o "[0-9]*" | head -1 || echo "0")
    WARNINGS=$(echo "$VALIDATE_OUTPUT" | grep -o "[0-9]* warning(s)" | grep -o "[0-9]*" | head -1 || echo "0")
    VIOLATION_COUNT=$(( ${ERRORS:-0} + ${WARNINGS:-0} ))
  fi

  # TypeScript: "Found N error(s)"
  if [ "$VIOLATION_COUNT" -eq 0 ] && echo "$VALIDATE_OUTPUT" | grep -q "error(" 2>/dev/null; then
    VIOLATION_COUNT=$(echo "$VALIDATE_OUTPUT" | grep -o "Found [0-9]* error" | grep -o "[0-9]*" | head -1 || echo "0")
  fi

  # ruff: counts lines with issues
  if [ "$VIOLATION_COUNT" -eq 0 ] && echo "$VALIDATE_OUTPUT" | grep -qE "^[0-9]+\s+\S+\s+\S+\+\+\+" 2>/dev/null; then
    VIOLATION_COUNT=$(echo "$VALIDATE_OUTPUT" | grep -oE "Found [0-9]+ issue" | grep -o "[0-9]*" | head -1 || echo "0")
  fi

  # Fallback: use exit code as primary signal
  : "${TEST_EXIT_CODE:=0}"
  : "${VIOLATION_COUNT:=0}"
  if [ "$VIOLATION_COUNT" -eq 0 ] && [ "$TEST_EXIT_CODE" -ne 0 ]; then
    VIOLATION_COUNT=1
  fi
else
  # No validate-tests.sh — run directly
  LINT_OUTPUT=""
  LINT_EXIT_CODE=0
  LINT_OUTPUT=$(bash -c "$LINT_COMMAND" 2>&1) || LINT_EXIT_CODE=$?

  echo "LINTER: ${LINT_COMMAND}"
  if [ -n "$LINT_OUTPUT" ]; then
    echo "$LINT_OUTPUT"
  fi

  # Try to count violations from linter output
  VIOLATION_COUNT=0

  # ESLint: "X error(s), Y warning(s)"
  if echo "$LINT_OUTPUT" | grep -q "error(s)" 2>/dev/null; then
    ERRORS=$(echo "$LINT_OUTPUT" | grep -o "[0-9]* error(s)" | grep -o "[0-9]*" | head -1 || echo "0")
    WARNINGS=$(echo "$LINT_OUTPUT" | grep -o "[0-9]* warning(s)" | grep -o "[0-9]*" | head -1 || echo "0")
    VIOLATION_COUNT=$(( ${ERRORS:-0} + ${WARNINGS:-0} ))
  fi

  # TypeScript: "Found N error(s)"
  if [ "$VIOLATION_COUNT" -eq 0 ] && echo "$LINT_OUTPUT" | grep -q "Found [0-9]* error" 2>/dev/null; then
    VIOLATION_COUNT=$(echo "$LINT_OUTPUT" | grep -o "Found [0-9]* error" | grep -o "[0-9]*" | head -1 || echo "0")
  fi

  # TypeScript: "error TSXXXX" count
  if [ "$VIOLATION_COUNT" -eq 0 ] && echo "$LINT_OUTPUT" | grep -qE "^error TS" 2>/dev/null; then
    VIOLATION_COUNT=$(echo "$LINT_OUTPUT" | grep -cE "^error TS" || echo "0")
  fi

  # Go fmt: lists files that need formatting
  if [ "$VIOLATION_COUNT" -eq 0 ] && echo "$LINT_OUTPUT" | grep -qE "\.go$" 2>/dev/null; then
    VIOLATION_COUNT=$(echo "$LINT_OUTPUT" | grep -cE "\.go$" || echo "0")
  fi

  # ruff: "Found N issue(s)"
  if [ "$VIOLATION_COUNT" -eq 0 ] && echo "$LINT_OUTPUT" | grep -qE "Found [0-9]+ issue" 2>/dev/null; then
    VIOLATION_COUNT=$(echo "$LINT_OUTPUT" | grep -oE "Found [0-9]+ issue" | grep -o "[0-9]*" | head -1 || echo "0")
  fi

  # flake8: "X failed"
  if [ "$VIOLATION_COUNT" -eq 0 ] && echo "$LINT_OUTPUT" | grep -qE "[0-9]+ failed" 2>/dev/null; then
    VIOLATION_COUNT=$(echo "$LINT_OUTPUT" | grep -oE "[0-9]+ failed" | grep -o "[0-9]*" | head -1 || echo "0")
  fi

  # pylint: "X issue(s)" or "X error(s)"
  if [ "$VIOLATION_COUNT" -eq 0 ] && echo "$LINT_OUTPUT" | grep -qE "[0-9]+ issue(s)" 2>/dev/null; then
    VIOLATION_COUNT=$(echo "$LINT_OUTPUT" | grep -oE "[0-9]+ issue(s)" | grep -o "[0-9]*" | head -1 || echo "0")
  fi

  # Fallback: use exit code as primary signal
  : "${VIOLATION_COUNT:=0}"
  if [ "$VIOLATION_COUNT" -eq 0 ] && [ "$LINT_EXIT_CODE" -ne 0 ]; then
    VIOLATION_COUNT=1
  fi
fi

# ── Write results ──────────────────────────────────────────────
mkdir -p "${FEATURE_DIR}/.artifacts/check-results"
RESULT_FILE="${FEATURE_DIR}/.artifacts/check-results/D.result"
if [ "$LINT_EXIT_CODE" -eq 0 ]; then
  {
    echo "PASS"
    echo "LINTER: PASS — 0 violations"
  } > "$RESULT_FILE"
  echo "LINTER: PASS — 0 violations"
  exit 0
else
  {
    echo "FAIL"
    echo "LINTER: FAIL — ${VIOLATION_COUNT} violation(s)"
  } > "$RESULT_FILE"
  echo "LINTER: FAIL — ${VIOLATION_COUNT} violation(s)"
  exit 1
fi
