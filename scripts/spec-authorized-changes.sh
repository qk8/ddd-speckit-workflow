#!/usr/bin/env bash
# Track which spec changes were approved during a revision cycle.
# Solves fragile authorization check by maintaining an explicit log.
#
# Usage:
#   spec-authorized-changes.sh <feature_dir> log <file> <reason> [task_id]
#   spec-authorized-changes.sh <feature_dir> check <file>
#   spec-authorized-changes.sh <feature_dir> list
#   spec-authorized-changes.sh <feature_dir> reset
#
# Log file: <feature_dir>/.artifacts/authorized-spec-changes.json
# Format: [{file, reason, timestamp, task_id}, ...]

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"

# ── Parse flags ────────────────────────────────────────────────────
if [ "${1:-}" = "--help" ]; then
  check_help "spec-authorized-changes.sh" "<feature_dir> <log|check|list|reset> [args...]"
fi

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(check_find_feature_dir "" || true)
fi
FEATURE_DIR="${FEATURE_DIR:-}"

if [ -z "$FEATURE_DIR" ]; then
  echo "ERROR: feature_dir required" >&2
  exit 1
fi

MODE="${2:-}"
if [ -z "$MODE" ]; then
  echo "ERROR: mode required (log|check|list|reset)" >&2
  exit 1
fi

LOG_FILE="$FEATURE_DIR/.artifacts/authorized-spec-changes.json"
LOCK_FILE="$LOG_FILE.lock"
mkdir -p "$FEATURE_DIR/.artifacts"

# Use flock for mutual exclusion
exec 200>"$LOCK_FILE"
flock -x 200

# Ensure log file exists
if [ ! -f "$LOG_FILE" ]; then
  echo '[]' > "$LOG_FILE"
fi

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

case "$MODE" in
  log)
    FILE="$3"
    REASON="${4:-}"
    TASK_ID="${5:-}"
    if [ -z "$FILE" ]; then
      echo "ERROR: file path required for log" >&2
      exit 1
    fi
    if [ -z "$REASON" ]; then
      echo "ERROR: reason required for log" >&2
      exit 1
    fi
    TMPFILE=$(mktemp "${LOG_FILE}.XXXXXX")
    jq --arg file "$FILE" \
       --arg reason "$REASON" \
       --arg ts "$(now_utc)" \
       --arg tid "${TASK_ID:-null}" \
      '. += [{"file": $file, "reason": $reason, "timestamp": $ts, "task_id": (if $tid == "null" then null else $tid end)}]' \
      "$LOG_FILE" > "$TMPFILE" && mv "$TMPFILE" "$LOG_FILE"
    echo "LOGGED: $FILE — $REASON"
    ;;

  check)
    FILE="$3"
    if [ -z "$FILE" ]; then
      echo "ERROR: file path required for check" >&2
      exit 1
    fi
    AUTHORIZED=$(jq --arg file "$FILE" 'any(.[]; .file == $file)' "$LOG_FILE")
    if [ "$AUTHORIZED" = "true" ]; then
      echo "AUTHORIZED"
      exit 0
    else
      echo "UNAUTHORIZED"
      exit 1
    fi
    ;;

  list)
    jq -r '.[] | "[\(.timestamp)] \(.file): \(.reason)" + (if .task_id then " (task: \(.task_id))" else "" end)' "$LOG_FILE"
    ;;

  reset)
    TMPFILE=$(mktemp "${LOG_FILE}.XXXXXX")
    echo '[]' > "$TMPFILE"
    mv "$TMPFILE" "$LOG_FILE"
    echo "RESET: authorized changes log cleared"
    ;;

  *)
    echo "ERROR: unknown mode: $MODE" >&2
    exit 1
    ;;
esac

flock -u 200
exit 0
