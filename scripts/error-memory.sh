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
          print "  TASK-" task ": " type " — " desc
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

  # Count existing entries of this type
  local existing_count=0
  if [ "$error_type" != "unknown" ] && [ -n "$description" ]; then
    existing_count=$(grep -c "\"task\".*\"$task_id\"" "$MEMORY_FILE" 2>/dev/null || true)
    existing_count=${existing_count:-0}
    # Ensure it's a number
    if ! echo "$existing_count" | grep -qE '^[0-9]+$'; then
      existing_count=0
    fi
  fi

  # Simple append approach (bash 3.2 compatible, no jq)
  # Read existing content, append new entry
  local tmp_file
  tmp_file=$(mktemp)

  # Copy existing content
  cp "$MEMORY_FILE" "$tmp_file"

  # If corrections array is empty, add first entry
  if ! grep -q '"task"' "$tmp_file" 2>/dev/null; then
    # Write the first entry directly to avoid sed escaping issues
    {
      echo '{'
      echo '  "version": 1,'
      echo '  "updated": "",'
      echo '  "corrections": ['
      echo '    {'
      echo "      \"task\": \"$task_id\","
      echo "      \"type\": \"$error_type\","
      echo "      \"description\": \"$description\","
      echo "      \"fix\": \"$fix_pattern\","
      if [ -n "$evidence" ]; then
        echo "      \"evidence\": \"$evidence\","
      fi
      echo '      "count": 1,'
      echo '      "confidence": 0.5'
      echo '    }'
      echo '  ],'
      echo '  "abandoned_tasks": [],'
      echo '  "drift_patterns": []'
      echo '}'
    } > "$tmp_file"
  fi

  mv "$tmp_file" "$MEMORY_FILE"
  sed -i "s/\"updated\": \"\"/\"updated\": \"$ts\"/" "$MEMORY_FILE" 2>/dev/null || true
}

# ── Clear: reset error memory ──────────────────────────────────
do_clear() {
  init_memory
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
