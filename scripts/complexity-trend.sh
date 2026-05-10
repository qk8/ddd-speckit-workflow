#!/usr/bin/env bash
# complexity-trend.sh — Log complexity metrics per task and compute trends
#
# Usage: scripts/complexity-trend.sh <feature_dir> <task_id> [source_dir]
#
# Reads baseline from .artifacts/complexity-trend.json, computes current
# metrics, checks alerts, appends entry, and outputs summary.
#
# Bash 3.2 compatible — no jq dependency.

set -euo pipefail

FEATURE_DIR="${1:?Usage: complexity-trend.sh <feature_dir> <task_id> [source_dir]}"
TASK_ID="${2:?Usage: complexity-trend.sh <feature_dir> <task_id> [source_dir]}"
SOURCE_DIR="${3:-}"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
TREND_FILE="$ARTIFACTS_DIR/complexity-trend.json"
QUALITY_FILE="$ARTIFACTS_DIR/code-quality-results.txt"
mkdir -p "$ARTIFACTS_DIR"

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

# ── Step 1: Read baseline ───────────────────────────────────────
if [ ! -f "$TREND_FILE" ]; then
  echo "COMPLEXITY TREND: SKIP (no baseline found — run complexity-baseline.sh first)"
  exit 0
fi

# Extract baseline values using grep/sed (no jq)
BASELINE_LOC=$(grep -oE '"total_loc"[[:space:]]*:[[:space:]]*[0-9]+' "$TREND_FILE" 2>/dev/null | grep -oE '[0-9]+$' || echo "0")
BASELINE_DOMAIN=$(grep -oE '"domain"[[:space:]]*:[[:space:]]*[0-9]+' "$TREND_FILE" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || echo "0")
BASELINE_INFRA=$(grep -oE '"infra"[[:space:]]*:[[:space:]]*[0-9]+' "$TREND_FILE" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || echo "0")
BASELINE_API=$(grep -oE '"api"[[:space:]]*:[[:space:]]*[0-9]+' "$TREND_FILE" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || echo "0")
BASELINE_FRONTEND=$(grep -oE '"frontend"[[:space:]]*:[[:space:]]*[0-9]+' "$TREND_FILE" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || echo "0")

# ── Step 2: Compute current metrics ─────────────────────────────
if [ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ]; then
  SRC_DIRS="$SOURCE_DIR"
else
  SRC_DIRS=""
  for d in "$FEATURE_DIR/src" "$FEATURE_DIR/lib" "$FEATURE_DIR/app" "$FEATURE_DIR/pkg"; do
    if [ -d "$d" ]; then
      SRC_DIRS="${SRC_DIRS} $d"
    fi
  done
fi

CURRENT_LOC=0
CURRENT_DOMAIN=0
CURRENT_INFRA=0
CURRENT_API=0
CURRENT_FRONTEND=0
CURRENT_FILE_DOMAIN=0
CURRENT_FILE_INFRA=0
CURRENT_FILE_API=0
CURRENT_FILE_FRONTEND=0

if [ -n "$SRC_DIRS" ]; then
  for src_dir in $SRC_DIRS; do
    dir_loc=$(find "$src_dir" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rb" -o -name "*.rs" \) -not -path '*/node_modules/*' -not -path '*/.artifacts/*' -not -path '*/dist/*' -not -path '*/build/*' -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
    CURRENT_LOC=$((CURRENT_LOC + dir_loc))

    for layer_dir in "$src_dir"/domain "$src_dir"/lib/domain "$src_dir"/src/domain; do
      if [ -d "$layer_dir" ]; then
        l=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
        CURRENT_DOMAIN=$((CURRENT_DOMAIN + l))
        fc=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) 2>/dev/null | wc -l | tr -d ' ')
        CURRENT_FILE_DOMAIN=$((CURRENT_FILE_DOMAIN + fc))
      fi
    done

    for layer_dir in "$src_dir"/infra "$src_dir"/lib/infra "$src_dir"/src/infra; do
      if [ -d "$layer_dir" ]; then
        l=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
        CURRENT_INFRA=$((CURRENT_INFRA + l))
        fc=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) 2>/dev/null | wc -l | tr -d ' ')
        CURRENT_FILE_INFRA=$((CURRENT_FILE_INFRA + fc))
      fi
    done

    for layer_dir in "$src_dir"/api "$src_dir"/lib/api "$src_dir"/src/api; do
      if [ -d "$layer_dir" ]; then
        l=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
        CURRENT_API=$((CURRENT_API + l))
        fc=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" \) 2>/dev/null | wc -l | tr -d ' ')
        CURRENT_FILE_API=$((CURRENT_FILE_API + fc))
      fi
    done

    for layer_dir in "$src_dir"/frontend "$src_dir"/lib/frontend "$src_dir"/src/frontend; do
      if [ -d "$layer_dir" ]; then
        l=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.tsx" -o -name "*.jsx" -o -name "*.py" \) -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
        CURRENT_FRONTEND=$((CURRENT_FRONTEND + l))
        fc=$(find "$layer_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.tsx" -o -name "*.jsx" \) 2>/dev/null | wc -l | tr -d ' ')
        CURRENT_FILE_FRONTEND=$((CURRENT_FILE_FRONTEND + fc))
      fi
    done
  done
fi

# Violation count
VIOLATION_COUNT=0
if [ -f "$QUALITY_FILE" ]; then
  VIOLATION_COUNT=$(grep -c '^VIOLATION:' "$QUALITY_FILE" 2>/dev/null || echo "0")
fi

# ── Step 3: Compute deltas ──────────────────────────────────────
LOC_DELTA=$((CURRENT_LOC - BASELINE_LOC))

if [ "$BASELINE_LOC" -gt 0 ]; then
  LOC_PCT_CHANGE=$(awk -v d="$LOC_DELTA" -v b="$BASELINE_LOC" 'BEGIN { printf "%.1f", (d/b)*100 }')
else
  LOC_PCT_CHANGE="0.0"
fi

FILE_DELTA=$((CURRENT_FILE_DOMAIN + CURRENT_FILE_INFRA + CURRENT_FILE_API + CURRENT_FILE_FRONTEND - BASELINE_DOMAIN - BASELINE_INFRA - BASELINE_API - BASELINE_FRONTEND))

# ── Step 4: Check alerts ────────────────────────────────────────
ALERTS=""
LOC_ALERT=0
FILE_ALERT=0

# LOC increase > 20%
LOC_ALERT_CHECK=$(awk -v pct="$LOC_PCT_CHANGE" 'BEGIN { print (pct+0 > 20) ? "1" : "0" }')
if [ "$LOC_ALERT_CHECK" = "1" ]; then
  ALERTS="${ALERTS}ALERT: LOC increased ${LOC_PCT_CHANGE}% from baseline (threshold: 20%)
"
  LOC_ALERT=1
fi

# File proliferation > 50%
if [ "$BASELINE_DOMAIN" -gt 0 ] || [ "$BASELINE_INFRA" -gt 0 ] || [ "$BASELINE_API" -gt 0 ] || [ "$BASELINE_FRONTEND" -gt 0 ]; then
  BASELINE_TOTAL=$((BASELINE_DOMAIN + BASELINE_INFRA + BASELINE_API + BASELINE_FRONTEND))
  CURRENT_TOTAL=$((CURRENT_FILE_DOMAIN + CURRENT_FILE_INFRA + CURRENT_FILE_API + CURRENT_FILE_FRONTEND))
  if [ "$BASELINE_TOTAL" -gt 0 ]; then
    FILE_PCT_CHANGE=$(awk -v d="$FILE_DELTA" -v b="$BASELINE_TOTAL" 'BEGIN { printf "%.1f", (d/b)*100 }')
    FILE_ALERT_CHECK=$(awk -v pct="$FILE_PCT_CHANGE" 'BEGIN { print (pct+0 > 50) ? "1" : "0" }')
    if [ "$FILE_ALERT_CHECK" = "1" ]; then
      ALERTS="${ALERTS}ALERT: File count increased ${FILE_PCT_CHANGE}% from baseline (threshold: 50%)
"
      FILE_ALERT=1
    fi
  fi
fi

# Violations
if [ "$VIOLATION_COUNT" -gt 0 ]; then
  ALERTS="${ALERTS}ALERT: ${VIOLATION_COUNT} code quality violations detected
"
fi

# ── Step 5: Compute trends ──────────────────────────────────────
TRENDS=""
if [ -f "$TREND_FILE" ]; then
  # Extract last 3 LOC values
  TRENDS=$(awk '
    /"total_loc"/ && /"baseline"/ { next }
    /"total_loc"/ {
      gsub(/.*"total_loc":[[:space:]]*/, "")
      gsub(/[,}].*/, "")
      values[++n] = $0 + 0
    }
    END {
      if (n < 3) { printf "\"total_loc\": \"insufficient_data\"" }
      else {
        avg = (values[n] + values[n-1] + values[n-2]) / 3
        if (values[n] > avg * 1.05) printf "\"total_loc\": \"up\""
        else if (values[n] < avg * 0.95) printf "\"total_loc\": \"down\""
        else printf "\"total_loc\": \"stable\""
      }
    }
  ' "$TREND_FILE" 2>/dev/null || echo "\"total_loc\": \"insufficient_data\"")
fi

# ── Step 6: Append entry ────────────────────────────────────────
TS=$(now_utc)
NEW_ENTRY="    {
      \"task_id\": \"${TASK_ID}\",
      \"completed_at\": \"${TS}\",
      \"total_loc\": ${CURRENT_LOC},
      \"loc_delta_from_baseline\": ${LOC_DELTA},
      \"loc_pct_change\": ${LOC_PCT_CHANGE},
      \"loc_by_layer\": {\"domain\": ${CURRENT_DOMAIN}, \"infra\": ${CURRENT_INFRA}, \"api\": ${CURRENT_API}, \"frontend\": ${CURRENT_FRONTEND}},
      \"file_count_by_layer\": {\"domain\": ${CURRENT_FILE_DOMAIN}, \"infra\": ${CURRENT_FILE_INFRA}, \"api\": ${CURRENT_FILE_API}, \"frontend\": ${CURRENT_FILE_FRONTEND}},
      \"violation_count\": ${VIOLATION_COUNT}
    }"

if [ -f "$TREND_FILE" ]; then
  EXISTING=$(cat "$TREND_FILE")

  if echo "$EXISTING" | grep -q '"entries"' && echo "$EXISTING" | grep -q '"task_id"'; then
    # Append before alerts
    TMPFILE=$(mktemp)
    awk -v entry="$NEW_ENTRY" '
      /"alerts"/ {
        print entry ","
        in_entry=1
      }
      { print }
    ' "$TREND_FILE" > "$TMPFILE"
    mv "$TMPFILE" "$TREND_FILE"
  else
    sed "s/\"entries\": \[\]/\"entries\": [${NEW_ENTRY}]/" "$TREND_FILE" > "${TREND_FILE}.tmp"
    mv "${TREND_FILE}.tmp" "$TREND_FILE"
  fi

  sed -i "s/\"updated_at\": \"[^\"]*\"/\"updated_at\": \"${TS}\"/" "$TREND_FILE" 2>/dev/null || true

  if [ -n "$TRENDS" ]; then
    sed -i "s/\"trends\": {}/\"trends\": {${TRENDS}}/" "$TREND_FILE" 2>/dev/null || true
  fi
else
  cat > "$TREND_FILE" << JSONEOF
{
  "version": 1,
  "baseline": {
    "established_at": "${TS}",
    "total_loc": ${CURRENT_LOC},
    "loc_by_layer": {"domain": ${CURRENT_DOMAIN}, "infra": ${CURRENT_INFRA}, "api": ${CURRENT_API}, "frontend": ${CURRENT_FRONTEND}},
    "file_count_by_layer": {"domain": ${CURRENT_FILE_DOMAIN}, "infra": ${CURRENT_FILE_INFRA}, "api": ${CURRENT_FILE_API}, "frontend": ${CURRENT_FILE_FRONTEND}},
    "avg_func_length": 0,
    "import_count": 0
  },
  "entries": [${NEW_ENTRY}],
  "alerts": [],
  "trends": {}
}
JSONEOF
fi

# ── Step 7: Output ──────────────────────────────────────────────
echo "COMPLEXITY TREND: ${TASK_ID} | LOC ${CURRENT_LOC} (${LOC_PCT_CHANGE}%), violations ${VIOLATION_COUNT}"

if [ -n "$ALERTS" ]; then
  echo "$ALERTS"
fi

exit 0
