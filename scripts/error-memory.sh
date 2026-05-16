#!/usr/bin/env bash
# error-memory.sh — Structured error memory for cross-task learning
#
# Usage:
#   bash error-memory.sh read <feature_dir>                          # Read error memory preamble
#   bash error-memory.sh update <feature_dir> <task_id> <error_type> <description> <fix_pattern> [evidence]
#   bash error-memory.sh clear <feature_dir>                         # Clear error memory
#   bash error-memory.sh summary <feature_dir>                       # Print summary
#
# Stores structured learnings in .artifacts/error-memory.json
# Schema (bash 3.2 compatible, no jq dependency):
#   {
#     "version": 1,
#     "updated": "2026-01-01T00:00:00Z",
#     "corrections": [
#       {"task": "TASK-3", "type": "mocking", "description": "...", "fix": "...", "evidence": "...", "count": 2, "confidence": 0.8}
#     ],
#     "abandoned_tasks": [
#       {"task": "TASK-5", "reason": "...", "date": "2026-01-01"}
#     ],
#     "drift_patterns": [
#       {"pattern": "naming", "description": "...", "count": 3, "confidence": 0.9}
#     ]
#   }
#
# Bounded: max 10 corrections, max 5 abandoned, max 5 drift patterns.

set -euo pipefail

ACTION="${1:-update}"
FEATURE_DIR="${2:-}"

if [ -z "$FEATURE_DIR" ]; then
  echo "Usage: bash error-memory.sh <read|update|clear|summary> <feature_dir> [args...]"
  exit 1
fi

MEMORY_FILE="$FEATURE_DIR/.artifacts/error-memory.json"
mkdir -p "$FEATURE_DIR/.artifacts"

# ── Helpers ─────────────────────────────────────────────────────

init_memory() {
  if [ ! -f "$MEMORY_FILE" ]; then
    cat > "$MEMORY_FILE" << 'JSONEOF'
{
  "version": 1,
  "updated": "",
  "corrections": [],
  "abandoned_tasks": [],
  "drift_patterns": []
}
JSONEOF
  fi
}

get_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown"
}

# ── Read: print preamble for LLM consumption ───────────────────
do_read() {
  if [ ! -f "$MEMORY_FILE" ]; then
    echo "# Error Memory: No prior learnings"
    return
  fi

  # Extract corrections
  local has_corrections=false
  if grep -q '"corrections"' "$MEMORY_FILE" 2>/dev/null; then
    local correction_count
    correction_count=$(grep -c '"task"' "$MEMORY_FILE" 2>/dev/null || true)
    correction_count=${correction_count:-0}
    if ! echo "$correction_count" | grep -qE '^[0-9]+$'; then
      correction_count=0
    fi
    if [ "$correction_count" -gt 0 ]; then
      has_corrections=true
      echo "# Known Correction Patterns (from recent tasks)"
      # Extract last N corrections
      awk '
        /"task"/ {
          gsub(/.*"task"[[:space:]]*:[[:space:]]*"/, "")
          gsub(/".*/, "")
          task = $0
        }
        /"type"/ {
          gsub(/.*"type"[[:space:]]*:[[:space:]]*"/, "")
          gsub(/".*/, "")
          type = $0
        }
        /"description"/ {
          gsub(/.*"description"[[:space:]]*:[[:space:]]*"/, "")
          gsub(/".*/, "")
          desc = $0
        }
        /"fix"/ {
          gsub(/.*"fix"[[:space:]]*:[[:space:]]*"/, "")
          gsub(/".*/, "")
          fix = $0
        }
        /"evidence"/ {
          gsub(/.*"evidence"[[:space:]]*:[[:space:]]*"/, "")
          gsub(/".*/, "")
          evidence = $0
        }
        /"confidence"/ {
          print "  " task ": " type " — " desc
          print "    Fix: " fix
          if (evidence != "") print "    Evidence: " evidence
          evidence = ""
        }
      ' "$MEMORY_FILE" 2>/dev/null | tail -10
    fi
  fi

  if [ "$has_corrections" = false ]; then
    echo "# Error Memory: No prior learnings"
  fi
}

# ── Update: add an entry ───────────────────────────────────────
do_update() {
  local task_id="${3:-unknown}"
  local error_type="${4:-unknown}"
  local description="${5:-}"
  local fix_pattern="${6:-}"
  local evidence="${7:-}"

  init_memory

  local ts
  ts=$(get_timestamp)

  # Normalize description for deduplication (lowercase, trim whitespace)
  local norm_desc
  norm_desc=$(echo "$description" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]\+/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null || echo "$description")

  # Check for duplicate: same error_type + normalized description within existing entries
  local is_duplicate=false
  local dup_index=""
  if [ "$error_type" != "unknown" ] && [ -n "$description" ]; then
    # Use jq to find matching entries (same type + normalized description)
    dup_index=$(jq -r --arg et "$error_type" --arg nd "$norm_desc" '
      .corrections | to_entries | map(
        select(.value.type == $et) |
        select((.value.description | ascii_downcase | gsub("[\\s]+"; " ") | ltrimstr(" ") | rtrimstr(" ")) == $nd)
      ) | map(.key) | first // empty
    ' "$MEMORY_FILE" 2>/dev/null || true)

    if [ -n "$dup_index" ]; then
      is_duplicate=true
    fi
  fi

  if [ "$is_duplicate" = true ]; then
    # Increment count on existing entry
    local tmp_file
    tmp_file=$(mktemp "${MEMORY_FILE}.XXXXXX")
    jq --argjson idx "$dup_index" \
      '.corrections[$idx].count = (.corrections[$idx].count + 1) | .updated = "'"$ts"'"' \
      "$MEMORY_FILE" > "$tmp_file" && mv "$tmp_file" "$MEMORY_FILE"
    echo "ERROR-MEMORY: deduplicated entry #$(( $(jq ".corrections[$dup_index].count" "$MEMORY_FILE") )) for $error_type"
    return 0
  fi

  # Build the new correction entry as JSON
  local new_entry
  new_entry=$(jq -n \
    --arg task "$task_id" \
    --arg type "$error_type" \
    --arg desc "$description" \
    --arg fix "$fix_pattern" \
    --arg conf "0.5" \
    '{task: $task, type: $type, description: $desc, fix: $fix, count: 1, confidence: ($conf | tonumber)}')

  # If evidence provided, add it
  if [ -n "$evidence" ]; then
    new_entry=$(echo "$new_entry" | jq --arg ev "$evidence" '. + {evidence: $ev}')
  fi

  # Append to corrections array and enforce 10-entry cap
  local tmp_file
  tmp_file=$(mktemp "${MEMORY_FILE}.XXXXXX")
  jq --argjson entry "$new_entry" --arg updated "$ts" '
    .corrections += [$entry] |
    if (.corrections | length) > 10 then
      .corrections = .corrections[-10:]
    else . end |
    .updated = $updated
  ' "$MEMORY_FILE" > "$tmp_file" && mv "$tmp_file" "$MEMORY_FILE"
  echo "ERROR-MEMORY: added correction for $task_id ($error_type)"
}

# ── Update abandoned tasks ──────────────────────────────────────
do_update_abandoned() {
  local task_id="${3:-unknown}"
  local reason="${4:-}"

  init_memory

  local ts
  ts=$(get_timestamp)

  # Check for duplicate
  local dup_index
  dup_index=$(jq -r --arg tid "$task_id" '
    .abandoned_tasks | to_entries | map(select(.value.task == $tid)) | map(.key) | first // empty
  ' "$MEMORY_FILE" 2>/dev/null || true)

  if [ -n "$dup_index" ]; then
    local tmp_file
    tmp_file=$(mktemp "${MEMORY_FILE}.XXXXXX")
    jq --argjson idx "$dup_index" --arg reason "$reason" --arg ts "$ts" '
      .abandoned_tasks[$idx].reason = $reason |
      .abandoned_tasks[$idx].count = (.abandoned_tasks[$idx].count // 1) + 1 |
      .updated = $ts
    ' "$MEMORY_FILE" > "$tmp_file" && mv "$tmp_file" "$MEMORY_FILE"
    return 0
  fi

  local new_entry
  new_entry=$(jq -n --arg task "$task_id" --arg reason "$reason" '{task: $task, reason: $reason, count: 1}')

  local tmp_file
  tmp_file=$(mktemp "${MEMORY_FILE}.XXXXXX")
  jq --argjson entry "$new_entry" --arg ts "$ts" '
    .abandoned_tasks += [$entry] |
    if (.abandoned_tasks | length) > 5 then
      .abandoned_tasks = .abandoned_tasks[-5:]
    else . end |
    .updated = $ts
  ' "$MEMORY_FILE" > "$tmp_file" && mv "$tmp_file" "$MEMORY_FILE"
}

# ── Update drift patterns ──────────────────────────────────────
do_update_drift() {
  local pattern="${3:-unknown}"
  local description="${4:-}"
  local confidence="${5:-0.5}"

  init_memory

  local ts
  ts=$(get_timestamp)

  # Check for duplicate
  local dup_index
  dup_index=$(jq -r --arg pat "$pattern" '
    .drift_patterns | to_entries | map(select(.value.pattern == $pat)) | map(.key) | first // empty
  ' "$MEMORY_FILE" 2>/dev/null || true)

  if [ -n "$dup_index" ]; then
    local tmp_file
    tmp_file=$(mktemp "${MEMORY_FILE}.XXXXXX")
    jq --argjson idx "$dup_index" --arg desc "$description" --arg conf "$confidence" --arg ts "$ts" '
      .drift_patterns[$idx].description = $desc |
      .drift_patterns[$idx].confidence = ($conf | tonumber) |
      .drift_patterns[$idx].count = (.drift_patterns[$idx].count // 1) + 1 |
      .updated = $ts
    ' "$MEMORY_FILE" > "$tmp_file" && mv "$tmp_file" "$MEMORY_FILE"
    return 0
  fi

  local new_entry
  new_entry=$(jq -n --arg pat "$pattern" --arg desc "$description" --arg conf "$confidence" \
    '{pattern: $pat, description: $desc, confidence: ($conf | tonumber), count: 1}')

  local tmp_file
  tmp_file=$(mktemp "${MEMORY_FILE}.XXXXXX")
  jq --argjson entry "$new_entry" --arg ts "$ts" '
    .drift_patterns += [$entry] |
    if (.drift_patterns | length) > 5 then
      .drift_patterns = .drift_patterns[-5:]
    else . end |
    .updated = $ts
  ' "$MEMORY_FILE" > "$tmp_file" && mv "$tmp_file" "$MEMORY_FILE"
}

# ── Clear: reset error memory ──────────────────────────────────
do_clear() {
  init_memory
  local tmp_file
  tmp_file=$(mktemp "${MEMORY_FILE}.XXXXXX")
  jq '{
    version: 1,
    updated: "",
    corrections: [],
    abandoned_tasks: [],
    drift_patterns: []
  }' > "$tmp_file" && mv "$tmp_file" "$MEMORY_FILE"
  echo "Error memory cleared."
}

# ── Summary: print brief summary ───────────────────────────────
do_summary() {
  if [ ! -f "$MEMORY_FILE" ]; then
    echo "Error memory: empty"
    return
  fi

  local correction_count=0
  local abandoned_count=0
  local drift_count=0

  correction_count=$(grep -c '"task"' "$MEMORY_FILE" 2>/dev/null || true)
  correction_count=${correction_count:-0}
  echo "$correction_count" | grep -qE '^[0-9]+$' || correction_count=0
  abandoned_count=$(grep -c '"reason"' "$MEMORY_FILE" 2>/dev/null || true)
  abandoned_count=${abandoned_count:-0}
  echo "$abandoned_count" | grep -qE '^[0-9]+$' || abandoned_count=0
  drift_count=$(grep -c '"pattern"' "$MEMORY_FILE" 2>/dev/null || true)
  drift_count=${drift_count:-0}
  echo "$drift_count" | grep -qE '^[0-9]+$' || drift_count=0

  echo "Error Memory Summary:"
  echo "  Corrections: $correction_count"
  echo "  Abandoned tasks: $abandoned_count"
  echo "  Drift patterns: $drift_count"
  echo "  Last updated: $(grep '"updated"' "$MEMORY_FILE" 2>/dev/null | head -1 | sed 's/.*"updated": "\(.*\)".*/\1/')"
}

# ── Main ─────────────────────────────────────────────────────────
case "$ACTION" in
  read)
    init_memory
    do_read
    ;;
  update)
    do_update "$FEATURE_DIR" "$ACTION" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}"
    ;;
  clear)
    do_clear
    ;;
  summary)
    do_summary
    ;;
  *)
    echo "Usage: bash error-memory.sh <read|update|clear|summary> <feature_dir> [args...]"
    exit 1
    ;;
esac
