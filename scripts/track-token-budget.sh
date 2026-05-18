#!/usr/bin/env bash
# track-token-budget.sh — Track actual LLM token usage across workflow iterations.
#
# Reads per-call token counts from .artifacts/token-log.jsonl (one JSON line per call).
# Each line: {"input_tokens": N, "output_tokens": N, "cache_creation": N, "cache_read": N}
# Computes running averages and projects remaining cost based on remaining tasks.
# Updates state.json token_budget section with actual counts.
#
# Usage: scripts/track-token-budget.sh <feature_dir> [--input INPUT_TOKENS --output OUTPUT_TOKENS [--cache-creation CC --cache-read CR]]
#
# Without --input/--output args: reads existing token-log.jsonl, computes projections, updates state.json.
# With --input/--output args: appends a new entry to token-log.jsonl, then computes projections.

set -euo pipefail

FEATURE_DIR="${1:?Usage: track-token-budget.sh <feature_dir> [--input N --output N [--cache-creation N --cache-read N]]}"
STATE_FILE="$FEATURE_DIR/state.json"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
TOKEN_LOG="$ARTIFACTS_DIR/token-log.jsonl"
mkdir -p "$ARTIFACTS_DIR"

APPEND_MODE=false
INPUT_TOKENS=0
OUTPUT_TOKENS=0
CACHE_CREATION=0
CACHE_READ=0

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --input) INPUT_TOKENS="${2:-0}"; shift 2 ;;
    --output) OUTPUT_TOKENS="${2:-0}"; shift 2 ;;
    --cache-creation) CACHE_CREATION="${2:-0}"; shift 2 ;;
    --cache-read) CACHE_READ="${2:-0}"; shift 2 ;;
    *) shift ;;
  esac
done

if [ "$INPUT_TOKENS" -gt 0 ] || [ "$OUTPUT_TOKENS" -gt 0 ]; then
  APPEND_MODE=true
fi

# ── Append new entry ─────────────────────────────────────────────
if [ "$APPEND_MODE" = true ]; then
  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  echo "{\"timestamp\":\"$TIMESTAMP\",\"input_tokens\":$INPUT_TOKENS,\"output_tokens\":$OUTPUT_TOKENS,\"cache_creation\":$CACHE_CREATION,\"cache_read\":$CACHE_READ}" >> "$TOKEN_LOG"
fi

# ── Read token log (re-read after append to include new entry) ───
TOTAL_INPUT=0
TOTAL_OUTPUT=0
TOTAL_CACHE_CREATION=0
TOTAL_CACHE_READ=0
SESSION_COUNT=0

if [ -f "$TOKEN_LOG" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    s_input=$(echo "$line" | jq -r '.input_tokens // 0' 2>/dev/null || echo 0)
    s_output=$(echo "$line" | jq -r '.output_tokens // 0' 2>/dev/null || echo 0)
    s_cc=$(echo "$line" | jq -r '.cache_creation // 0' 2>/dev/null || echo 0)
    s_cr=$(echo "$line" | jq -r '.cache_read // 0' 2>/dev/null || echo 0)
    case "$s_input" in ''|*[!0-9]*) s_input=0 ;; esac
    case "$s_output" in ''|*[!0-9]*) s_output=0 ;; esac
    case "$s_cc" in ''|*[!0-9]*) s_cc=0 ;; esac
    case "$s_cr" in ''|*[!0-9]*) s_cr=0 ;; esac
    TOTAL_INPUT=$((TOTAL_INPUT + s_input))
    TOTAL_OUTPUT=$((TOTAL_OUTPUT + s_output))
    TOTAL_CACHE_CREATION=$((TOTAL_CACHE_CREATION + s_cc))
    TOTAL_CACHE_READ=$((TOTAL_CACHE_READ + s_cr))
    SESSION_COUNT=$((SESSION_COUNT + 1))
  done < "$TOKEN_LOG"
fi

TOTAL_ALL=$((TOTAL_INPUT + TOTAL_OUTPUT + TOTAL_CACHE_CREATION + TOTAL_CACHE_READ))

# ── Estimate remaining tokens ────────────────────────────────────
# Get remaining task count from state.json or tasks.md
REMAINING_TASKS=0
TOTAL_TASKS=0

if [ -f "$STATE_FILE" ]; then
  REMAINING_TASKS=$(jq '[.tasks | to_entries[] | select(.value.status == "TODO" or .value.status == "IN_PROGRESS")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
  TOTAL_TASKS=$(jq '.tasks | length' "$STATE_FILE" 2>/dev/null || echo 0)
fi

if [ "$REMAINING_TASKS" -le 0 ] || [ -z "$REMAINING_TASKS" ]; then
  REMAINING_TASKS=0
fi
case "$TOTAL_TASKS" in ''|*[!0-9]*) TOTAL_TASKS=0 ;; esac
case "$REMAINING_TASKS" in ''|*[!0-9]*) REMAINING_TASKS=0 ;; esac

COMPLETED_TASKS=$((TOTAL_TASKS - REMAINING_TASKS))

# Compute average tokens per completed task (or per session if no task count yet)
if [ "$COMPLETED_TASKS" -gt 0 ]; then
  AVG_PER_TASK=$((TOTAL_ALL / COMPLETED_TASKS))
elif [ "$SESSION_COUNT" -gt 0 ]; then
  # No completed tasks yet, but we have token data from sessions.
  # Use per-session average as a fallback projection basis.
  AVG_PER_TASK=$((TOTAL_ALL / SESSION_COUNT))
else
  AVG_PER_TASK=0
fi

# Project remaining: average per task * remaining tasks
PROJECTED_REMAINING=0
if [ "$AVG_PER_TASK" -gt 0 ] && [ "$REMAINING_TASKS" -gt 0 ]; then
  PROJECTED_REMAINING=$((AVG_PER_TASK * REMAINING_TASKS))
fi

PROJECTED_TOTAL=$((TOTAL_ALL + PROJECTED_REMAINING))

# ── Cost estimation (approximate Claude API pricing) ────────────
# Claude Sonnet: $3/M input, $15/M output
# Claude Opus: $15/M input, $75/M output
# Using a conservative average: $5/M input, $30/M output
COST_PER_M_INPUT=5
COST_PER_M_OUTPUT=30

INPUT_COST=$(echo "scale=2; $TOTAL_INPUT * $COST_PER_M_INPUT / 1000000" | bc 2>/dev/null || echo "0.00")
OUTPUT_COST=$(echo "scale=2; $TOTAL_OUTPUT * $COST_PER_M_OUTPUT / 1000000" | bc 2>/dev/null || echo "0.00")
TOTAL_COST=$(echo "scale=2; $INPUT_COST + $OUTPUT_COST" | bc 2>/dev/null || echo "0.00")

PROJECTED_COST=$(echo "scale=2; $TOTAL_COST + ($PROJECTED_REMAINING * $COST_PER_M_OUTPUT / 1000000)" | bc 2>/dev/null || echo "0.00")

# ── Risk level ───────────────────────────────────────────────────
# Use percentage of $100 budget as a practical threshold
CRITICAL_DOLLAR=80
WARNING_DOLLAR=50

# Approximate dollar usage from total tokens (rough heuristic)
DOLLAR_USAGE=$(echo "scale=0; ($TOTAL_INPUT + $TOTAL_OUTPUT * 5) * 30 / 1000000" | bc 2>/dev/null || echo 0)

RISK="OK"
if [ "$DOLLAR_USAGE" -ge "$CRITICAL_DOLLAR" ]; then
  RISK="CRITICAL"
elif [ "$DOLLAR_USAGE" -ge "$WARNING_DOLLAR" ]; then
  RISK="WARNING"
fi

# ── Update state.json ────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  TMP=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --argjson input "$TOTAL_INPUT" \
     --argjson output "$TOTAL_OUTPUT" \
     --argjson cc "$TOTAL_CACHE_CREATION" \
     --argjson cr "$TOTAL_CACHE_READ" \
     --argjson sessions "$SESSION_COUNT" \
     --argjson projected "$PROJECTED_TOTAL" \
     --argjson avg_per_task "$AVG_PER_TASK" \
     --arg risk "$RISK" \
     --arg cost "$TOTAL_COST" \
     --arg projected_cost "$PROJECTED_COST" \
     '.token_budget = {
        "actual_input_tokens": $input,
        "actual_output_tokens": $output,
        "cache_creation_tokens": $cc,
        "cache_read_tokens": $cr,
        "sessions_count": $sessions,
        "projected_total": $projected,
        "avg_tokens_per_task": $avg_per_task,
        "risk": $risk,
        "estimated_cost": $cost,
        "projected_cost": $projected_cost
      } | .metadata.updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
     "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
fi

# ── Output ───────────────────────────────────────────────────────
echo "=== TOKEN BUDGET (Actual) ==="
echo "  Sessions:         $SESSION_COUNT"
echo "  Input tokens:     $TOTAL_INPUT"
echo "  Output tokens:    $TOTAL_OUTPUT"
echo "  Cache creation:   $TOTAL_CACHE_CREATION"
echo "  Cache read:       $TOTAL_CACHE_READ"
echo "  Total used:       $TOTAL_ALL"
echo "  Avg per task:     $AVG_PER_TASK"
echo "  Remaining tasks:  $REMAINING_TASKS"
echo "  Projected total:  $PROJECTED_TOTAL"
echo "  Estimated cost:   $TOTAL_COST"
echo "  Projected cost:   $PROJECTED_COST"
echo "  Risk:             $RISK"

if [ "$RISK" = "CRITICAL" ] || [ "$RISK" = "WARNING" ]; then
  echo ""
  echo "WARNING: Token budget ${RISK,,}. Consider:"
  echo "  - Using /speckit.context to compact context"
  echo "  - Splitting remaining tasks into smaller pieces"
  echo "  - Resetting session context"
fi
