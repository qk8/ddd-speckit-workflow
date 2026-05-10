#!/usr/bin/env bash
# verify-code-quality.sh — Deterministic code quality gates
#
# Usage: bash scripts/verify-code-quality.sh <feature_dir> [source_dir]
#
# Scans source files for quality violations:
#   MAX_FUNC_LINES  — function/method body too long
#   MAX_FILE_LINES  — file too long
#   MAX_NESTING     — nesting depth too deep
#   MAX_PARAMS      — too many function parameters
#   MAX_CLASS_METHODS — class has too many public methods
#   MAX_CYCLOMATIC  — cyclomatic complexity too high (basic count)
#
# Output format (machine-parseable):
#   VIOLATION: [file]:[line] [metric] [actual] > [threshold] — [detail]
#   SUMMARY: [N] violations found ([N] files affected)
# Exit code: 0 = no violations, 1 = violations found

set -euo pipefail

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_DIR" ]; then
  echo "CODE QUALITY: SKIP (no feature directory)"
  exit 0
fi

SOURCE_DIR="${2:-}"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_FILE="$ARTIFACTS_DIR/code-quality-results.txt"
mkdir -p "$ARTIFACTS_DIR"

# Load thresholds
# shellcheck source=code-quality-thresholds.sh
source "$(dirname "$0")/code-quality-thresholds.sh"

VIOLATION_COUNT=0
declare -a VIOLATION_FILES=()

# ── Detect language from source files ──────────────────────────
detect_lang() {
  local dir="$1"
  if [ -f "$dir/package.json" ] || find "$dir" -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" 2>/dev/null | head -1 | grep -q .; then
    # Distinguish TS vs JS
    if find "$dir" -name "*.ts" -o -name "*.tsx" 2>/dev/null | head -1 | grep -q .; then
      echo "ts"
    else
      echo "js"
    fi
  elif find "$dir" -name "*.py" 2>/dev/null | head -1 | grep -q .; then
    echo "python"
  elif find "$dir" -name "*.go" 2>/dev/null | head -1 | grep -q .; then
    echo "go"
  elif find "$dir" -name "*.java" 2>/dev/null | head -1 | grep -q .; then
    echo "java"
  elif find "$dir" -name "*.rb" 2>/dev/null | head -1 | grep -q .; then
    echo "ruby"
  elif find "$dir" -name "*.rs" 2>/dev/null | head -1 | grep -q .; then
    echo "rust"
  elif find "$dir" -name "*.cs" 2>/dev/null | head -1 | grep -q .; then
    echo "csharp"
  elif find "$dir" -name "*.kt" 2>/dev/null | head -1 | grep -q .; then
    echo "kotlin"
  elif find "$dir" -name "*.php" 2>/dev/null | head -1 | grep -q .; then
    echo "php"
  elif find "$dir" -name "*.swift" 2>/dev/null | head -1 | grep -q .; then
    echo "swift"
  else
    echo "default"
  fi
}

# ── Get source directory ───────────────────────────────────────
get_source_dir() {
  if [ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ]; then
    echo "$SOURCE_DIR"
    return
  fi
  # Try common locations
  for d in "$FEATURE_DIR/src" "$FEATURE_DIR/lib" "$FEATURE_DIR/app" "$FEATURE_DIR/pkg"; do
    if [ -d "$d" ]; then
      # Check if it contains source files
      if find "$d" -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rb" -o -name "*.rs" -o -name "*.cs" -o -name "*.kt" -o -name "*.php" -o -name "*.swift" 2>/dev/null | head -1 | grep -q .; then
        echo "$d"
        return
      fi
    fi
  done
  # Fallback: search feature dir recursively
  local found
  found=$(find "$FEATURE_DIR" -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rb" -o -name "*.rs" -o -name "*.cs" -o -name "*.kt" -o -name "*.php" -o -name "*.swift" 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    echo "$(dirname "$found")"
  else
    echo ""
  fi
}

# ── Record a violation ─────────────────────────────────────────
record_violation() {
  local file="$1"
  local line="$2"
  local metric="$3"
  local actual="$4"
  local threshold="$5"
  local detail="$6"
  echo "VIOLATION: $file:$line $metric $actual > $threshold — $detail" >> "$RESULTS_FILE"
  VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
  # Track unique files
  local found=false
  for f in "${VIOLATION_FILES[@]+"${VIOLATION_FILES[@]}"}"; do
    if [ "$f" = "$file" ]; then
      found=true
      break
    fi
  done
  if [ "$found" = false ]; then
    VIOLATION_FILES+=("$file")
  fi
}

# ── Check 1: File length ──────────────────────────────────────
check_file_length() {
  local file="$1"
  local lang="$2"
  local threshold
  threshold=$(resolve_threshold FILE_LINES "$lang")
  local lines
  lines=$(wc -l < "$file" 2>/dev/null || echo 0)
  if [ "$lines" -gt "$threshold" ]; then
    record_violation "$file" 0 "MAX_FILE_LINES" "$lines" "$threshold" "File has $lines lines (max $threshold)"
  fi
}

# ── Check 2: Function length (AWK-based) ──────────────────────
check_function_length() {
  local file="$1"
  local lang="$2"
  local threshold
  threshold=$(resolve_threshold FUNC_LINES "$lang")
  local ext="${file##*.}"

  case "$ext" in
    ts|js|java|c|cpp|cs|kt|scala|php|swift|go|rs)
      # C-family: count lines between { and matching }
      awk -v threshold="$threshold" -v fname="$file" '
        BEGIN { in_func=0; func_start=0; brace_count=0; func_name="" }
        {
          # Detect function/method start (simplified: line with "function ", "def ", "func ", "public ", "private ", "protected ", "static ")
          is_func_start = 0
          line = $0
          if (match(line, /function[[:space:]]+[a-zA-Z_]/)) is_func_start = 1
          if (match(line, /public[[:space:]]+[a-zA-Z_]/) && match(line, /\(/)) is_func_start = 1
          if (match(line, /private[[:space:]]+[a-zA-Z_]/) && match(line, /\(/)) is_func_start = 1
          if (match(line, /protected[[:space:]]+[a-zA-Z_]/) && match(line, /\(/)) is_func_start = 1
          if (match(line, /static[[:space:]]+[a-zA-Z_]/) && match(line, /\(/)) is_func_start = 1
          if (match(line, /^[[:space:]]*(async[[:space:]]+)?function[[:space:]]/) ) is_func_start = 1
          if (match(line, /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(/) && match(line, /\)[[:space:]]*\{?[[:space:]]*$/) && !match(line, /if[[:space:]]*\(/) && !match(line, /while[[:space:]]*\(/) && !match(line, /for[[:space:]]*\(/) && !match(line, /switch[[:space:]]*\(/) && !match(line, /catch[[:space:]]*\(/) && !match(line, /class[[:space:]]/) && !match(line, /interface[[:space:]]/) && !match(line, /enum[[:space:]]/) && !match(line, /struct[[:space:]]/)) is_func_start = 1

          if (is_func_start && !in_func) {
            in_func = 1
            func_start = NR
            brace_count = 0
            func_name = line
            gsub(/^[[:space:]]+/, "", func_name)
            gsub(/[[:space:]].*/, "", func_name)
            if (length(func_name) > 80) func_name = substr(func_name, 1, 80) "..."
          }

          if (in_func) {
            func_lines++
            n = split($0, chars, "")
            for (i = 1; i <= n; i++) {
              if (chars[i] == "{") brace_count++
              if (chars[i] == "}") brace_count--
            }
            if (brace_count <= 0 && index(func_line, "{") > 0) {
              if (func_lines > threshold) {
                printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long (%s)\n", fname, func_start, func_lines, threshold, func_name
              }
              in_func = 0
              func_lines = 0
              brace_count = 0
            }
          }
        }
      ' "$file" >> "$RESULTS_FILE" 2>/dev/null || true
      ;;
    py)
      # Python: count lines between def/dedent
      awk -v threshold="$threshold" -v fname="$file" '
        BEGIN { in_func=0; func_start=0; func_lines=0; indent_level=0 }
        /^[[:space:]]*def[[:space:]]/ {
          if (in_func && func_lines > threshold) {
            printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long\n", fname, func_start, func_lines, threshold
          }
          in_func = 1
          func_start = NR
          func_lines = 1
          indent_level = 0
          match($0, /^[[:space:]]*/)
          indent_level = RLENGTH
          next
        }
        in_func {
          func_lines++
          if (NR > func_start) {
            line = $0
            if (line ~ /^[^[:space:]]/ && line !~ /^[[:space:]]*#/ && line !~ /^[[:space:]]*"/) {
              if (func_lines > threshold) {
                printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long\n", fname, func_start, func_lines, threshold
              }
              in_func = 0
            }
          }
        }
        END {
          if (in_func && func_lines > threshold) {
            printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long\n", fname, func_start, func_lines, threshold
          }
        }
      ' "$file" >> "$RESULTS_FILE" 2>/dev/null || true
      ;;
    rb)
      # Ruby: count lines between def/end
      awk -v threshold="$threshold" -v fname="$file" '
        BEGIN { in_func=0; func_start=0; func_lines=0; brace_depth=0 }
        /^[[:space:]]*(def[[:space:]]|def\b)/ {
          if (in_func && func_lines > threshold) {
            printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long\n", fname, func_start, func_lines, threshold
          }
          in_func = 1
          func_start = NR
          func_lines = 1
          next
        }
        in_func {
          func_lines++
          if ($0 ~ /^[[:space:]]*(end|else|elsif|rescue|ensure)[[:space:]]*$/) {
            if (func_lines > threshold) {
              printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long\n", fname, func_start, func_lines, threshold
            }
            in_func = 0
          }
        }
        END {
          if (in_func && func_lines > threshold) {
            printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long\n", fname, func_start, func_lines, threshold
          }
        }
      ' "$file" >> "$RESULTS_FILE" 2>/dev/null || true
      ;;
    go)
      # Go: count lines between func and matching brace
      awk -v threshold="$threshold" -v fname="$file" '
        BEGIN { in_func=0; func_start=0; func_lines=0; brace_count=0 }
        /func[[:space:]]+/ {
          if (in_func && func_lines > threshold) {
            printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long\n", fname, func_start, func_lines, threshold
          }
          in_func = 1
          func_start = NR
          func_lines = 1
          brace_count = 0
          next
        }
        in_func {
          func_lines++
          n = split($0, chars, "")
          for (i = 1; i <= n; i++) {
            if (chars[i] == "{") brace_count++
            if (chars[i] == "}") brace_count--
          }
          if (brace_count <= 0) {
            if (func_lines > threshold) {
              printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long\n", fname, func_start, func_lines, threshold
            }
            in_func = 0
          }
        }
        END {
          if (in_func && func_lines > threshold) {
            printf "VIOLATION: %s:%d MAX_FUNC_LINES %d > %d — function too long\n", fname, func_start, func_lines, threshold
          }
        }
      ' "$file" >> "$RESULTS_FILE" 2>/dev/null || true
      ;;
  esac
}

# ── Check 3: Nesting depth ────────────────────────────────────
check_nesting_depth() {
  local file="$1"
  local lang="$2"
  local threshold
  threshold=$(resolve_threshold NESTING "$lang")
  local ext="${file##*.}"

  case "$ext" in
    ts|js|java|c|cpp|cs|kt|scala|php|swift|go|rs|py|rb)
      awk -v threshold="$threshold" -v fname="$file" '
        {
          depth = 0
          n = split($0, chars, "")
          for (i = 1; i <= n; i++) {
            if (chars[i] == "{") depth++
            if (chars[i] == "}") depth--
          }
          if (depth > threshold) {
            printf "VIOLATION: %s:%d MAX_NESTING %d > %d — nesting too deep\n", fname, NR, depth, threshold
          }
        }
      ' "$file" >> "$RESULTS_FILE" 2>/dev/null || true
      ;;
  esac
}

# ── Check 4: Parameter count ──────────────────────────────────
check_param_count() {
  local file="$1"
  local lang="$2"
  local threshold
  threshold=$(resolve_threshold PARAMS "$lang")
  local ext="${file##*.}"

  # Find function signatures with too many parameters
  # Pattern: ( arg1, arg2, ..., argN ) where N > threshold
  grep -n 'function\|def \|func \|public \|private \|protected \|static ' "$file" 2>/dev/null | while IFS= read -r line; do
    linenum=$(echo "$line" | cut -d: -f1)
    content=$(echo "$line" | cut -d: -f2-)

    # Extract the parameter list — find matching parentheses
    # Count commas inside the first ( ) pair after the function name
    param_count=0
    if echo "$content" | grep -q '('; then
      # Extract text between first ( and its matching )
      param_text=$(echo "$content" | sed 's/.*(\(.*\)).*/\1/' 2>/dev/null || echo "")
      if [ -n "$param_text" ] && [ "$param_text" != "$content" ]; then
        param_count=$(echo "$param_text" | tr ',' '\n' | grep -c '[a-zA-Z_]' 2>/dev/null || echo 0)
      fi
      # Also handle multi-line: grab up to next )
      if [ "$param_count" -le "$threshold" ]; then
        multi_line=$(sed -n "${linenum},$((linenum+5))p" "$file" 2>/dev/null | tr '\n' ' ' | sed 's/.*(\(.*\)).*/\1/' 2>/dev/null || echo "")
        if [ -n "$multi_line" ] && [ "$multi_line" != "$(sed -n "${linenum}p" "$file" 2>/dev/null)" ]; then
          param_count=$(echo "$multi_line" | tr ',' '\n' | grep -c '[a-zA-Z_]' 2>/dev/null || echo 0)
        fi
      fi
    fi

    if [ "$param_count" -gt "$threshold" ]; then
      echo "VIOLATION: $file:$linenum MAX_PARAMS $param_count > $threshold — too many parameters" >> "$RESULTS_FILE"
    fi
  done || true
}

# ── Check 5: Class method count ───────────────────────────────
check_class_methods() {
  local file="$1"
  local lang="$2"
  local threshold
  threshold=$(resolve_threshold CLASS_METHODS "$lang")
  local ext="${file##*.}"

  case "$ext" in
    ts|js|java|c|cpp|cs|kt|scala|php|swift|go|rs)
      # Count method declarations within class bodies
      awk -v threshold="$threshold" -v fname="$file" '
        BEGIN { in_class=0; method_count=0; brace_depth=0 }
        /class[[:space:]]+[A-Z]/ {
          in_class = 1
          method_count = 0
          brace_depth = 0
        }
        in_class {
          n = split($0, chars, "")
          for (i = 1; i <= n; i++) {
            if (chars[i] == "{") brace_depth++
            if (chars[i] == "}") brace_depth--
          }
          # Count method-like declarations (not constructor, not { or })
          if ($0 ~ /(public|private|protected|static|async)[[:space:]]+[a-zA-Z_]/) {
            method_count++
          } else if ($0 ~ /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(/ && $0 !~ /(if|while|for|switch|catch|return)[[:space:]]*\(/) {
            method_count++
          }
          if (brace_depth <= 0 && in_class) {
            if (method_count > threshold) {
              printf "VIOLATION: %s:0 MAX_CLASS_METHODS %d > %d — class has too many methods\n", fname, method_count, threshold
            }
            in_class = 0
          }
        }
      ' "$file" >> "$RESULTS_FILE" 2>/dev/null || true
      ;;
  esac
}

# ── Check 6: Basic cyclomatic complexity ──────────────────────
check_cyclomatic_complexity() {
  local file="$1"
  local lang="$2"
  local threshold
  threshold=$(resolve_threshold CYCLOMATIC "$lang")
  local ext="${file##*.}"

  # Count decision points per function: if, else if, for, while, case, catch, &&, ||, ?
  # This is a rough approximation — not a full CFG analysis
  case "$ext" in
    ts|js|java|c|cpp|cs|kt|scala|php|swift|go|rs|py|rb)
      awk -v threshold="$threshold" -v fname="$file" '
        BEGIN { in_func=0; func_start=0; complexity=0 }
        {
          line = $0
          # Count decision keywords
          n_if = gsub(/if[[:space:]]*\(/, "if", line)
          line = $0
          n_else_if = gsub(/else[[:space:]]+if/, "else_if", line)
          line = $0
          n_for = gsub(/for[[:space:]]*\(/, "for", line)
          line = $0
          n_while = gsub(/while[[:space:]]*\(/, "while", line)
          line = $0
          n_case = gsub(/case[[:space:]]/, "case", line)
          line = $0
          n_catch = gsub(/catch[[:space:]]*\(/, "catch", line)
          line = $0
          n_and = gsub(/&&/, "&&", line)
          line = $0
          n_or = gsub(/\|\|/, "||", line)
          line = $0
          n_question = gsub(/\?/, "?", line)

          decisions = n_if + n_else_if + n_for + n_while + n_case + n_catch + n_and + n_or + n_question
          if (decisions > 0) {
            # Rough: if we see decisions, we might be in a function
            # Track function scope roughly
            if ($0 ~ /(function|def |func |public |private |protected |static )[[:space:]]/) {
              in_func = 1
              func_start = NR
              complexity = decisions + 1  # base complexity = 1
            } else if (in_func) {
              complexity += decisions
            }
          }

          # End of function (simplified: closing brace at low depth)
          if (in_func && $0 ~ /^[[:space:]]*\}/) {
            if (complexity > threshold) {
              printf "VIOLATION: %s:%d MAX_CYCLOMATIC %d > %d — complexity too high\n", fname, func_start, complexity, threshold
            }
            in_func = 0
            complexity = 0
          }
        }
      ' "$file" >> "$RESULTS_FILE" 2>/dev/null || true
      ;;
  esac
}

# ── Main ───────────────────────────────────────────────────────
> "$RESULTS_FILE"  # Clear results

if [ -z "$SOURCE_DIR" ]; then
  SOURCE_DIR=$(get_source_dir)
fi

if [ -z "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR" ]; then
  echo "CODE QUALITY: SKIP (no source directory found)"
  echo "SUMMARY: 0 violations found (0 files affected)"
  exit 0
fi

LANG=$(detect_lang "$SOURCE_DIR")
echo "CODE QUALITY: Scanning $SOURCE_DIR (lang=$LANG)"

# Print thresholds being used
echo "  MAX_FUNC_LINES=$(resolve_threshold FUNC_LINES "$LANG")"
echo "  MAX_FILE_LINES=$(resolve_threshold FILE_LINES "$LANG")"
echo "  MAX_NESTING=$(resolve_threshold NESTING "$LANG")"
echo "  MAX_PARAMS=$(resolve_threshold PARAMS "$LANG")"
echo "  MAX_CLASS_METHODS=$(resolve_threshold CLASS_METHODS "$LANG")"
echo "  MAX_CYCLOMATIC=$(resolve_threshold CYCLOMATIC "$LANG")"

# Find and scan source files
FILE_COUNT=0
find "$SOURCE_DIR" -type f \( \
  -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
  -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rb" \
  -o -name "*.rs" -o -name "*.cs" -o -name "*.kt" -o -name "*.php" \
  -o -name "*.swift" \
\) -not -path "*/node_modules/*" -not -path "*/.artifacts/*" -not -path "*/dist/*" -not -path "*/build/*" -not -path "*/__tests__/*" -not -path "*/test/*" -not -path "*/tests/*" -not -path "*/spec/*" 2>/dev/null | while IFS= read -r file; do
  FILE_COUNT=$((FILE_COUNT + 1))

  check_file_length "$file" "$LANG"
  check_function_length "$file" "$LANG"
  check_nesting_depth "$file" "$LANG"
  check_param_count "$file" "$LANG"
  check_class_methods "$file" "$LANG"
  check_cyclomatic_complexity "$file" "$LANG"
done

# Count results
if [ -f "$RESULTS_FILE" ] && [ -s "$RESULTS_FILE" ]; then
  VIOLATION_COUNT=$(grep -c '^VIOLATION:' "$RESULTS_FILE" 2>/dev/null || echo 0)
  AFFECTED_FILES=$(grep '^VIOLATION:' "$RESULTS_FILE" 2>/dev/null | sed 's/VIOLATION: \([^:]*\).*/\1/' | sort -u | wc -l | tr -d ' ')
else
  VIOLATION_COUNT=0
  AFFECTED_FILES=0
fi

echo "SUMMARY: $VIOLATION_COUNT violations found ($AFFECTED_FILES files affected)"

# Save results for check-runner.sh
cp "$RESULTS_FILE" "$ARTIFACTS_DIR/check-results/V.result" 2>/dev/null || true

# ── Complexity metrics logging (for trend tracking) ─────────────
METRICS_DIR="$ARTIFACTS_DIR/complexity-logs"
mkdir -p "$METRICS_DIR"

# Extract task_id from environment or use placeholder
METRICS_TASK_ID="${TASK_ID:-task}"

# Count LOC by layer
LOC_BY_LAYER=""
for layer_dir in "$SOURCE_DIR"/domain "$SOURCE_DIR"/infra "$SOURCE_DIR"/api "$SOURCE_DIR"/frontend; do
  if [ -d "$layer_dir" ]; then
    layer_name=$(basename "$layer_dir")
    layer_loc=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
    LOC_BY_LAYER="${LOC_BY_LAYER}${layer_name}:${layer_loc}|"
  fi
done

# Count files by layer
FILE_COUNT_BY_LAYER=""
for layer_dir in "$SOURCE_DIR"/domain "$SOURCE_DIR"/infra "$SOURCE_DIR"/api "$SOURCE_DIR"/frontend; do
  if [ -d "$layer_dir" ]; then
    layer_name=$(basename "$layer_dir")
    layer_files=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) 2>/dev/null | wc -l | tr -d ' ')
    FILE_COUNT_BY_LAYER="${FILE_COUNT_BY_LAYER}${layer_name}:${layer_files}|"
  fi
done

# Total LOC
TOTAL_LOC=$(find "$SOURCE_DIR" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rb" -o -name "*.rs" \) -not -path '*/node_modules/*' -not -path '*/.artifacts/*' -not -path '*/dist/*' -not -path '*/build/*' -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")

# Write metrics log
echo "TASK_ID=$METRICS_TASK_ID" > "$METRICS_DIR/${METRICS_TASK_ID}.metrics"
echo "TOTAL_LOC=$TOTAL_LOC" >> "$METRICS_DIR/${METRICS_TASK_ID}.metrics"
echo "LOC_BY_LAYER=$LOC_BY_LAYER" >> "$METRICS_DIR/${METRICS_TASK_ID}.metrics"
echo "FILE_COUNT_BY_LAYER=$FILE_COUNT_BY_LAYER" >> "$METRICS_DIR/${METRICS_TASK_ID}.metrics"
echo "VIOLATION_COUNT=$VIOLATION_COUNT" >> "$METRICS_DIR/${METRICS_TASK_ID}.metrics"
echo "AFFECTED_FILES=$AFFECTED_FILES" >> "$METRICS_DIR/${METRICS_TASK_ID}.metrics"

if [ "$VIOLATION_COUNT" -gt 0 ]; then
  exit 1
else
  exit 0
fi
