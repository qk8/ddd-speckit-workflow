#!/usr/bin/env bash
# Track context window budget usage across a feature session.
# Estimates token counts from context files and logs cumulative usage.
# Helps detect context window overflow risk before it happens.
#
# Usage: scripts/track-context-budget.sh <feature_dir> [--json] [--limit <max_tokens>]
#
# Estimates tokens using rough heuristic: ~1 token per 4 bytes for mixed code/text.
# Logs cumulative budget to .artifacts/context-budget.json.

set -euo pipefail

FEATURE_DIR="${1:?Usage: track-context-budget.sh <feature_dir> [--json] [--limit <max_tokens>]}"
JSON_OUTPUT=false
LIMIT_TOKENS=128000  # Default: Claude 8K context (will be overridden by model)

# Source config for default limit if --limit not explicitly provided
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/ddd-clean-arch/workflow-config.json"

if [ -f "$CONFIG" ]; then
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" context.default_limit_tokens 2>/dev/null || echo "")
  if [ -n "$val" ]; then
    LIMIT_TOKENS="$val"
  fi
fi

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUTPUT=true ;;
    --limit) LIMIT_TOKENS="${2:-128000}"; shift ;;
  esac
  shift
done

ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
BUDGET_FILE="$ARTIFACTS_DIR/context-budget.json"

# ── Token estimation: bytes / 4 ────────────────────────────────
estimate_tokens() {
  local file="$1"
  if [ -f "$file" ]; then
    local bytes
    bytes=$(wc -c < "$file" | tr -d ' ')
    echo $(( bytes / 4 ))
  else
    echo 0
  fi
}

# ── Measure current context files ──────────────────────────────
UNIFIED_CTX="$ARTIFACTS_DIR/unified-context.json"
PLAN_FILE="$FEATURE_DIR/plan.md"
TASKS_FILE="$FEATURE_DIR/tasks.md"
CLAUDE_MD_FILE="$FEATURE_DIR/CLAUDE.md"

UNIFIED_TOKENS=$(estimate_tokens "$UNIFIED_CTX")
PLAN_TOKENS=$(estimate_tokens "$PLAN_FILE")
TASKS_TOKENS=$(estimate_tokens "$TASKS_FILE")
CLAUDE_TOKENS=$(estimate_tokens "$CLAUDE_MD_FILE")

# Check checkpoint files
CHECKPOINT_TOKENS=0
if [ -d "$ARTIFACTS_DIR/checkpoints" ]; then
  for cf in "$ARTIFACTS_DIR/checkpoints"/*.json; do
    [ -f "$cf" ] || continue
    ct=$(estimate_tokens "$cf")
    CHECKPOINT_TOKENS=$((CHECKPOINT_TOKENS + ct))
  done
fi

# Check error memory
ERROR_MEMORY_TOKENS=0
if [ -d "$ARTIFACTS_DIR/error-memory" ]; then
  for ef in "$ARTIFACTS_DIR/error-memory"/*.json; do
    [ -f "$ef" ] || continue
    et=$(estimate_tokens "$ef")
    ERROR_MEMORY_TOKENS=$((ERROR_MEMORY_TOKENS + et))
  done
fi

CURRENT_TOTAL=$((UNIFIED_TOKENS + PLAN_TOKENS + TASKS_TOKENS + CLAUDE_TOKENS + CHECKPOINT_TOKENS + ERROR_MEMORY_TOKENS))

# ── Read cumulative budget (if exists) ─────────────────────────
PREV_TOTAL=0
if [ -f "$BUDGET_FILE" ]; then
  # Extract cumulative_total from existing JSON (bash 3.2 compatible)
  PREV_TOTAL=$(grep -oE '"cumulative_total": [0-9]+' "$BUDGET_FILE" 2>/dev/null | grep -oE '[0-9]+' || echo 0)
fi

CUMULATIVE=$((PREV_TOTAL + CURRENT_TOTAL))

# ── Calculate budget percentages ───────────────────────────────
if [ "$LIMIT_TOKENS" -gt 0 ]; then
  CURRENT_PCT=$((CURRENT_TOTAL * 100 / LIMIT_TOKENS))
  CUMULATIVE_PCT=$((CUMULATIVE * 100 / LIMIT_TOKENS))
else
  CURRENT_PCT=0
  CUMULATIVE_PCT=0
fi

# ── Risk level ─────────────────────────────────────────────────
RISK="OK"
if [ "$CURRENT_PCT" -ge 90 ]; then
  RISK="CRITICAL"
elif [ "$CURRENT_PCT" -ge 75 ]; then
  RISK="WARNING"
elif [ "$CURRENT_PCT" -ge 50 ]; then
  RISK="MODERATE"
fi

# ── Update budget file ─────────────────────────────────────────
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

# Build file breakdown
FILE_BREAKDOWN=""
[ "$UNIFIED_TOKENS" -gt 0 ] && FILE_BREAKDOWN="${FILE_BREAKDOWN}\"unified-context.json\": $UNIFIED_TOKENS, "
[ "$PLAN_TOKENS" -gt 0 ] && FILE_BREAKDOWN="${FILE_BREAKDOWN}\"plan.md\": $PLAN_TOKENS, "
[ "$TASKS_TOKENS" -gt 0 ] && FILE_BREAKDOWN="${FILE_BREAKDOWN}\"tasks.md\": $TASKS_TOKENS, "
[ "$CLAUDE_TOKENS" -gt 0 ] && FILE_BREAKDOWN="${FILE_BREAKDOWN}\"CLAUDE.md\": $CLAUDE_TOKENS, "
[ "$CHECKPOINT_TOKENS" -gt 0 ] && FILE_BREAKDOWN="${FILE_BREAKDOWN}\"checkpoints\": $CHECKPOINT_TOKENS, "
[ "$ERROR_MEMORY_TOKENS" -gt 0 ] && FILE_BREAKDOWN="${FILE_BREAKDOWN}\"error-memory\": $ERROR_MEMORY_TOKENS"

# Remove trailing ", "
FILE_BREAKDOWN=$(echo "$FILE_BREAKDOWN" | sed 's/, $//')

# Read existing session count
SESSION_COUNT=1
if [ -f "$BUDGET_FILE" ]; then
  SESSION_COUNT=$(grep -oE '"session_count": [0-9]+' "$BUDGET_FILE" 2>/dev/null | grep -oE '[0-9]+' || echo 1)
  SESSION_COUNT=$((SESSION_COUNT + 1))
fi

# Write budget file
cat > "$BUDGET_FILE" << EOF
{
  "session_count": $SESSION_COUNT,
  "updated_at": "$TIMESTAMP",
  "current_context": {
    "total_tokens": $CURRENT_TOTAL,
    "budget_limit": $LIMIT_TOKENS,
    "budget_pct": $CURRENT_PCT,
    "risk": "$RISK",
    "files": {$FILE_BREAKDOWN}
  },
  "cumulative": {
    "total_tokens": $CUMULATIVE,
    "sessions": $SESSION_COUNT
  }
}
EOF

# ── Output ─────────────────────────────────────────────────────
if [ "$JSON_OUTPUT" = true ]; then
  cat "$BUDGET_FILE"
else
  echo "=== CONTEXT BUDGET ==="
  echo "Current context: $CURRENT_TOTAL tokens / $LIMIT_TOKENS ($CURRENT_PCT%) [$RISK]"
  echo "Cumulative session: $CUMULATIVE tokens across $SESSION_COUNT task(s)"
  echo ""
  echo "Breakdown:"
  [ "$UNIFIED_TOKENS" -gt 0 ] && echo "  unified-context.json: $UNIFIED_TOKENS tokens"
  [ "$PLAN_TOKENS" -gt 0 ] && echo "  plan.md: $PLAN_TOKENS tokens"
  [ "$TASKS_TOKENS" -gt 0 ] && echo "  tasks.md: $TASKS_TOKENS tokens"
  [ "$CLAUDE_TOKENS" -gt 0 ] && echo "  CLAUDE.md: $CLAUDE_TOKENS tokens"
  [ "$CHECKPOINT_TOKENS" -gt 0 ] && echo "  checkpoints: $CHECKPOINT_TOKENS tokens"
  [ "$ERROR_MEMORY_TOKENS" -gt 0 ] && echo "  error-memory: $ERROR_MEMORY_TOKENS tokens"
  echo ""
  if [ "$RISK" = "CRITICAL" ] || [ "$RISK" = "WARNING" ]; then
    echo "WARNING: Context budget ${RISK,,}. Consider:"
    echo "  - Using context-limited.sh to cap context output"
    echo "  - Removing stale checkpoints"
    echo "  - Narrowing scope to reduce plan.md size"
  fi
fi
