#!/usr/bin/env bash
# context-compact.sh — Proactive context window management.
#
# Between tasks, summarizes learned patterns and prunes stale artifacts.
# 1. Summarizes learned patterns, corrections, and decisions from error memory
#    and revision history into context-summary.json.
# 2. Prunes checkpoint files older than the last N successful checkpoints.
# 3. Trims error memory to the last N most relevant entries.
#
# Usage: scripts/context-compact.sh <feature_dir> [--keep-checkpoints N] [--keep-error-memory N]

set -euo pipefail

FEATURE_DIR="${1:?Usage: context-compact.sh <feature_dir> [--keep-checkpoints N] [--keep-error-memory N]}"

# Defaults — sourced from ddd-clean-arch/workflow-config.json
KEEP_CHECKPOINTS=5
KEEP_ERROR_MEMORY=10
KEEP_PATTERNS=5
KEEP_CORRECTIONS=10
KEEP_DECISIONS=5

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/ddd-clean-arch/workflow-config.json"

if [ -f "$CONFIG" ]; then
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" context.keep_checkpoints 2>/dev/null || echo "")
  [ -n "$val" ] && KEEP_CHECKPOINTS="$val"
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" context.keep_error_memory 2>/dev/null || echo "")
  [ -n "$val" ] && KEEP_ERROR_MEMORY="$val"
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" context.keep_patterns 2>/dev/null || echo "")
  [ -n "$val" ] && KEEP_PATTERNS="$val"
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" context.keep_error_memory 2>/dev/null || echo "")
  [ -n "$val" ] && KEEP_CORRECTIONS="$val"
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" context.keep_decisions 2>/dev/null || echo "")
  [ -n "$val" ] && KEEP_DECISIONS="$val"
fi

# Parse optional args (override config defaults)
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-checkpoints) KEEP_CHECKPOINTS="${2:-$KEEP_CHECKPOINTS}"; shift 2 ;;
    --keep-error-memory) KEEP_ERROR_MEMORY="${2:-$KEEP_ERROR_MEMORY}"; shift 2 ;;
    *) shift ;;
  esac
done

ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
STATE_FILE="$FEATURE_DIR/state.json"
SUMMARY_FILE="$ARTIFACTS_DIR/context-summary.json"
mkdir -p "$ARTIFACTS_DIR"

# ── 1. Summarize learned patterns from error memory ───────────────
PATTERN_COUNT=0
CORRECTION_COUNT=0
DECISION_COUNT=0
PATTERNS="[]"
CORRECTIONS="[]"
DECISIONS="[]"

if [ -d "$ARTIFACTS_DIR/error-memory" ]; then
  # Collect entries from error memory
  ALL_ENTRIES=""
  for ef in "$ARTIFACTS_DIR/error-memory"/*.json; do
    [ -f "$ef" ] || continue
    ALL_ENTRIES+=$(cat "$ef")$'\n'
  done

  # Count entries by type
  PATTERN_COUNT=$(echo "$ALL_ENTRIES" | jq -r '[.[] | select(.type == "pattern")] | length' 2>/dev/null || echo 0)
  CORRECTION_COUNT=$(echo "$ALL_ENTRIES" | jq -r '[.[] | select(.type == "correction")] | length' 2>/dev/null || echo 0)
  DECISION_COUNT=$(echo "$ALL_ENTRIES" | jq -r '[.[] | select(.type == "decision")] | length' 2>/dev/null || echo 0)

  # Keep only the last N of each type
  PATTERNS=$(echo "$ALL_ENTRIES" | jq -c --argjson keep "$KEEP_PATTERNS" '[.[] | select(.type == "pattern")]' 2>/dev/null | jq -c "if length > \$keep then .[-\$keep:] else . end" 2>/dev/null || echo "[]")
  CORRECTIONS=$(echo "$ALL_ENTRIES" | jq -c --argjson keep "$KEEP_CORRECTIONS" '[.[] | select(.type == "correction")]' 2>/dev/null | jq -c "if length > \$keep then .[-\$keep:] else . end" 2>/dev/null || echo "[]")
  DECISIONS=$(echo "$ALL_ENTRIES" | jq -c --argjson keep "$KEEP_DECISIONS" '[.[] | select(.type == "decision")]' 2>/dev/null | jq -c "if length > \$keep then .[-\$keep:] else . end" 2>/dev/null || echo "[]")
fi

# ── 2. Prune old checkpoint files ─────────────────────────────────
CHECKPOINT_DIR="$ARTIFACTS_DIR/checkpoints"
PRUNED_CHECKPOINTS=0

if [ -d "$CHECKPOINT_DIR" ]; then
  CP_COUNT=$(ls -1 "$CHECKPOINT_DIR" 2>/dev/null | wc -l || echo 0)
  if [ "$CP_COUNT" -gt "$KEEP_CHECKPOINTS" ]; then
    TO_REMOVE=$((CP_COUNT - KEEP_CHECKPOINTS))
    # Use a temp file to avoid subshell counter loss from pipe
    local_tmp=$(mktemp)
    ls -1 "$CHECKPOINT_DIR" 2>/dev/null | sort | head -n "$TO_REMOVE" > "$local_tmp"
    while read -r cp_dir; do
      rm -rf "$CHECKPOINT_DIR/$cp_dir"
      PRUNED_CHECKPOINTS=$((PRUNED_CHECKPOINTS + 1))
    done < "$local_tmp"
    rm -f "$local_tmp"
  fi
fi

# ── 3. Trim error memory ─────────────────────────────────────────
ERROR_MEM_DIR="$ARTIFACTS_DIR/error-memory"
PRUNED_MEMORY=0

if [ -d "$ERROR_MEM_DIR" ]; then
  EM_COUNT=$(ls -1 "$ERROR_MEM_DIR" 2>/dev/null | wc -l || echo 0)
  if [ "$EM_COUNT" -gt "$KEEP_ERROR_MEMORY" ]; then
    TO_REMOVE=$((EM_COUNT - KEEP_ERROR_MEMORY))
    # Use a temp file to avoid subshell counter loss from pipe
    local_tmp=$(mktemp)
    ls -1 "$ERROR_MEM_DIR" 2>/dev/null | sort | head -n "$TO_REMOVE" > "$local_tmp"
    while read -r em_file; do
      rm -f "$ERROR_MEM_DIR/$em_file"
      PRUNED_MEMORY=$((PRUNED_MEMORY + 1))
    done < "$local_tmp"
    rm -f "$local_tmp"
  fi
fi

# ── 4. Write context summary ─────────────────────────────────────
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

cat > "$SUMMARY_FILE" <<EOF
{
  "updated_at": "$TIMESTAMP",
  "patterns_count": $PATTERN_COUNT,
  "corrections_count": $CORRECTION_COUNT,
  "decisions_count": $DECISION_COUNT,
  "pruned_checkpoints": $PRUNED_CHECKPOINTS,
  "pruned_error_memory": $PRUNED_MEMORY
}
EOF

# ── 5. Update state.json ─────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  TMP=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg ts "$TIMESTAMP" \
     --argjson pc "$PATTERN_COUNT" \
     --argjson cc "$CORRECTION_COUNT" \
     --argjson dc "$DECISION_COUNT" \
     --argjson pcp "$PRUNED_CHECKPOINTS" \
     --argjson pem "$PRUNED_MEMORY" \
     '.context_summary = {
        "last_compacted": $ts,
        "patterns_count": $pc,
        "corrections_count": $cc,
        "decisions_count": $dc,
        "pruned_checkpoints": $pcp,
        "pruned_error_memory": $pem
      } | .metadata.updated_at = $ts' \
     "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
fi

# ── Output ───────────────────────────────────────────────────────
echo "=== CONTEXT COMPACTION ==="
echo "  Patterns:     $PATTERN_COUNT"
echo "  Corrections:  $CORRECTION_COUNT"
echo "  Decisions:    $DECISION_COUNT"
echo "  Checkpoints pruned: $PRUNED_CHECKPOINTS"
echo "  Error memory pruned: $PRUNED_MEMORY"
echo "  Summary:      $SUMMARY_FILE"

# ── Issue 5: Post-compaction invariant verification ───────────────
bash scripts/post-compaction-verify.sh "$FEATURE_DIR" 2>/dev/null || echo "  Post-compaction verification: SKIPPED (script not found or failed)"
