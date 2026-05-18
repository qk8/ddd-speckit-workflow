#!/usr/bin/env bash
# Unified spec revision counter.
# Single source of truth for spec revision tracking via state.json.
# Replaces separate .spec_revision_count and .spec_revision_cascade files.
#
# Usage:
#   spec-revision-counter.sh <feature_dir> read [--cascade]
#   spec-revision-counter.sh <feature_dir> increment [--cascade]
#   spec-revision-counter.sh <feature_dir> reset [--cascade]
#   spec-revision-counter.sh <feature_dir> status [--cascade]
#
# Outputs:
#   REVISIONS=N          — main spec revision count
#   CASCADE=N            — cascade revision count (if --cascade)
#   OK=true|false        — within limits?
#   EXHAUSTED=true|false — revision limit reached?
#   CASCADE_EXHAUSTED=true|false — cascade limit reached?

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/lib/check-common.sh"
source "$SCRIPTS_DIR/revision-limits.sh"

# ── Parse flags ────────────────────────────────────────────────────
JSON_MODE=false
CASCADE_FLAG=false
FILTERED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --json)      JSON_MODE=true ;;
    --cascade)   CASCADE_FLAG=true ;;
    --help)      check_help "spec-revision-counter.sh" "<feature_dir> <read|increment|reset|status> [--cascade] [--json] [--help]" ;;
    *)           FILTERED_ARGS+=("$arg") ;;
  esac
done
set -- "${FILTERED_ARGS[@]}"

FEATURE_DIR="${1:-}"
MODE="${2:-}"
if [ -z "$MODE" ]; then
  echo "ERROR: mode required (read|increment|reset|status)" >&2
  exit 1
fi
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(check_find_feature_dir "" || true)
fi
FEATURE_DIR="${FEATURE_DIR:-}"

if [ -z "$FEATURE_DIR" ]; then
  echo "REVISIONS=0"
  echo "OK=true"
  echo "EXHAUSTED=false"
  if [ "$CASCADE_FLAG" = true ]; then
    echo "CASCADE=0"
    echo "CASCADE_EXHAUSTED=false"
  fi
  exit 0
fi

STATE_FILE="$FEATURE_DIR/state.json"
LOCK_FILE="$STATE_FILE.lock"

# Fallback files (legacy, used if state.json doesn't exist)
COUNT_FILE="$FEATURE_DIR/.spec_revision_count"

mkdir -p "$FEATURE_DIR"

# ── Locking ────────────────────────────────────────────────────────
exec 200>"$LOCK_FILE"
flock -x 200

# ── Read current counts ───────────────────────────────────────────
# Priority: state.json > legacy files
read_state() {
  local revs=0 cascades=0

  if [ -f "$STATE_FILE" ] && jq empty "$STATE_FILE" 2>/dev/null; then
    revs=$(jq -r '.revisions.spec_total // 0' "$STATE_FILE" 2>/dev/null || echo 0)
    cascades=$(jq -r '.revisions.spec_cascade // 0' "$STATE_FILE" 2>/dev/null || echo 0)
    case "$revs" in ''|*[!0-9]*) revs=0 ;; esac
    case "$cascades" in ''|*[!0-9]*) cascades=0 ;; esac
  else
    # Fallback to legacy files
    if [ -f "${COUNT_FILE}.spec_total" ]; then
      revs=$(cat "${COUNT_FILE}.spec_total" 2>/dev/null || echo 0)
      case "$revs" in ''|*[!0-9]*) revs=0 ;; esac
    fi
    if [ -f "${COUNT_FILE}.spec_cascade" ]; then
      cascades=$(cat "${COUNT_FILE}.spec_cascade" 2>/dev/null || echo 0)
      case "$cascades" in ''|*[!0-9]*) cascades=0 ;; esac
    fi
  fi

  echo "$revs $cascades"
}

write_state() {
  local revs="$1" cascades="$2"

  if [ -f "$STATE_FILE" ] && jq empty "$STATE_FILE" 2>/dev/null; then
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq --argjson rev "$revs" --argjson cas "$cascades" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')" \
      '.revisions.spec_total = $rev | .revisions.spec_cascade = $cas | .metadata.updated_at = $ts' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  else
    # Write legacy files
    echo "$revs" > "${COUNT_FILE}.spec_total"
    echo "$cascades" > "${COUNT_FILE}.spec_cascade"
  fi
}

# ── Operations ─────────────────────────────────────────────────────
CURRENT_REV=0
CURRENT_CASC=0
read_out=$(read_state)
CURRENT_REV=$(echo "$read_out" | awk '{print $1}')
CURRENT_CASC=$(echo "$read_out" | awk '{print $2}')

case "$MODE" in
  read)
    echo "REVISIONS=$CURRENT_REV"
    if [ "$CURRENT_CASC" -ge "$MAX_SPEC_REVISIONS" ]; then
      echo "CASCADE_EXHAUSTED=true"
    else
      echo "CASCADE_EXHAUSTED=false"
    fi
    if [ "$CURRENT_REV" -ge "$MAX_SPEC_REVISIONS" ]; then
      echo "OK=false"
      echo "EXHAUSTED=true"
    else
      echo "OK=true"
      echo "EXHAUSTED=false"
    fi
    if [ "$CASCADE_FLAG" = true ]; then
      echo "CASCADE=$CURRENT_CASC"
    fi
    ;;

  increment)
    CURRENT_REV=$((CURRENT_REV + 1))
    if [ "$CASCADE_FLAG" = true ]; then
      CURRENT_CASC=$((CURRENT_CASC + 1))
    fi
    write_state "$CURRENT_REV" "$CURRENT_CASC"
    echo "REVISIONS=$CURRENT_REV"
    if [ "$CASCADE_FLAG" = true ]; then
      echo "CASCADE=$CURRENT_CASC"
    fi
    if [ "$CURRENT_REV" -ge "$MAX_SPEC_REVISIONS" ]; then
      echo "OK=false"
      echo "EXHAUSTED=true"
    else
      echo "OK=true"
      echo "EXHAUSTED=false"
    fi
    if [ "$CURRENT_CASC" -ge "$MAX_SPEC_REVISIONS" ]; then
      echo "CASCADE_EXHAUSTED=true"
    else
      echo "CASCADE_EXHAUSTED=false"
    fi
    ;;

  reset)
    if [ "$CASCADE_FLAG" = true ]; then
      write_state 0 0
      echo "REVISIONS=0"
      echo "CASCADE=0"
      echo "CASCADE_EXHAUSTED=false"
    else
      write_state 0 "$CURRENT_CASC"
      echo "REVISIONS=0"
      echo "CASCADE=$CURRENT_CASC"
    fi
    echo "OK=true"
    echo "EXHAUSTED=false"
    ;;

  status)
    echo "REVISIONS=$CURRENT_REV"
    echo "CASCADE=$CURRENT_CASC"
    if [ "$CURRENT_REV" -ge "$MAX_SPEC_REVISIONS" ]; then
      echo "OK=false"
      echo "EXHAUSTED=true"
    else
      echo "OK=true"
      echo "EXHAUSTED=false"
    fi
    if [ "$CURRENT_CASC" -ge "$MAX_SPEC_REVISIONS" ]; then
      echo "CASCADE_EXHAUSTED=true"
    else
      echo "CASCADE_EXHAUSTED=false"
    fi
    echo "MAX_SPEC_REVISIONS=$MAX_SPEC_REVISIONS"
    echo "REMAINING=$((MAX_SPEC_REVISIONS - CURRENT_REV))"
    ;;

  *)
    echo "ERROR: unknown mode: $MODE" >&2
    exit 1
    ;;
esac

flock -u 200
exit 0
