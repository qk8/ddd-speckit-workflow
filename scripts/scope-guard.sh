#!/usr/bin/env bash
# ── Scope Guard ──────────────────────────────────────────────────
# Validates that file modifications match the task's declared scope.
# Cross-references git diff against tasks.md Scope.Creates/Modifies
# and other tasks' scope to detect scope creep.
#
# Usage: scope-guard.sh <feature_dir> [task_id] [--enforce] [--monorepo <config_path>]
#
# Output: SCOPE=WITHIN_SCOPE|MINOR_VIOLATION|MAJOR_VIOLATION
#         VIOLATION-1=...
#
# Exit codes:
#   0 — within scope (or advisory mode)
#   1 — minor violation (advisory: 1; enforced: 1)
#   2 — major violation (advisory: 0; enforced: 2)
#
# --enforce: exit non-zero on violations (MAJOR→2, MINOR→1).
#            Without --enforce, always exits 0 (advisory only).
# --monorepo <config_path>: path to a YAML/JSON config listing shared directories.
#                           Files in shared dirs are marked SHARED instead of UNOWNED.

set -euo pipefail

FEATURE_DIR="${1:?Usage: scope-guard.sh <feature_dir> [task_id] [--enforce] [--monorepo <config>]}"
TASK_ID="${2:-}"
ENFORCE="${3:-}"
MONOREPO_CONFIG="${4:-}"

# Parse remaining args for --enforce and --monorepo
for arg in "$@"; do
  [ "$arg" = "--enforce" ] && ENFORCE="true"
done

# ── Load monorepo shared directories ──────────────────────────────
declare -A shared_dirs
if [ -n "$MONOREPO_CONFIG" ] && [ -f "$MONOREPO_CONFIG" ]; then
  # Support YAML (list under 'shared_directories') or JSON
  if command -v jq &>/dev/null; then
    while IFS= read -v dir; do
      [ -z "$dir" ] && continue
      shared_dirs["$dir"]=1
    done < <(jq -r '.shared_directories[]? // empty' "$MONOREPO_CONFIG" 2>/dev/null || true)
  fi
fi

is_shared_path() {
  local path="$1"
  for dir in "${!shared_dirs[@]}"; do
    case "$path" in
      "$dir"/*|"$dir") return 0 ;;
    esac
  done
  return 1
}

if [ ! -f "$FEATURE_DIR/tasks.md" ]; then
  echo "SCOPE=WITHIN_SCOPE"
  exit 0
fi

# ── Extract scope files for a task ──────────────────────────────
extract_scope() {
  local task_file="$1"
  local task_id="$2"
  local section="$3"  # "Creates" or "Modifies"

  awk -v tid="## $task_id" -v sec="$section" '
    $0 == tid { found=1; next }
    found && /^## / { exit }
    found && scope_found && /^\s+- / {
      sub(/^[[:space:]]+- /, "")
      sub(/[[:space:]]*$/, "")
      if (length($0) > 0) print
    }
    found && $0 ~ "^Scope\\."sec ":" { scope_found=1; next }
    found && scope_found && /^Scope:/ { exit }
    found && scope_found && /^[A-Z]/ { exit }
  ' "$task_file" 2>/dev/null || true
}

# ── Build scope manifest ────────────────────────────────────────
# Collects all Scope.Creates and Scope.Modifies from ALL tasks
# to detect cross-task scope violations.
declare -A all_task_creates
declare -A all_task_modifies

while IFS= read -v task_line; do
  local_tid=$(echo "$task_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$local_tid" ] && continue

  local_creates
  local_creates=$(extract_scope "$FEATURE_DIR/tasks.md" "$local_tid" "Creates")
  local_modifies
  local_modifies=$(extract_scope "$FEATURE_DIR/tasks.md" "$local_tid" "Modifies")

  while IFS= read -v f; do
    [ -z "$f" ] && continue
    all_task_creates["$local_tid|$f"]=1
  done <<< "$local_creates"

  while IFS= read -v f; do
    [ -z "$f" ] && continue
    all_task_modifies["$local_tid|$f"]=1
  done <<< "$local_modifies"
done < <(grep '^## TASK-' "$FEATURE_DIR/tasks.md" 2>/dev/null || true)

# ── Get current task's scope ────────────────────────────────────
if [ -z "$TASK_ID" ]; then
  # Try to determine from state or tasks.md
  if [ -f "$FEATURE_DIR/state.json" ]; then
    TASK_ID=$(jq -r '.tasks | to_entries[] | select(.value.status == "IN_PROGRESS") | .key' "$FEATURE_DIR/state.json" 2>/dev/null | head -1 || true)
  fi
  if [ -z "$TASK_ID" ] && [ -f "$FEATURE_DIR/tasks.md" ]; then
    TASK_ID=$(awk '
      /^## TASK-/ { tid = $0; sub(/^## /, "", tid) }
      /^Status: IN_PROGRESS/ { print tid; exit }
    ' "$FEATURE_DIR/tasks.md" 2>/dev/null || true)
  fi
fi

if [ -z "$TASK_ID" ]; then
  echo "SCOPE=WITHIN_SCOPE"
  echo "NOTE: No task ID found, skipping scope check"
  exit 0
fi

current_creates=$(extract_scope "$FEATURE_DIR/tasks.md" "$TASK_ID" "Creates")
current_modifies=$(extract_scope "$FEATURE_DIR/tasks.md" "$TASK_ID" "Modifies")

# Build allowed files set
declare -A allowed_files
while IFS= read -v f; do
  [ -z "$f" ] && continue
  allowed_files["$f"]=1
done <<< "$current_creates"
while IFS= read -v f; do
  [ -z "$f" ] && continue
  allowed_files["$f"]=1
done <<< "$current_modifies"

# ── Get modified files from git diff ────────────────────────────
modified_files=""
if [ -d "$FEATURE_DIR/.git" ]; then
  modified_files=$(cd "$FEATURE_DIR" && git diff --name-only HEAD 2>/dev/null || true)
fi

if [ -z "$modified_files" ]; then
  echo "SCOPE=WITHIN_SCOPE"
  exit 0
fi

# ── Check each modified file against scope ──────────────────────
VIOLATION_COUNT=0
MINOR_VIOLATIONS=0
MAJOR_VIOLATIONS=0

while IFS= read -v fpath; do
  [ -z "$fpath" ] && continue

  # Skip non-code files and artifacts
  if echo "$fpath" | grep -qE '^\.artifacts/|^\.git/|\.bak$|\.log$|\.tmp$'; then
    continue
  fi

  # Issue 12: Skip shared directories in monorepo mode
  if [ ${#shared_dirs[@]} -gt 0 ] && is_shared_path "$fpath"; then
    echo "SHARED: $fpath (in shared directory, skipped)"
    continue
  fi

  # Check if file is in current task's scope
  if [ "${allowed_files[$fpath]+isset}" ]; then
    continue  # File is in scope, OK
  fi

  # Check if file belongs to another task's Creates list (MAJOR violation)
  local_is_major=false
  for other_tid in "${!all_task_creates[@]}"; do
    local_other_task=$(echo "$other_tid" | cut -d'|' -f1)
    [ "$local_other_task" = "$TASK_ID" ] && continue
    if [ "${all_task_creates[$other_tid|$fpath]+isset}" ]; then
      local_is_major=true
      break
    fi
  done

  if [ "$local_is_major" = true ]; then
    MAJOR_VIOLATIONS=$((MAJOR_VIOLATIONS + 1))
    VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
  else
    # Check if file is in another task's Modifies list (still MAJOR)
    for other_tid in "${!all_task_modifies[@]}"; do
      local_other_task=$(echo "$other_tid" | cut -d'|' -f1)
      [ "$local_other_task" = "$TASK_ID" ] && continue
      if [ "${all_task_modifies[$other_tid|$fpath]+isset}" ]; then
        MAJOR_VIOLATIONS=$((MAJOR_VIOLATIONS + 1))
        VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
        break
      fi
    done
    if [ "$local_is_major" = false ] && [ "$MAJOR_VIOLATIONS" -eq 0 ]; then
      # Not in any other task's scope either — minor violation (just outside scope)
      MINOR_VIOLATIONS=$((MINOR_VIOLATIONS + 1))
      VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
    fi
  fi
done <<< "$modified_files"

# ── Determine overall status ────────────────────────────────────
if [ "$MAJOR_VIOLATIONS" -gt 0 ]; then
  echo "SCOPE=MAJOR_VIOLATION"
  local_idx=0
  while IFS= read -v fpath; do
    [ -z "$fpath" ] && continue
    if echo "$fpath" | grep -qE '^\.artifacts/|^\.git/|\.bak$|\.log$|\.tmp$'; then
      continue
    fi
    if [ "${allowed_files[$fpath]+isset}" ]; then
      continue
    fi
    local_idx=$((local_idx + 1))
    echo "VIOLATION-${local_idx}=${fpath} (outside task scope)"
  done <<< "$modified_files"
elif [ "$MINOR_VIOLATIONS" -gt 0 ]; then
  echo "SCOPE=MINOR_VIOLATION"
  local_idx=0
  while IFS= read -v fpath; do
    [ -z "$fpath" ] && continue
    if echo "$fpath" | grep -qE '^\.artifacts/|^\.git/|\.bak$|\.log$|\.tmp$'; then
      continue
    fi
    if [ "${allowed_files[$fpath]+isset}" ]; then
      continue
    fi
    local_idx=$((local_idx + 1))
    echo "VIOLATION-${local_idx}=${fpath} (outside task scope, minor)"
  done <<< "$modified_files"
else
  echo "SCOPE=WITHIN_SCOPE"
fi

# ── Exit with appropriate code ───────────────────────────────────
if [ "$ENFORCE" = "true" ]; then
  if [ "$MAJOR_VIOLATIONS" -gt 0 ]; then
    exit 2
  elif [ "$MINOR_VIOLATIONS" -gt 0 ]; then
    exit 1
  fi
fi

exit 0
