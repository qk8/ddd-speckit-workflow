#!/usr/bin/env bash
# complexity-baseline.sh — Establish complexity baseline at plan phase
#
# Usage: scripts/complexity-baseline.sh <feature_dir> [source_dir]
#
# Computes initial complexity metrics and writes baseline to
# .artifacts/complexity-trend.json.
#
# Bash 3.2 compatible — no jq dependency.

set -euo pipefail

FEATURE_DIR="${1:?Usage: complexity-baseline.sh <feature_dir> [source_dir]}"
SOURCE_DIR="${2:-}"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
TREND_FILE="$ARTIFACTS_DIR/complexity-trend.json"
mkdir -p "$ARTIFACTS_DIR"

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

# ── Step 1: Determine source directories ────────────────────────
if [ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ]; then
  SOURCE_DIRS="$SOURCE_DIR"
else
  SOURCE_DIRS=""
  for d in "$FEATURE_DIR/src" "$FEATURE_DIR/lib" "$FEATURE_DIR/app" "$FEATURE_DIR/pkg"; do
    if [ -d "$d" ]; then
      if find "$d" -maxdepth 3 -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) 2>/dev/null | head -1 | grep -q .; then
        SOURCE_DIRS="${SOURCE_DIRS} $d"
      fi
    fi
  done
fi

if [ -z "$SOURCE_DIRS" ]; then
  echo "COMPLEXITY BASELINE: SKIP (no source directory found)"
  exit 0
fi

# ── Step 2: Count LOC by layer ──────────────────────────────────
TOTAL_LOC=0
LOC_DOMAIN=0
LOC_INFRA=0
LOC_API=0
LOC_FRONTEND=0
FILE_DOMAIN=0
FILE_INFRA=0
FILE_API=0
FILE_FRONTEND=0

for src_dir in $SOURCE_DIRS; do
  # Total LOC
  dir_loc=$(find "$src_dir" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rb" -o -name "*.rs" \) -not -path '*/node_modules/*' -not -path '*/.artifacts/*' -not -path '*/dist/*' -not -path '*/build/*' -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
  TOTAL_LOC=$((TOTAL_LOC + dir_loc))

  # Per-layer LOC
  for layer_dir in "$src_dir"/domain "$src_dir"/lib/domain "$src_dir"/src/domain; do
    if [ -d "$layer_dir" ]; then
      l=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
      LOC_DOMAIN=$((LOC_DOMAIN + l))
      fc=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) 2>/dev/null | wc -l | tr -d ' ')
      FILE_DOMAIN=$((FILE_DOMAIN + fc))
    fi
  done

  for layer_dir in "$src_dir"/infra "$src_dir"/lib/infra "$src_dir"/src/infra; do
    if [ -d "$layer_dir" ]; then
      l=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
      LOC_INFRA=$((LOC_INFRA + l))
      fc=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) 2>/dev/null | wc -l | tr -d ' ')
      FILE_INFRA=$((FILE_INFRA + fc))
    fi
  done

  for layer_dir in "$src_dir"/api "$src_dir"/lib/api "$src_dir"/src/api; do
    if [ -d "$layer_dir" ]; then
      l=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
      LOC_API=$((LOC_API + l))
      fc=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) 2>/dev/null | wc -l | tr -d ' ')
      FILE_API=$((FILE_API + fc))
    fi
  done

  for layer_dir in "$src_dir"/frontend "$src_dir"/lib/frontend "$src_dir"/src/frontend; do
    if [ -d "$layer_dir" ]; then
      l=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.tsx" -o -name "*.jsx" -o -name "*.py" \) -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
      LOC_FRONTEND=$((LOC_FRONTEND + l))
      fc=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.tsx" -o -name "*.jsx" \) 2>/dev/null | wc -l | tr -d ' ')
      FILE_FRONTEND=$((FILE_FRONTEND + fc))
    fi
  done
done

# ── Step 3: Count files by layer ────────────────────────────────
# (Already computed above in the loop)

# ── Step 4: Compute average function length ─────────────────────
AVG_FUNC_LENGTH=0
TOTAL_FUNC_LENGTH=0
FUNC_COUNT=0

for src_dir in $SOURCE_DIRS; do
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # Use awk to find function declarations and count lines to closing brace
    func_info=$(awk '
      /function[[:space:]]+[a-zA-Z_]/ || /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\([^{]*\)[[:space:]]*\{/ {
        in_func = 1
        brace_count = 0
        func_start = NR
        func_lines = 0
      }
      in_func {
        func_lines++
        n = split($0, chars, "")
        for (i = 1; i <= n; i++) {
          if (chars[i] == "{") brace_count++
          if (chars[i] == "}") brace_count--
        }
        if (brace_count <= 0 && func_lines > 1) {
          total += func_lines
          count++
          in_func = 0
          func_lines = 0
        }
      }
      END { printf "%d %d", total, count }
    ' "$file" 2>/dev/null || echo "0 0")
    f_total=$(echo "$func_info" | awk '{print $1}')
    f_count=$(echo "$func_info" | awk '{print $2}')
    TOTAL_FUNC_LENGTH=$((TOTAL_FUNC_LENGTH + f_total))
    FUNC_COUNT=$((FUNC_COUNT + f_count))
  done < <(find "$src_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" \) -not -path '*/node_modules/*' -not -path '*/.artifacts/*' 2>/dev/null)
done

if [ "$FUNC_COUNT" -gt 0 ]; then
  AVG_FUNC_LENGTH=$((TOTAL_FUNC_LENGTH / FUNC_COUNT))
fi

# ── Step 5: Count imports ───────────────────────────────────────
IMPORT_COUNT=0
for src_dir in $SOURCE_DIRS; do
  ic=$(grep -rcE '^(import |require\(|from )' "$src_dir" 2>/dev/null | tail -1 | cut -d: -f2 || echo "0")
  IMPORT_COUNT=$((IMPORT_COUNT + ic))
done

# ── Step 6: Write baseline ──────────────────────────────────────
TS=$(now_utc)

cat > "$TREND_FILE" << JSONEOF
{
  "version": 1,
  "baseline": {
    "established_at": "${TS}",
    "total_loc": ${TOTAL_LOC},
    "loc_by_layer": {"domain": ${LOC_DOMAIN}, "infra": ${LOC_INFRA}, "api": ${LOC_API}, "frontend": ${LOC_FRONTEND}},
    "file_count_by_layer": {"domain": ${FILE_DOMAIN}, "infra": ${FILE_INFRA}, "api": ${FILE_API}, "frontend": ${FILE_FRONTEND}},
    "avg_func_length": ${AVG_FUNC_LENGTH},
    "import_count": ${IMPORT_COUNT}
  },
  "entries": [],
  "alerts": [],
  "trends": {}
}
JSONEOF

echo "COMPLEXITY BASELINE established: LOC=${TOTAL_LOC}, domain=${LOC_DOMAIN}, infra=${LOC_INFRA}, api=${LOC_API}, frontend=${LOC_FRONTEND}"
echo "  avg_func_length=${AVG_FUNC_LENGTH}, import_count=${IMPORT_COUNT}, files: d=${FILE_DOMAIN} i=${FILE_INFRA} a=${FILE_API} f=${FILE_FRONTEND}"
