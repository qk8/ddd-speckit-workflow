#!/usr/bin/env bash
# Increment the implementation loop iteration counter and output count=N.
# Usage: increment-iteration.sh <feature_dir>
# Outputs: count=N

set -euo pipefail

FEATURE_DIR="${1:?Usage: increment-iteration.sh <feature_dir>}"
STATE_FILE="$FEATURE_DIR/state.json"

if [ -f "$STATE_FILE" ]; then
  current=$(jq -r '._impl.loop_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  case "$current" in ''|*[!0-9]*) current=0 ;; esac
  new_count=$((current + 1))
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --argjson n "$new_count" '._impl.loop_count = $n | .metadata.updated_at = (now | todate)' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
else
  new_count=1
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  echo "{}" > "$tmp"
  jq --argjson n "$new_count" '._impl.loop_count = $n | .metadata.updated_at = (now | todate)' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp" && mv "$tmp" "$STATE_FILE"
fi

echo "count=$new_count"
