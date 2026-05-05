#!/usr/bin/env bash
# check-point.sh — Read/write .workflow-state.json checkpoint
#
# Usage:
#   check-point.sh read <feature_dir>
#   check-point.sh write <feature_dir> task_done <task_id> <type> <built> <test_file>
#   check-point.sh write <feature_dir> task_in_progress <task_id> <type>
#   check-point.sh write <feature_dir> task_abandoned <task_id> <reason>
#
# Uses jq if available, falls back to sed/grep for bash 3.2 compatibility.

set -euo pipefail

MODE="${1:?Usage: check-point.sh <read|write> <feature_dir> <action> [args...]}"
FEATURE_DIR="${2:?Usage: check-point.sh <read|write> <feature_dir> <action> [args...]}"
ACTION="${3:-}"

CHECKPOINT_FILE="$FEATURE_DIR/.workflow-state.json"
mkdir -p "$FEATURE_DIR/.artifacts"

HAS_JQ=false
command -v jq &>/dev/null && HAS_JQ=true

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

init_checkpoint() {
  if [ ! -f "$CHECKPOINT_FILE" ]; then
    cat > "$CHECKPOINT_FILE" <<'EOF'
{
  "version": "2.0",
  "metadata": {"created_at": "", "updated_at": "", "complexity": "medium", "total_tasks": 0},
  "tasks": {},
  "batch_plan": {},
  "stagnation": {"consecutive": 0, "last_done_count": 0},
  "retrospective": {"next_due": 5, "interval": 10},
  "workflow": {"current_phase": "init", "current_iteration": 0}
}
EOF
  fi
}

# ── JQ operations ───────────────────────────────────────────────
TS="$(now_utc)"

do_task_done_jq() {
  local tid="$1" tt="$2" built="$3" tf="$4"
  init_checkpoint
  local tmp; tmp=$(mktemp)
  jq --arg tid "$tid" --arg tt "$tt" --arg b "$built" --arg tf "$tf" --arg ts "$TS" \
    '.tasks[$tid]={"status":"DONE","type":$tt,"built":$b,"test_file":$tf,"checks":{},"revision_history":[],"completed_at":$ts} | .metadata.updated_at=$ts' \
    "$CHECKPOINT_FILE" > "$tmp" && mv "$tmp" "$CHECKPOINT_FILE"
}

do_task_in_progress_jq() {
  local tid="$1" tt="$2"
  init_checkpoint
  local tmp; tmp=$(mktemp)
  jq --arg tid "$tid" --arg tt "$tt" --arg ts "$TS" \
    '.tasks[$tid]={"status":"IN_PROGRESS","type":$tt,"started_at":$ts} | .metadata.updated_at=$ts' \
    "$CHECKPOINT_FILE" > "$tmp" && mv "$tmp" "$CHECKPOINT_FILE"
}

do_task_abandoned_jq() {
  local tid="$1" reason="$2"
  init_checkpoint
  local tmp; tmp=$(mktemp)
  jq --arg tid "$tid" --arg r "$reason" --arg ts "$TS" \
    '.tasks[$tid].status="ABANDONED" | .tasks[$tid].abandoned_reason=$r | .tasks[$tid].abandoned_at=$ts | .metadata.updated_at=$ts' \
    "$CHECKPOINT_FILE" > "$tmp" && mv "$tmp" "$CHECKPOINT_FILE"
}

# ── Fallback (no jq) — uses sed/grep for JSON manipulation ───────
# These functions modify .workflow-state.json without jq.
# Entries are single-line: "TASK-N": {...},
# We use sed to replace existing entries or awk to insert new ones.

do_task_done_fallback() {
  local tid="$1" tt="$2" built="$3" tf="$4"
  init_checkpoint
  local tmp; tmp=$(mktemp)

  local entry="    \"${tid}\": {\"status\":\"DONE\",\"type\":\"${tt}\",\"built\":\"${built}\",\"test_file\":\"${tf}\",\"completed_at\":\"${TS}\"}"

  if grep -q "\"${tid}\":" "$CHECKPOINT_FILE" 2>/dev/null; then
    # Replace existing single-line entry with sed
    sed "s|    \"${tid}\": {[^}]*}|${entry}|" "$CHECKPOINT_FILE" > "$tmp"
  else
    # Insert before "batch_plan"
    awk -v entry="$entry" '
      /^  "batch_plan"/ {
        printf "%s,\n", entry
      }
      { print }
    ' "$CHECKPOINT_FILE" > "$tmp"
  fi
  mv "$tmp" "$CHECKPOINT_FILE"
}

do_task_in_progress_fallback() {
  local tid="$1" tt="$2"
  init_checkpoint
  local tmp; tmp=$(mktemp)

  local entry="    \"${tid}\": {\"status\":\"IN_PROGRESS\",\"type\":\"${tt}\",\"started_at\":\"${TS}\"}"

  if grep -q "\"${tid}\":" "$CHECKPOINT_FILE" 2>/dev/null; then
    sed "s|    \"${tid}\": {[^}]*}|${entry}|" "$CHECKPOINT_FILE" > "$tmp"
  else
    awk -v entry="$entry" '
      /^  "batch_plan"/ {
        printf "%s,\n", entry
      }
      { print }
    ' "$CHECKPOINT_FILE" > "$tmp"
  fi
  mv "$tmp" "$CHECKPOINT_FILE"
}

# ── Read mode ───────────────────────────────────────────────────
if [ "$MODE" = "read" ]; then
  if [ -f "$CHECKPOINT_FILE" ]; then
    cat "$CHECKPOINT_FILE"
  else
    echo "{}"
  fi
  exit 0
fi

# ── Write mode ──────────────────────────────────────────────────
if [ "$MODE" = "write" ]; then
  case "$ACTION" in
    task_done)
      if [ "$HAS_JQ" = true ]; then
        do_task_done_jq "$4" "$5" "$6" "$7"
      else
        do_task_done_fallback "$4" "$5" "$6" "$7"
      fi
      ;;
    task_in_progress)
      if [ "$HAS_JQ" = true ]; then
        do_task_in_progress_jq "$4" "$5"
      else
        do_task_in_progress_fallback "$4" "$5"
      fi
      ;;
    task_abandoned)
      if [ "$HAS_JQ" = true ]; then
        do_task_abandoned_jq "$4" "${5:-}"
      else
        tid="$4"
        reason="${5:-Manual abandon}"
        tmp=$(mktemp)
        entry="    \"${tid}\": {\"status\":\"ABANDONED\",\"abandoned_reason\":\"${reason}\",\"abandoned_at\":\"${TS}\"}"
        if grep -q "\"${tid}\":" "$CHECKPOINT_FILE" 2>/dev/null; then
          sed "s|    \"${tid}\": {[^}]*}|${entry}|" "$CHECKPOINT_FILE" > "$tmp"
        else
          awk -v entry="$entry" '
            /^  "batch_plan"/ {
              printf "%s,\n", entry
            }
            { print }
          ' "$CHECKPOINT_FILE" > "$tmp"
        fi
        mv "$tmp" "$CHECKPOINT_FILE"
      fi
      ;;
    *)
      echo "Unknown action: $ACTION" >&2
      exit 1
      ;;
  esac
else
  echo "Unknown mode: $MODE" >&2
  exit 1
fi
