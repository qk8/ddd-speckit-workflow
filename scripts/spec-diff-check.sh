#!/usr/bin/env bash
# ── Spec Diff Check ──────────────────────────────────────────────
# Detects unauthorized modifications to spec/plan files during
# implementation. Captures baseline before impl, checks after.
#
# Usage:
#   spec-diff-check.sh --capture <feature_dir>  — capture baseline hashes
#   spec-diff-check.sh --check <feature_dir>    — compare against baseline
#
# Output (check mode):
#   SPEC_CHANGES=NONE|AUTHORIZED|UNAUTHORIZED
#   CHANGED-FILE-1=path
#   CHANGED-FILE-2=path
# Always exits 0 (advisory to orchestrator, enforced by command instruction).

set -euo pipefail

FEATURE_DIR="${1:-}"
MODE="${2:-}"

if [ -z "$FEATURE_DIR" ] || [ -z "$MODE" ]; then
  echo "Usage: spec-diff-check.sh [--capture|--check] <feature_dir>"
  exit 0
fi

ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"
BASELINE_FILE="$ARTIFACTS_DIR/spec-baseline.json"

# Spec files to monitor
SPEC_FILES="spec.md plan.md constitution.md"

# ── Mode 1: Capture baseline ────────────────────────────────────
if [ "$MODE" = "--capture" ]; then
  mkdir -p "$ARTIFACTS_DIR"

  echo "{" > "$BASELINE_FILE"
  echo "  \"captured_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'unknown')\"," >> "$BASELINE_FILE"
  echo "  \"files\": {" >> "$BASELINE_FILE"

  first=true
  for spec_file in $SPEC_FILES; do
    local_fpath="$FEATURE_DIR/$spec_file"
    if [ -f "$local_fpath" ]; then
      local_hash=$(sha256sum "$local_fpath" 2>/dev/null | awk '{print $1}' || echo "unavailable")
      if [ "$first" = true ]; then
        first=false
      else
        echo "," >> "$BASELINE_FILE"
      fi
      printf '    "%s": "%s"' "$spec_file" "$local_hash" >> "$BASELINE_FILE"
    fi
  done

  echo "" >> "$BASELINE_FILE"
  echo "  }" >> "$BASELINE_FILE"
  echo "}" >> "$BASELINE_FILE"

  echo "SPEC_BASELINE_CAPTURED=${BASELINE_FILE}"
  echo "FILES_TRACKED=$(echo "$SPEC_FILES" | wc -w)"
  exit 0
fi

# ── Mode 2: Check against baseline ──────────────────────────────
if [ "$MODE" = "--check" ] && [ ! -f "$BASELINE_FILE" ]; then
  echo "SPEC_CHANGES=NONE"
  echo "NO_BASELINE_FOUND"
  exit 0
fi

if [ "$MODE" = "--check" ]; then
  # Extract baseline hashes
  declare -A baseline_hashes
  while IFS= read -v line; do
    local_key=$(echo "$line" | sed 's/.*"\([^"]*\)": "\([^"]*\)".*/\1/')
    local_val=$(echo "$line" | sed 's/.*"\([^"]*\)": "\([^"]*\)".*/\2/')
    if [ -n "$local_key" ] && [ -n "$local_val" ] && [ "$local_key" != "$local_val" ]; then
      baseline_hashes["$local_key"]="$local_val"
    fi
  done < <(grep '"spec.md"\|"plan.md"\|"constitution.md"' "$BASELINE_FILE" 2>/dev/null || true)

  # Get current hashes and compare
  CHANGED_FILES=""
  CHANGED_COUNT=0

  for spec_file in $SPEC_FILES; do
    local_fpath="$FEATURE_DIR/$spec_file"
    if [ ! -f "$local_fpath" ]; then
      continue
    fi

    local_current_hash=$(sha256sum "$local_fpath" 2>/dev/null | awk '{print $1}' || echo "unavailable")
    local_baseline_hash="${baseline_hashes[$spec_file]:-}"

    if [ -n "$local_baseline_hash" ] && [ "$local_current_hash" != "$local_baseline_hash" ]; then
      CHANGED_COUNT=$((CHANGED_COUNT + 1))
      CHANGED_FILES="${CHANGED_FILES}${spec_file};"
    fi
  done

  if [ "$CHANGED_COUNT" -eq 0 ]; then
    echo "SPEC_CHANGES=NONE"
    exit 0
  fi

  # Check if changes are authorized (match task Scope.Modifies)
  local authorized=false
  local todo_task_id=""

  # Get current task ID from state.json or tasks.md
  if [ -f "$FEATURE_DIR/state.json" ]; then
    todo_task_id=$(jq -r '.tasks | to_entries[] | select(.value.status == "IN_PROGRESS") | .key' "$FEATURE_DIR/state.json" 2>/dev/null | head -1 || true)
  fi

  if [ -z "$todo_task_id" ] && [ -f "$FEATURE_DIR/tasks.md" ]; then
    todo_task_id=$(awk '
      /^## TASK-/ { tid = $0; sub(/^## /, "", tid) }
      /^Status: IN_PROGRESS/ { print tid; exit }
    ' "$FEATURE_DIR/tasks.md" 2>/dev/null || true)
  fi

  if [ -n "$todo_task_id" ] && [ -f "$FEATURE_DIR/tasks.md" ]; then
    # Extract Scope.Modifies for this task
    local scope_modifies
    scope_modifies=$(awk -v tid="## $todo_task_id" '
      $0 == tid { found=1; next }
      found && /^## / { exit }
      found && /Scope.Modifies:/ { in_scope=1; next }
      in_scope && /^\s+- / {
        sub(/^[[:space:]]+- /, "")
        sub(/[[:space:]]*$/, "")
        print
      }
      in_scope && /^Scope:/ { exit }
    ' "$FEATURE_DIR/tasks.md" 2>/dev/null || true)

    # Check if any changed spec file is in Scope.Modifies
    while IFS=';' read -v -a changed_arr; do
      for cf in "${changed_arr[@]}"; do
        [ -z "$cf" ] && continue
        if echo "$scope_modifies" | grep -qF "$cf"; then
          authorized=true
        fi
      done
    done <<< "$CHANGED_FILES"
  fi

  if [ "$authorized" = true ]; then
    echo "SPEC_CHANGES=AUTHORIZED"
  else
    echo "SPEC_CHANGES=UNAUTHORIZED"
  fi

  IFS=';' read -v -a changed_arr <<< "$CHANGED_FILES"
  for i in "${!changed_arr[@]}"; do
    cf="${changed_arr[$i]}"
    [ -z "$cf" ] && continue
    echo "CHANGED-FILE-$((i+1))=${cf}"
  done
  echo "CHANGED_COUNT=${CHANGED_COUNT}"
fi

exit 0
