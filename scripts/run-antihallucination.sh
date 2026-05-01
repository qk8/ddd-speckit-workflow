#!/usr/bin/env bash
# Anti-Hallucination Check (Check L)
# Verifies that imported modules actually exist in the project's dependency
# declarations and that HTTP endpoints match the API contract.
set -euo pipefail

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_DIR" ]; then
  echo "ANTI-HALLUCINATION CHECK: SKIPPED (no feature directory)"
  exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
ARTIFACTS_DIR="${REPO_ROOT}/.artifacts"
CHECK_RESULTS="${ARTIFACTS_DIR}/check-results"
mkdir -p "$CHECK_RESULTS"

VIOLATIONS=0
IMPORTS_SCANNED=0

# Collect all source files under FEATURE_DIR
SOURCE_FILES=""
SOURCE_FILES=$(find "$FEATURE_DIR" \( -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.java' -o -name '*.kt' -o -name '*.rb' -o -name '*.go' \) -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.git/*' -not -path '*/__pycache__/*' -not -path '*/dist/*' -not -path '*/build/*' 2>/dev/null || true)

if [ -z "$SOURCE_FILES" ]; then
  echo "ANTI-HALLUCINATION CHECK: SKIPPED (no source files in ${FEATURE_DIR})"
  exit 0
fi

# ── Load dependency names from known files ──────────────────────
# We use simple newline-separated lists (bash 3.2 compatible, no assoc arrays).
LOAD_DEPS_FROM_PACKAGE_JSON() {
  # Extract names from dependencies and devDependencies in package.json
  local pkg="${REPO_ROOT}/package.json"
  if [ -f "$pkg" ]; then
    # Use sed to extract keys from dependencies/devDependencies blocks
    sed -n '/"dependencies"[[:space:]]*:/,/^  \}/p' "$pkg" 2>/dev/null | \
      grep -oE '"[^"]+"\s*:' | sed 's/"//g; s/://; s/[[:space:]]//g' || true
    sed -n '/"devDependencies"[[:space:]]*:/,/^  \}/p' "$pkg" 2>/dev/null | \
      grep -oE '"[^"]+"\s*:' | sed 's/"//g; s/://; s/[[:space:]]//g' || true
  fi
}

LOAD_DEPS_FROM_REQUIREMENTS_TXT() {
  local req="${REPO_ROOT}/requirements.txt"
  if [ -f "$req" ]; then
    grep -vE '^\s*#|^\s*$|^\s*-' "$req" 2>/dev/null | sed 's/[>=<!].*//' | sed 's/[[:space:]]//g' | sort -u || true
  fi
}

LOAD_DEPS_FROM_PYPROJECT_TOML() {
  local pyproject="${REPO_ROOT}/pyproject.toml"
  if [ -f "$pyproject" ]; then
    # Extract packages under [project.dependencies]
    if grep -q '\[project\.dependencies\]' "$pyproject" 2>/dev/null; then
      sed -n '/\[project\.dependencies\]/,/\[/p' "$pyproject" 2>/dev/null | \
        grep -oE '"[^"]+"' | sed 's/"//g; s/[>=<!=].*//' | sed 's/[[:space:]]//g' || true
    fi
    # Also check [tool.poetry.dependencies]
    if grep -q '\[tool\.poetry\.dependencies\]' "$pyproject" 2>/dev/null; then
      sed -n '/\[tool\.poetry\.dependencies\]/,/\[/p' "$pyproject" 2>/dev/null | \
        grep -oE '"[^"]+"' | sed 's/"//g; s/:.*//' | sed 's/[[:space:]]//g' | grep -v 'python' || true
    fi
  fi
}

LOAD_DEPS_FROM_CARGO_TOML() {
  local cargo="${REPO_ROOT}/Cargo.toml"
  if [ -f "$cargo" ]; then
    # Extract under [dependencies]
    if grep -q '\[dependencies\]' "$cargo" 2>/dev/null; then
      sed -n '/\[dependencies\]/,/\[/p' "$cargo" 2>/dev/null | \
        grep -oE '^[a-zA-Z0-9_-]+' | sed 's/[[:space:]]//g' || true
    fi
  fi
}

DEPS=""
if [ -f "${REPO_ROOT}/package.json" ]; then
  DEPS=$(LOAD_DEPS_FROM_PACKAGE_JSON | sort -u)
elif [ -f "${REPO_ROOT}/requirements.txt" ]; then
  DEPS=$(LOAD_DEPS_FROM_REQUIREMENTS_TXT | sort -u)
elif [ -f "${REPO_ROOT}/pyproject.toml" ]; then
  DEPS=$(LOAD_DEPS_FROM_PYPROJECT_TOML | sort -u)
elif [ -f "${REPO_ROOT}/Cargo.toml" ]; then
  DEPS=$(LOAD_DEPS_FROM_CARGO_TOML | sort -u)
fi

# ── Helper: check if a package name is in the deps list ────────
# Bash 3.2 compatible: simple grep against the newline-separated list.
PACKAGE_IS_IN_DEPS() {
  local pkg="$1"
  # Strip version specifiers, scoped packages (handle @scope/pkg)
  local clean
  clean=$(echo "$pkg" | sed 's/@\([^/]*\)\/\(.*\)/\1\/\2/' | sed 's/[>=<!=~^].*//')
  echo "$DEPS" | grep -qxF "$clean" 2>/dev/null
}

# ── Helper: check if a relative import path resolves ───────────
RELATIVE_IMPORT_EXISTS() {
  local from_file="$1"
  local import_path="$2"
  local dir
  dir=$(dirname "$from_file")
  # Resolve .. and .
  local resolved
  resolved=$(cd "$dir" 2>/dev/null && cd "$(dirname "$import_path")" 2>/dev/null && pwd)/$(basename "$import_path")
  [ -f "$resolved" ] && return 0
  # Try with common extensions
  for ext in "" ".ts" ".js" ".tsx" ".jsx" ".py" ".java" ".kt" ".rb" ".go" "/index.ts" "/index.js" "/index.py" "/index.java" "/__init__.py"; do
    if [ -f "${resolved}${ext}" ]; then
      return 0
    fi
  done
  return 1
}

# ── Check 1: Import resolution against dependency declarations ──
check_imports() {
  local file="$1"
  local ext="${file##*.}"
  local line_num=""
  local line_content=""

  case "$ext" in
    ts|js)
      while IFS= read -r match; do
        [ -z "$match" ] && continue
        IMPORTS_SCANNED=$((IMPORTS_SCANNED + 1))
        # Extract module name: from 'module', require('module'), import 'module'
        local mod
        mod=$(echo "$match" | sed -E "s/.*from ['\"]([^'\"]+)['\"].*/\1/" | sed -E "s/.*require\s*\(\s*['\"]([^'\"]+)['\"].*/\1/" | sed -E "s/.*import ['\"]([^'\"]+)['\"].*/\1/")

        # Check if line matches an import/require
        if echo "$match" | grep -qE "from ['\"]|require\s*\(|from ['\"]" 2>/dev/null; then
          # Get line number
          local lnum
          lnum=$(grep -n "$match" "$file" 2>/dev/null | head -1 | cut -d: -f1 || echo "?")

          # Relative import?
          if echo "$mod" | grep -qE '^\.\.?/'; then
            if ! RELATIVE_IMPORT_EXISTS "$file" "$mod"; then
              echo "  VIOLATION: ${file}:${lnum} imports '${mod}' — relative path does not resolve"
              VIOLATIONS=$((VIOLATIONS + 1))
            fi
          else
            # Package import — check dependencies
            # Get the top-level package name (strip scope, strip subpath)
            local top_pkg
            top_pkg=$(echo "$mod" | sed -E 's/^(@[^/]+\/[^/]+)/\1/' | sed -E 's/^(.*\/).*/\1/' | sed 's:/$::')
            # Keep scoped packages intact
            if echo "$mod" | grep -qE '^@'; then
              top_pkg=$(echo "$mod" | sed -E 's/^(@[^/]+\/[^/]+).*/\1/')
            fi

            if [ "$top_pkg" != "$mod" ] && ! PACKAGE_IS_IN_DEPS "$mod"; then
              # It's a subpath — check the top-level package
              if ! PACKAGE_IS_IN_DEPS "$top_pkg"; then
                echo "  VIOLATION: ${file}:${lnum} imports '${mod}' — not in dependencies"
                VIOLATIONS=$((VIOLATIONS + 1))
              fi
            elif [ "$top_pkg" = "$mod" ] && ! PACKAGE_IS_IN_DEPS "$mod"; then
              echo "  VIOLATION: ${file}:${lnum} imports '${mod}' — not in dependencies"
              VIOLATIONS=$((VIOLATIONS + 1))
            fi
          fi
        fi
      done < <(grep -nE "from ['\"].*['\"]|require\s*\(['\"].*['\"]\)|import ['\"].*['\"]" "$file" 2>/dev/null || true)
      ;;

    py)
      while IFS= read -r match; do
        [ -z "$match" ] && continue
        IMPORTS_SCANNED=$((IMPORTS_SCANNED + 1))

        local mod=""
        local lnum
        lnum=$(echo "$match" | cut -d: -f1)
        local content
        content=$(echo "$match" | cut -d: -f2-)

        # from X.Y.Z import ... — top-level is X
        # import X.Y.Z — top-level is X
        mod=$(echo "$content" | sed -E 's/^from ([a-zA-Z_][a-zA-Z0-9_]*).*/\1/' | sed -E 's/^import ([a-zA-Z_][a-zA-Z0-9_]*).*/\1/' | sed -E 's/^import\s+//' | sed 's/\..*//' | sed 's/\s.*//')

        if [ -n "$mod" ] && [ "$mod" != "$content" ]; then
          # Skip stdlib/common patterns by checking deps
          if ! PACKAGE_IS_IN_DEPS "$mod"; then
            # Could be stdlib, or could be hallucinated
            # Flag it only if the project has a deps file
            if [ -n "$DEPS" ]; then
              echo "  VIOLATION: ${file}:${lnum} imports '${mod}' — not in dependencies"
              VIOLATIONS=$((VIOLATIONS + 1))
            fi
          fi
        fi
      done < <(grep -nE '^\s*(import |from [a-zA-Z_][a-zA-Z0-9_]* )' "$file" 2>/dev/null || true)
      ;;

    java)
      while IFS= read -r match; do
        [ -z "$match" ] && continue
        IMPORTS_SCANNED=$((IMPORTS_SCANNED + 1))

        local lnum
        lnum=$(echo "$match" | cut -d: -f1)
        local content
        content=$(echo "$match" | cut -d: -f2-)

        # import com.example.pkg — check top-level
        local mod
        mod=$(echo "$content" | sed -E 's/^\s*import\s+static\s+//' | sed -E 's/^\s*import\s+//' | sed -E 's/\.[*;].*//' | awk '{print $NF}' | cut -d. -f1)

        if [ -n "$mod" ] && [ "$mod" != "import" ] && [ "$mod" != "static" ]; then
          # Java imports are typically fully qualified; for this check
          # we only verify against deps if the top-level org/package matches
          # Most Java projects use Maven/Gradle — check if top-level is in deps
          if [ -n "$DEPS" ] && ! PACKAGE_IS_IN_DEPS "$mod"; then
            echo "  VIOLATION: ${file}:${lnum} imports '${mod}' — not in dependencies"
            VIOLATIONS=$((VIOLATIONS + 1))
          fi
        fi
      done < <(grep -nE '^\s*import\s+' "$file" 2>/dev/null || true)
      ;;
  esac
}

# ── Check 2: API contract endpoint verification ────────────────
check_api_contract() {
  # Find the first api-contract.yaml in any feature subdirectory
  local contract=""
  contract=$(find "$FEATURE_DIR" -name "api-contract.yaml" -o -name "api-contract.yml" 2>/dev/null | head -1 || true)

  if [ -z "$contract" ] || [ ! -f "$contract" ]; then
    return
  fi

  # Extract path+method pairs from the contract
  # Expected format:
  # /path/to/endpoint:
  #   get:
  #   post:
  local contract_endpoints=""
  local current_path=""
  local methods="get post put delete patch head options"

  while IFS= read -r line; do
    # Skip comments and empty lines
    echo "$line" | grep -qE '^\s*#' && continue
    echo "$line" | grep -qE '^\s*$' && continue

    # Check if this is a path (starts with /, indented, with colon)
    if echo "$line" | grep -qE '^\s+/\S.*:\s*$'; then
      current_path=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/:[[:space:]]*$//')
      continue
    fi

    # Check if this is a method under the current path
    if [ -n "$current_path" ]; then
      for method in $methods; do
        if echo "$line" | grep -qE "^[[:space:]]+${method}:"; then
          local method_upper
          method_upper=$(echo "$method" | tr '[:lower:]' '[:upper:]')
          contract_endpoints="${contract_endpoints}${current_path}|${method_upper}"$'\n'
          break
        fi
      done
    fi
  done < "$contract"

  # Now search source files for endpoint implementations
  # Pattern depends on framework:
  #   TypeScript/Node: @Get, @Post, @Put, @Delete, router.get, app.get, .get(
  #   Python: @app.route, @router.get, @.get, @app.post, etc.
  #   Java/Kotlin: @RestController, @GetMapping, @PostMapping, etc.

  local found_endpoints=""

  while IFS= read -r srcfile; do
    [ -f "$srcfile" ] || continue
    local sext="${srcfile##*.}"

    case "$sext" in
      ts|js)
        while IFS= read -r eline; do
          local eline_num
          eline_num=$(echo "$eline" | cut -d: -f1)
          local econtent
          econtent=$(echo "$eline" | cut -d: -f2-)

          # Decorator-style: @Get('/path'), @Post('/path'), etc.
          local epath ehttp
          epath=$(echo "$econtent" | sed -nE "s/.*@(Get|Post|Put|Delete|Patch)[[:space:]]*\(\s*['\"]([^'\"]+)['\"].*/\2/p")
          ehttp=$(echo "$econtent" | sed -nE "s/.*@(Get|Post|Put|Delete|Patch)[[:space:]]*\(\s*['\"]([^'\"]+)['\"].*/\1/p" | tr '[:lower:]' '[:upper:]')
          if [ -n "$epath" ] && [ -n "$ehttp" ]; then
            found_endpoints="${found_endpoints}${epath}|${ehttp}"$'\n'
          fi

          # Express-style: router.get('/path'), app.post('/path'), .get('/path')
          epath=$(echo "$econtent" | sed -nE "s/.*\.(get|post|put|delete|patch)\(\s*['\"]([^'\"]+)['\"].*/\2/p")
          ehttp=$(echo "$econtent" | sed -nE "s/.*\.(get|post|put|delete|patch)\(\s*['\"]([^'\"]+)['\"].*/\1/p" | tr '[:lower:]' '[:upper:]')
          if [ -n "$epath" ] && [ -n "$ehttp" ]; then
            found_endpoints="${found_endpoints}${epath}|${ehttp}"$'\n'
          fi
        done < <(grep -nE '@(Get|Post|Put|Delete|Patch)|\.(get|post|put|delete|patch)\(' "$srcfile" 2>/dev/null || true)
        ;;

      py)
        while IFS= read -r eline; do
          local eline_num
          eline_num=$(echo "$eline" | cut -d: -f1)
          local econtent
          econtent=$(echo "$eline" | cut -d: -f2-)

          # Flask-style: @app.route('/path', methods=['GET'])
          # FastAPI-style: @app.get('/path'), @router.post('/path')
          local epath ehttp
          epath=$(echo "$econtent" | sed -nE "s/.*@(get|post|put|delete|patch)\(\s*['\"]([^'\"]+)['\"].*/\2/p")
          ehttp=$(echo "$econtent" | sed -nE "s/.*@(get|post|put|delete|patch)\(\s*['\"]([^'\"]+)['\"].*/\1/p" | tr '[:lower:]' '[:upper:]')
          if [ -n "$epath" ] && [ -n "$ehttp" ]; then
            found_endpoints="${found_endpoints}${epath}|${ehttp}"$'\n'
            continue
          fi

          # Flask @app.route with methods param
          epath=$(echo "$econtent" | sed -nE "s/.*@app\.route\s*\(\s*['\"]([^'\"]+)['\"].*/\1/p")
          local methods_param
          methods_param=$(echo "$econtent" | sed -nE "s/.*methods\s*=\s*\[([^]]+)\].*/\1/p" | sed 's/["'\'' ]//g')
          if [ -n "$epath" ] && [ -n "$methods_param" ]; then
            IFS=',' read -ra method_arr <<< "$methods_param"
            for m in "${method_arr[@]}"; do
              local mu
              mu=$(echo "$m" | tr '[:lower:]' '[:upper:]')
              found_endpoints="${found_endpoints}${epath}|${mu}"$'\n'
            done
          elif [ -n "$epath" ]; then
            found_endpoints="${found_endpoints}${epath}|GET"$'\n'
          fi
        done < <(grep -nE '@app\.(route|get|post|put|delete|patch)|@router\.(get|post|put|delete|patch)|@\.get\(|@\.post\(' "$srcfile" 2>/dev/null || true)
        ;;

      java|kt)
        while IFS= read -r eline; do
          local eline_num
          eline_num=$(echo "$eline" | cut -d: -f1)
          local econtent
          econtent=$(echo "$eline" | cut -d: -f2-)

          # Spring-style: @GetMapping("/path"), @PostMapping("/path"), @RequestMapping
          local epath ehttp
          if echo "$econtent" | grep -qE '@(Get|Post|Put|Delete|Patch)Mapping'; then
            ehttp=$(echo "$econtent" | sed -nE "s/.*@(Get|Post|Put|Delete|Patch)Mapping.*/\1/p" | tr '[:lower:]' '[:upper:]' | sed 's/MAPPING//')
            epath=$(echo "$econtent" | sed -nE "s/.*@(Get|Post|Put|Delete|Patch)Mapping\s*\(\s*value\s*=\s*['\"]([^'\"]+)['\"].*/\2/p")
            if [ -z "$epath" ]; then
              epath=$(echo "$econtent" | sed -nE "s/.*@(Get|Post|Put|Delete|Patch)Mapping\s*\(\s*['\"]([^'\"]+)['\"].*/\2/p")
            fi
            if [ -n "$epath" ] && [ -n "$ehttp" ]; then
              found_endpoints="${found_endpoints}${epath}|${ehttp}"$'\n'
            fi
          fi

          # @RequestMapping
          if echo "$econtent" | grep -qE '@RequestMapping'; then
            epath=$(echo "$econtent" | sed -nE "s/.*@RequestMapping\s*\(\s*(value|path)\s*=\s*['\"]([^'\"]+)['\"].*/\2/p")
            local req_methods
            req_methods=$(echo "$econtent" | sed -nE "s/.*method\s*=\s*RequestMethod\.([A-Z]+).*/\1/p")
            if [ -n "$epath" ]; then
              if [ -n "$req_methods" ]; then
                found_endpoints="${found_endpoints}${epath}|${req_methods}"$'\n'
              else
                # Default is GET
                found_endpoints="${found_endpoints}${epath}|GET"$'\n'
              fi
            fi
          fi

          # Kotlin Anvil-style: @Get("path")
          if echo "$econtent" | grep -qE '@(Get|Post|Put|Delete|Patch)\('; then
            ehttp=$(echo "$econtent" | sed -nE "s/.*@(Get|Post|Put|Delete|Patch)\(.*/\1/p" | tr '[:lower:]' '[:upper:]')
            epath=$(echo "$econtent" | sed -nE "s/.*@(Get|Post|Put|Delete|Patch)\(\s*['\"]([^'\"]+)['\"].*/\2/p")
            if [ -n "$epath" ] && [ -n "$ehttp" ]; then
              found_endpoints="${found_endpoints}${epath}|${ehttp}"$'\n'
            fi
          fi
        done < <(grep -nE '@(Get|Post|Put|Delete|Patch)(Mapping)?|@RequestMapping' "$srcfile" 2>/dev/null || true)
        ;;
    esac
  done <<< "$SOURCE_FILES"

  # Compare: every contract endpoint must have an implementation
  while IFS= read -r ep; do
    [ -z "$ep" ] && continue
    local epath ehttp
    epath=$(echo "$ep" | cut -d'|' -f1)
    ehttp=$(echo "$ep" | cut -d'|' -f2)

    if ! echo "$found_endpoints" | grep -qF "${epath}|${ehttp}"; then
      echo "  VIOLATION: ${epath} ${ehttp} in contract has no implementation"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done <<< "$(echo "$contract_endpoints" | sort -u)"

  # Also flag: every implementation should be in the contract
  # (but only if we found at least one contract endpoint to compare against)
  if [ -n "$contract_endpoints" ]; then
    while IFS= read -r impl; do
      [ -z "$impl" ] && continue
      local ipath ihttp
      ipath=$(echo "$impl" | cut -d'|' -f1)
      ihttp=$(echo "$impl" | cut -d'|' -f2)

      if ! echo "$contract_endpoints" | grep -qF "${ipath}|${ihttp}"; then
        echo "  VIOLATION: ${ipath} ${ihttp} implemented but not in contract"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
    done <<< "$(echo "$found_endpoints" | sort -u)"
  fi
}

# ── Check 3: SQL injection — string concatenation in queries ───
check_sql_concat() {
  local file="$1"
  local ext="${file##*.}"

  case "$ext" in
    ts|js)
      # Template literal concatenation: `SELECT * FROM foo WHERE id = ${id}`
      # String concatenation in execute/query calls
      while IFS= read -r match; do
        [ -z "$match" ] && continue
        IMPORTS_SCANNED=$((IMPORTS_SCANNED + 0))  # SQL checks don't count toward imports

        local lnum
        lnum=$(echo "$match" | cut -d: -f1)

        # Detect concatenation patterns inside SQL-like strings
        if echo "$match" | grep -qiE "(query|execute|sql|exec)\s*[\(\.]" 2>/dev/null; then
          # Template literal with expression interpolation
          if echo "$match" | grep -qE '(query|execute|sql)\s*\(\s*`[^`]*\$\{' 2>/dev/null; then
            echo "  VIOLATION: ${file}:${lnum} uses string concatenation in SQL query"
            VIOLATIONS=$((VIOLATIONS + 1))
            continue
          fi
          # String concatenation with +
          if echo "$match" | grep -qiE "(query|execute|sql)\s*\(.*['\`](.*)\+.*['\`]" 2>/dev/null; then
            echo "  VIOLATION: ${file}:${lnum} uses string concatenation in SQL query"
            VIOLATIONS=$((VIOLATIONS + 1))
            continue
          fi
        fi

        # Standalone string concatenation in SQL context (multi-line pattern)
        # Look for +  followed by a variable on the next lines
        if echo "$match" | grep -qE "(query|execute|sql|SELECT|INSERT|UPDATE|DELETE)" 2>/dev/null; then
          if echo "$match" | grep -qE "'[^']*'\s*\+\s*['\"]" 2>/dev/null; then
            echo "  VIOLATION: ${file}:${lnum} uses string concatenation in SQL query"
            VIOLATIONS=$((VIOLATIONS + 1))
            continue
          fi
        fi
      done < <(grep -nE "(query|execute|sql|SELECT|INSERT|UPDATE|DELETE)" "$file" 2>/dev/null | grep -E "['\`].*\+|\\$\{" 2>/dev/null || true)
      ;;

    py)
      while IFS= read -r match; do
        [ -z "$match" ] && continue
        local lnum
        lnum=$(echo "$match" | cut -d: -f1)

        if echo "$match" | grep -qiE "(execute|executemany|query)\s*\(.*['\"](.*\+.*['\"])" 2>/dev/null; then
          echo "  VIOLATION: ${file}:${lnum} uses string concatenation in SQL query"
          VIOLATIONS=$((VIOLATIONS + 1))
          continue
        fi
        # f-string in execute
        if echo "$match" | grep -qE "(execute|executemany)\s*\(.*f['\"]" 2>/dev/null; then
          echo "  VIOLATION: ${file}:${lnum} uses string concatenation in SQL query"
          VIOLATIONS=$((VIOLATIONS + 1))
          continue
        fi
        # format() or .format() in SQL
        if echo "$match" | grep -qE "(SELECT|INSERT|UPDATE|DELETE).*\.(format|%s)" 2>/dev/null; then
          echo "  VIOLATION: ${file}:${lnum} uses string concatenation in SQL query"
          VIOLATIONS=$((VIOLATIONS + 1))
          continue
        fi
      done < <(grep -nE "(execute|executemany|query|SELECT|INSERT|UPDATE|DELETE)" "$file" 2>/dev/null || true)
      ;;

    java|kt)
      while IFS= read -r match; do
        [ -z "$match" ] && continue
        local lnum
        lnum=$(echo "$match" | cut -d: -f1)

        # String concatenation with + in SQL
        if echo "$match" | grep -qE "(executeQuery|executeUpdate|createStatement|PreparedStatement)" 2>/dev/null; then
          if echo "$match" | grep -qE "'[^']*'\s*\+\s*" 2>/dev/null; then
            echo "  VIOLATION: ${file}:${lnum} uses string concatenation in SQL query"
            VIOLATIONS=$((VIOLATIONS + 1))
            continue
          fi
        fi
        if echo "$match" | grep -qE "(SELECT|INSERT|UPDATE|DELETE).*['\"].*\+\s*\w" 2>/dev/null; then
          echo "  VIOLATION: ${file}:${lnum} uses string concatenation in SQL query"
          VIOLATIONS=$((VIOLATIONS + 1))
          continue
        fi
      done < <(grep -nE "(executeQuery|executeUpdate|createStatement|PreparedStatement|SELECT|INSERT|UPDATE|DELETE)" "$file" 2>/dev/null || true)
      ;;
  esac
}

# ── Main scan loop ─────────────────────────────────────────────
while IFS= read -r file; do
  [ -f "$file" ] || continue
  check_imports "$file"
  check_sql_concat "$file"
done <<< "$SOURCE_FILES"

# Run API contract check separately
check_api_contract

# ── Write results ──────────────────────────────────────────────
RESULT_FILE="${CHECK_RESULTS}/L.result"

{
  if [ "$VIOLATIONS" -gt 0 ]; then
    echo "FAIL"
  else
    echo "PASS"
  fi
  echo "ANTI-HALLUCINATION CHECK: ${IMPORTS_SCANNED} imports scanned, ${VIOLATIONS} violations"
} > "$RESULT_FILE"

# Also print to stdout
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "ANTI-HALLUCINATION CHECK: ${IMPORTS_SCANNED} imports scanned, ${VIOLATIONS} violations"
  echo "FAIL"
  exit 1
fi

echo "ANTI-HALLUCINATION CHECK: ${IMPORTS_SCANNED} imports scanned, ${VIOLATIONS} violations"
echo "PASS"
exit 0
