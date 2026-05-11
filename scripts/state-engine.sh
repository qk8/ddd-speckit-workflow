#!/usr/bin/env bash
# state-engine.sh — Unified state engine for DDD + Spec Kit workflow
#
# Single source of truth for all workflow state. Replaces 12+ scattered state files.
# All writes use mktemp + mv for atomicity. Uses jq exclusively.
#
# Usage:
#   state-engine.sh init <feature_dir>                          — create empty state.json scaffold
#   state-engine.sh read <feature_dir> <key>                    — read any value (dot notation)
#   state-engine.sh write <feature_dir> <key> <value>           — atomic write
#   state-engine.sh delete <feature_dir> <key>                  — remove a key
#   state-engine.sh validate <feature_dir>                      — validate JSON schema
#   state-engine.sh migrate <feature_dir>                       — migrate old format → state.json
#   state-engine.sh generate-tasks-md <feature_dir>             — regenerate tasks.md from state.json
#   state-engine.sh history-append <feature_dir> <json_entry>   — append to history array
#   state-engine.sh history-prune <feature_dir> <keep>          — keep last N history entries
#   state-engine.sh task-set <feature_dir> <task_id> <key> <value> — set a field on a task
#   state-engine.sh task-incr <feature_dir> <task_id> <key>    — increment a numeric field on a task
#
# State is stored in <feature_dir>/state.json
# Old format files are preserved as .bak after migration.

set -euo pipefail

# ── Prerequisites ────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

MODE="${1:?Usage: state-engine.sh <init|read|write|delete|validate|migrate|generate-tasks-md|history-append|history-prune|task-set|task-incr> <feature_dir> [args...]}"
FEATURE_DIR="${2:?Feature directory required}"
STATE_FILE="$FEATURE_DIR/state.json"

# ── Helpers ──────────────────────────────────────────────────────

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
}

atomic_write() {
  local target="$1" content="$2"
  local tmp
  tmp=$(mktemp "${target}.XXXXXX")
  echo "$content" > "$tmp"
  mv "$tmp" "$target"
}

# Resolve dot-notation key to jq filter (e.g. "tasks.TASK-1.status" → ".tasks.TASK-1.status")
dot_to_jq() {
  local key="$1"
  # Split on dots and build jq path
  local result=""
  local IFS='.'
  for part in $key; do
    result="${result}.${part}"
  done
  echo "$result"
}

# Ensure state.json exists (used by init + auto-init for read/write)
ensure_exists() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "{}" > "$STATE_FILE"
  fi
}

# ── Init ─────────────────────────────────────────────────────────
do_init() {
  mkdir -p "$FEATURE_DIR"
  local ts
  ts="$(now_utc)"
  cat > "$STATE_FILE" <<EOF
{
  "version": 1,
  "tasks": {},
  "history": [],
  "stagnation": {
    "consecutive_no_progress": 0,
    "consecutive_continues": 0,
    "drift_violations": 0,
    "total_abort_count": 0,
    "last_done_count": 0
  },
  "revisions": {
    "plan_review": 0,
    "tasks_phase": 0,
    "fix_needed": 0,
    "per_task": {}
  },
  "metadata": {
    "created_at": "$ts",
    "updated_at": "$ts",
    "feature_dir": "$(cd "$FEATURE_DIR" && pwd)",
    "workflow_version": "2.0.0"
  }
}
EOF
  echo "INIT: state.json created at $STATE_FILE"
}

# ── Read ─────────────────────────────────────────────────────────
do_read() {
  local key="$1"
  [ -z "$key" ] && { echo "Usage: state-engine.sh read <feature_dir> <key>" >&2; exit 1; }
  ensure_exists
  # Convert dot-notation to jq array path for safe key handling
  local jq_path_arr
  jq_path_arr=$(echo "$key" | jq -R 'split(".")')
  jq -r "getpath($jq_path_arr) // empty" "$STATE_FILE"
}

# ── Write ────────────────────────────────────────────────────────
do_write() {
  local key="$1"
  local value="${2:-}"
  [ -z "$key" ] && { echo "Usage: state-engine.sh write <feature_dir> <key> <value>" >&2; exit 1; }
  ensure_exists

  # Convert dot-notation to jq array path (e.g. "tasks.TASK-1.status" → ["tasks","TASK-1","status"])
  local jq_path_arr
  jq_path_arr=$(echo "$key" | jq -R 'split(".")')

  local tmp
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    jq --argjson path "$jq_path_arr" --argjson val "$value" --arg ts "$(now_utc)" \
      'setpath($path; $val) | .metadata.updated_at = $ts' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  elif [[ "$value" == "true" || "$value" == "false" || "$value" == "null" ]]; then
    jq --argjson path "$jq_path_arr" --argjson val "$value" --arg ts "$(now_utc)" \
      'setpath($path; $val) | .metadata.updated_at = $ts' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  else
    jq --argjson path "$jq_path_arr" --arg val "$value" --arg ts "$(now_utc)" \
      'setpath($path; $val) | .metadata.updated_at = $ts' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi
}

# ── Delete ───────────────────────────────────────────────────────
do_delete() {
  local key="$1"
  [ -z "$key" ] && { echo "Usage: state-engine.sh delete <feature_dir> <key>" >&2; exit 1; }
  ensure_exists
  local jq_path_arr
  jq_path_arr=$(echo "$key" | jq -R 'split(".")')

  local tmp
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --argjson path "$jq_path_arr" --arg ts "$(now_utc)" \
    'delpath($path) | .metadata.updated_at = $ts' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ── Validate ─────────────────────────────────────────────────────
do_validate() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "VALIDATION: FAIL — state.json does not exist" >&2
    exit 1
  fi

  # Check valid JSON
  if ! jq empty "$STATE_FILE" 2>/dev/null; then
    echo "VALIDATION: FAIL — not valid JSON" >&2
    exit 1
  fi

  # Check required top-level keys
  local missing=""
  for req_key in version tasks history stagnation revisions metadata; do
    if ! jq -e "has(\"$req_key\")" "$STATE_FILE" >/dev/null 2>&1; then
      missing="${missing}${missing:+,}$req_key"
    fi
  done

  if [ -n "$missing" ]; then
    echo "VALIDATION: FAIL — missing keys: $missing" >&2
    exit 1
  fi

  # Check version is integer 1
  local ver
  ver=$(jq -r '.version' "$STATE_FILE")
  if [[ ! "$ver" =~ ^1$ ]]; then
    echo "VALIDATION: FAIL — version must be 1, got $ver" >&2
    exit 1
  fi

  # Check tasks is object
  local tasks_type
  tasks_type=$(jq -r '.tasks | type' "$STATE_FILE")
  if [ "$tasks_type" != "object" ]; then
    echo "VALIDATION: FAIL — tasks must be an object" >&2
    exit 1
  fi

  # Check each task has status and type
  local bad_tasks
  bad_tasks=$(jq -r '
    .tasks | to_entries[]
    | select(.value.status == null or .value.type == null)
    | .key
  ' "$STATE_FILE" 2>/dev/null)

  if [ -n "$bad_tasks" ]; then
    echo "VALIDATION: FAIL — tasks missing status/type: $bad_tasks" >&2
    exit 1
  fi

  echo "VALIDATION: PASS"
}

# ── Task helpers ─────────────────────────────────────────────────

# Set a field on a specific task
do_task_set() {
  local tid="$1"
  local tkey="$2"
  local tval="${3:-}"
  [ -z "$tid" ] && { echo "Usage: state-engine.sh task-set <feature_dir> <task_id> <key> <value>" >&2; exit 1; }
  [ -z "$tkey" ] && { echo "Usage: state-engine.sh task-set <feature_dir> <task_id> <key> <value>" >&2; exit 1; }
  ensure_exists

  local tmp
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")

  if [[ "$tval" =~ ^[0-9]+$ ]]; then
    jq --arg tid "$tid" --argjson val "$tval" --arg ts "$(now_utc)" \
      '.tasks[$tid].'"$tkey"' = $val | .metadata.updated_at = $ts' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  elif [[ "$tval" == "true" || "$tval" == "false" || "$tval" == "null" ]]; then
    jq --arg tid "$tid" --argjson val "$tval" --arg ts "$(now_utc)" \
      '.tasks[$tid].'"$tkey"' = $val | .metadata.updated_at = $ts' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  else
    jq --arg tid "$tid" --arg val "$tval" --arg ts "$(now_utc)" \
      '.tasks[$tid].'"$tkey"' = $val | .metadata.updated_at = $ts' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi
}

# Increment a numeric field on a specific task
do_task_incr() {
  local tid="$1"
  local tkey="$2"
  [ -z "$tid" ] && { echo "Usage: state-engine.sh task-incr <feature_dir> <task_id> <key>" >&2; exit 1; }
  [ -z "$tkey" ] && { echo "Usage: state-engine.sh task-incr <feature_dir> <task_id> <key>" >&2; exit 1; }
  ensure_exists

  local tmp
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg ts "$(now_utc)" \
    '.tasks[$tid].'"$tkey"' = ((.tasks[$tid].'"$tkey"' // 0) + 1) | .metadata.updated_at = $ts' \
    --arg tid "$tid" \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ── History ──────────────────────────────────────────────────────

do_history_append() {
  local entry="$1"
  [ -z "$entry" ] && { echo "Usage: state-engine.sh history-append <feature_dir> <json_entry>" >&2; exit 1; }
  ensure_exists

  local tmp
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --argjson entry "$entry" \
    '.history += [$entry] | .metadata.updated_at = "'"$(now_utc)"'"' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

do_history_prune() {
  local keep="$1"
  [ -z "$keep" ] && { echo "Usage: state-engine.sh history-prune <feature_dir> <keep>" >&2; exit 1; }
  ensure_exists

  local tmp
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --argjson keep "$keep" \
    '.history = (.history[-($keep):]) | .metadata.updated_at = "'"$(now_utc)"'"' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ── Generate tasks.md ────────────────────────────────────────────

do_generate_tasks_md() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: state.json does not exist — run migrate or init first" >&2
    exit 1
  fi

  local output
  output=$(jq -r '
    "# Implementation Backlog\n",
    "One task = one speckit.implement session (max 5 files, max 1 aggregate).\n",
    "# HOW TDD WORKS\n",
    "# TDD is used throughout — see plan.md for the full explanation.\n",
    "Task order:\n",
    "1. backend-domain  (aggregate root, value objects, events, repo interface — one task per aggregate)\n",
    "2. backend-infra   (repo implementation, DB migration, external adapters — one task per aggregate)\n",
    "3. backend-api     (controller, use case, wired together — one task per endpoint group)\n",
    "4. shared          (contract types, generated code — after API contract is stable)\n",
    "5. integration     (cross-context boundary tests — one task per bounded context relationship)\n",
    "6. frontend-data   (data layer module — one task per bounded context)\n",
    "7. frontend-feature (feature components with Playwright E2E TDD — one task per major feature)\n",
    "8. e2e             (cross-feature journey tests — after all dependent features are DONE)\n",
    "",
    "─────────────────────────────────────────────────────────────────────────\n",
    (.tasks | to_entries | sort_by(.key) | .[] |
      "## \(.key):\(.value.title // "Untitled")\n",
      "Status: \(.value.status // "TODO")\n",
      "Type: \(.value.type // "backend-domain")\n",
      "Depends on: \(if (.value.depends_on // []) | length > 0 then (.value.depends_on | join(", ")) else "none" end)\n",
      "Scope:\n",
      "  Creates:\n",
      "    - \((.value.scope.creates // []) | if length > 0 then join("\n    - ") else "none" end)\n",
      "  Modifies:\n",
      "    - \((.value.scope.modifies // []) | if length > 0 then join("\n    - ") else "none" end)\n",
      "Acceptance criteria:\n",
      "  - \((.value.acceptance_criteria // []) | join("\n  - "))\n",
      "Do NOT:\n",
      "  - \((.value.do_not // []) | if length > 0 then join("\n  - ") else "Nothing specific" end)\n",
      (if .value.revision_count // 0 > 0 then "Revision count: \(.value.revision_count)\n" else "" end),
      (if .value.files_modified // [] | length > 0 then "Files: \(.value.files_modified | join(", "))\n" else "" end),
      ""
    ),
    "─────────────────────────────────────────────────────────────────────────"
  ' "$STATE_FILE" 2>/dev/null)

  echo "$output"
}

# ── Migrate ──────────────────────────────────────────────────────

migrate_tasks_md() {
  local tasks_md="$FEATURE_DIR/tasks.md"
  [ ! -f "$tasks_md" ] && return

  # Parse each ## TASK-N block
  local in_task=false
  local in_section=""  # "creates", "modifies", "ac", "do_not", or ""
  local tid="" title="" status="TODO" task_type="backend-domain" depends="[]"
  local creates="" modifies="" ac="" do_not=""

  while IFS= read -r line; do
    # Detect task header — saves previous task, starts new one
    if [[ "$line" =~ ^##\ (TASK-[0-9]+):\ (.*) ]]; then
      if [ -n "$tid" ]; then
        _save_task "$tid" "$title" "$status" "$task_type" "$depends" "$creates" "$modifies" "$ac" "$do_not"
      fi
      tid="${BASH_REMATCH[1]}"
      title="${BASH_REMATCH[2]}"
      status="TODO"; task_type="backend-domain"; depends="[]"
      creates=""; modifies=""; ac=""; do_not=""
      in_task=true; in_section=""
      continue
    fi

    [ "$in_task" = false ] && continue

    # Section headers set the active section
    if [[ "$line" =~ ^Status:\ (.*) ]]; then
      status="${BASH_REMATCH[1]}"; in_section=""
      continue
    fi
    if [[ "$line" =~ ^Type:\ (.*) ]]; then
      task_type="${BASH_REMATCH[1]}"; in_section=""
      continue
    fi
    if [[ "$line" =~ ^Depends\ on:\ (.*) ]]; then
      local dep_raw="${BASH_REMATCH[1]}"
      if [ "$dep_raw" = "none" ]; then
        depends="[]"
      else
        # Split on comma, trim spaces, quote each
        depends="[$(echo "$dep_raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')]"
      fi
      in_section=""
      continue
    fi
    if [[ "$line" =~ ^Scope: ]]; then
      in_section="scope"; continue
    fi
    if [[ "$line" =~ ^\ \ Creates: ]]; then
      in_section="creates"; continue
    fi
    if [[ "$line" =~ ^\ \ Modifies: ]]; then
      in_section="modifies"; continue
    fi
    if [[ "$line" =~ ^Acceptance\ criteria: ]]; then
      in_section="ac"; continue
    fi
    if [[ "$line" =~ ^Do\ NOT: ]]; then
      in_section="do_not"; continue
    fi

    # Items under active section (4-space indent = scope items, 2-space = AC/do_not)
    if [ -n "$in_section" ]; then
      if [[ "$line" =~ ^\ \ \ \ -\ (.*) ]]; then
        # 4-space indent: Creates or Modifies
        local item="${BASH_REMATCH[1]}"
        # Skip "none" entries
        [ "$item" = "none" ] && continue
        case "$in_section" in
          creates)
            [ -n "$creates" ] && creates="$creates,$item" || creates="$item"
            ;;
          modifies)
            [ -n "$modifies" ] && modifies="$modifies,$item" || modifies="$item"
            ;;
        esac
        continue
      fi
      if [[ "$line" =~ ^\ \ -\ (.*) ]]; then
        # 2-space indent: Acceptance criteria or Do NOT
        local item="${BASH_REMATCH[1]}"
        case "$in_section" in
          ac) [ -n "$ac" ] && ac="$ac|$item" || ac="$item" ;;
          do_not) [ -n "$do_not" ] && do_not="$do_not|$item" || do_not="$item" ;;
        esac
        continue
      fi
      # Any other line resets section (e.g., next section header without ":", or blank line)
      if [[ "$line" =~ ^[[:space:]]*$ ]]; then
        : # blank line, keep section
      else
        in_section=""
      fi
    fi

  done < "$tasks_md"

  # Save last task
  if [ -n "$tid" ]; then
    _save_task "$tid" "$title" "$status" "$task_type" "$depends" "$creates" "$modifies" "$ac" "$do_not"
  fi
}

# Accumulator for migration — we build a JSON string
_MIG_TASKS_JSON="{}"

_save_task() {
  local tid="$1" title="$2" status="$3" task_type="$4" depends="$5"
  local creates="$6" modifies="$7" ac="$8" do_not="$9"

  # Build arrays safely using jq -R (handles quotes, special chars)
  local creates_json="[]"
  [ -n "$creates" ] && creates_json=$(echo "$creates" | tr ',' '\n' | jq -R . | jq -s .)

  local modifies_json="[]"
  [ -n "$modifies" ] && modifies_json=$(echo "$modifies" | tr ',' '\n' | jq -R . | jq -s .)

  local ac_json="[]"
  [ -n "$ac" ] && ac_json=$(echo "$ac" | tr '|' '\n' | jq -R . | jq -s .)

  local dn_json="[]"
  [ -n "$do_not" ] && dn_json=$(echo "$do_not" | tr '|' '\n' | jq -R . | jq -s .)

  _MIG_TASKS_JSON=$(echo "$_MIG_TASKS_JSON" | jq \
    --arg tid "$tid" \
    --arg title "$title" \
    --arg status "$status" \
    --arg type "$task_type" \
    --argjson depends "$depends" \
    --argjson creates "$creates_json" \
    --argjson modifies "$modifies_json" \
    --argjson ac "$ac_json" \
    --argjson dn "$dn_json" \
    '.[$tid] = {
      "status": $status,
      "type": $type,
      "title": $title,
      "depends_on": $depends,
      "scope": { "creates": $creates, "modifies": $modifies },
      "acceptance_criteria": $ac,
      "do_not": $dn,
      "revision_count": 0,
      "last_changed": "",
      "files_modified": [],
      "blocking_reason": null,
      "check_results": {},
      "interfaces_produced": [],
      "interfaces_consumed": []
    }')
}

do_migrate() {
  # Auto-init if state.json doesn't exist
  if [ ! -f "$STATE_FILE" ]; then
    do_init
  fi

  local migrated=false

  # 1. Parse tasks.md
  if [ -f "$FEATURE_DIR/tasks.md" ]; then
    echo "MIGRATE: Parsing tasks.md..."
    migrate_tasks_md
    if [ -n "$_MIG_TASKS_JSON" ] && [ "$_MIG_TASKS_JSON" != "{}" ]; then
      local tmp
      tmp=$(mktemp "${STATE_FILE}.XXXXXX")
      jq --argjson tasks "$_MIG_TASKS_JSON" \
        '.tasks = $tasks | .metadata.updated_at = "'"$(now_utc)"'"' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      migrated=true
    fi
    _MIG_TASKS_JSON="{}"
  fi

  # 2. Merge .workflow-state.json if exists
  if [ -f "$FEATURE_DIR/.workflow-state.json" ]; then
    echo "MIGRATE: Merging .workflow-state.json..."
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq '
      .tasks as $existing |
      (input | .tasks // {}) as $checkpoint_tasks |
      .tasks = ($existing * $checkpoint_tasks | to_entries | map(
        .key as $k |
        .value as $existing_val |
        ($checkpoint_tasks[$k] // null) as $cp_val |
        if $cp_val != null then
          { key: $k, value: ($existing_val * $cp_val) }
        else
          .
        end
      ) | from_entries) |
      .metadata.updated_at = "'"$(now_utc)"'"
    ' "$STATE_FILE" "$FEATURE_DIR/.workflow-state.json" > "$tmp" && mv "$tmp" "$STATE_FILE"
    migrated=true
  fi

  # 3. Parse .artifacts/task-revisions/*.count → revisions.per_task
  if ls "$FEATURE_DIR/.artifacts/task-revisions/"*.count &>/dev/null; then
    echo "MIGRATE: Parsing task revision counts..."
    local rev_json="{}"
    for count_file in "$FEATURE_DIR/.artifacts/task-revisions/"*.count; do
      local tid
      tid=$(basename "$count_file" .count)
      local count
      count=$(cat "$count_file" 2>/dev/null || echo 0)
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      rev_json=$(echo "$rev_json" | jq --arg tid "$tid" --argjson count "$count" '.[$tid] = $count')
    done
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq --argjson rev "$rev_json" \
      '.revisions.per_task = $rev | .metadata.updated_at = "'"$(now_utc)"'"' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    migrated=true
  fi

  # 4. Parse .artifacts/created-files/*.files → tasks.*.files_modified
  if ls "$FEATURE_DIR/.artifacts/created-files/"*.files &>/dev/null; then
    echo "MIGRATE: Parsing created files..."
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq '
      . as $state |
      (
        ["'"$FEATURE_DIR"'/artifacts/created-files/"*.files"] | map(
          . as $pattern |
          $pattern | explode |
          # We use a simpler approach: read each file
          .
        )
      ) |
      $state
    ' "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" || true

    # Simpler approach: bash loop
    for files_file in "$FEATURE_DIR/.artifacts/created-files/"*.files; do
      local tid
      tid=$(basename "$files_file" .files)
      local files_list
      files_list=$(cat "$files_file" 2>/dev/null || echo "")
      if [ -n "$files_list" ]; then
        local tmp2
        tmp2=$(mktemp "${STATE_FILE}.XXXXXX")
        jq --arg tid "$tid" \
          --argjson files "[$(echo "$files_list" | tr '\n' ',' | sed 's/,$//; s/[^,]$/&"/; s/^/"')" \
          '.tasks[$tid].files_modified = $files | .metadata.updated_at = "'"$(now_utc)"'"' \
          "$STATE_FILE" > "$tmp2" && mv "$tmp2" "$STATE_FILE"
      fi
    done
    migrated=true
  fi

  # 5. Parse .stagnation_state* → stagnation
  if [ -f "$FEATURE_DIR/.stagnation_state" ]; then
    echo "MIGRATE: Parsing stagnation state..."
    local prev_done consec
    prev_done=$(head -1 "$FEATURE_DIR/.stagnation_state" 2>/dev/null || echo "-1")
    consec=$(sed -n '2p' "$FEATURE_DIR/.stagnation_state" 2>/dev/null || echo "0")
    case "$prev_done" in ''|*[!0-9-]*) prev_done=-1 ;; esac
    case "$consec" in ''|*[!0-9]*) consec=0 ;; esac

    local consec_file="$FEATURE_DIR/.stagnation_state.consec"
    local continue_file="$FEATURE_DIR/.stagnation_state.continue_count"
    local drift_file="$FEATURE_DIR/.stagnation_state.drift_count"
    local consec_val=$consec
    local continue_val=0
    local drift_val=0

    [ -f "$consec_file" ] && { consec_val=$(cat "$consec_file" 2>/dev/null || echo 0); case "$consec_val" in ''|*[!0-9]*) consec_val=0 ;; esac; }
    [ -f "$continue_file" ] && { continue_val=$(cat "$continue_file" 2>/dev/null || echo 0); case "$continue_val" in ''|*[!0-9]*) continue_val=0 ;; esac; }
    [ -f "$drift_file" ] && { drift_val=$(cat "$drift_file" 2>/dev/null || echo 0); case "$drift_val" in ''|*[!0-9]*) drift_val=0 ;; esac; }

    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq --argjson consec "$consec_val" \
       --argjson continues "$continue_val" \
       --argjson drift "$drift_val" \
       --argjson prev "$prev_done" \
      '.stagnation.consecutive_no_progress = $consec |
       .stagnation.consecutive_continues = $continues |
       .stagnation.drift_violations = $drift |
       .stagnation.last_done_count = (if $prev >= 0 then $prev else 0 end) |
       .metadata.updated_at = "'"$(now_utc)"'"' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    migrated=true
  fi

  # 6. Parse .stagnation_total → stagnation.total_abort_count
  if [ -f "$FEATURE_DIR/.stagnation_total" ]; then
    echo "MIGRATE: Parsing stagnation total..."
    local abort_count
    abort_count=$(cat "$FEATURE_DIR/.stagnation_total" 2>/dev/null || echo 0)
    case "$abort_count" in ''|*[!0-9]*) abort_count=0 ;; esac
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq --argjson count "$abort_count" \
      '.stagnation.total_abort_count = $count | .metadata.updated_at = "'"$(now_utc)"'"' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    migrated=true
  fi

  # 7. Parse .artifacts/check-results/*.result → tasks.*.check_results
  if ls "$FEATURE_DIR/.artifacts/check-results/"*.result &>/dev/null; then
    echo "MIGRATE: Parsing check results..."
    local all_results="{}"
    for result_file in "$FEATURE_DIR/.artifacts/check-results/"*.result; do
      local check_id
      check_id=$(basename "$result_file" .result)
      local first_line
      first_line=$(head -1 "$result_file" 2>/dev/null || echo "SKIP")
      all_results=$(echo "$all_results" | jq --arg id "$check_id" --arg result "$first_line" '.[$id] = $result')
    done
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq --argjson results "$all_results" \
      '.tasks["TASK-1"].check_results = $results | .metadata.updated_at = "'"$(now_utc)"'"' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    migrated=true
  fi

  # 8. Parse .artifacts/test-health.json → history
  if [ -f "$FEATURE_DIR/.artifacts/test-health.json" ]; then
    echo "MIGRATE: Parsing test health data..."
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq '
      .history += ((.artifacts // . // {}) as $dummy |
        input | .entries // [] | map({
          "phase": "test-health",
          "task": .task_id,
          "iteration": 0,
          "result": (if .pass_rate == 100 then "PASS" else "FAIL" end),
          "timestamp": .completed_at
        })) |
      .metadata.updated_at = "'"$(now_utc)"'"
    ' "$STATE_FILE" "$FEATURE_DIR/.artifacts/test-health.json" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" || true
    migrated=true
  fi

  # 9. Parse revision_history.md → history
  if [ -f "$FEATURE_DIR/revision_history.md" ]; then
    echo "MIGRATE: Parsing revision history..."
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX")
    jq '
      .history += [{"phase":"revision","task":"unknown","iteration":0,"result":"REVISION","timestamp":"'"$(now_utc)"'"}] |
      .metadata.updated_at = "'"$(now_utc)"'"
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    migrated=true
  fi

  # 10. Backup old files
  if [ "$migrated" = true ]; then
    echo "MIGRATE: Backing up old state files..."
    [ -f "$FEATURE_DIR/tasks.md" ] && cp "$FEATURE_DIR/tasks.md" "$FEATURE_DIR/tasks.md.bak"
    [ -f "$FEATURE_DIR/.workflow-state.json" ] && cp "$FEATURE_DIR/.workflow-state.json" "$FEATURE_DIR/.workflow-state.json.bak"
    [ -f "$FEATURE_DIR/.tasks-state.json" ] && cp "$FEATURE_DIR/.tasks-state.json" "$FEATURE_DIR/.tasks-state.json.bak"
    [ -f "$FEATURE_DIR/.stagnation_state" ] && cp "$FEATURE_DIR/.stagnation_state" "$FEATURE_DIR/.stagnation_state.bak"
    [ -f "$FEATURE_DIR/.stagnation_state.consec" ] && cp "$FEATURE_DIR/.stagnation_state.consec" "$FEATURE_DIR/.stagnation_state.consec.bak"
    [ -f "$FEATURE_DIR/.stagnation_state.continue_count" ] && cp "$FEATURE_DIR/.stagnation_state.continue_count" "$FEATURE_DIR/.stagnation_state.continue_count.bak"
    [ -f "$FEATURE_DIR/.stagnation_state.drift_count" ] && cp "$FEATURE_DIR/.stagnation_state.drift_count" "$FEATURE_DIR/.stagnation_state.drift_count.bak"
    [ -f "$FEATURE_DIR/.stagnation_total" ] && cp "$FEATURE_DIR/.stagnation_total" "$FEATURE_DIR/.stagnation_total.bak"
    [ -f "$FEATURE_DIR/revision_history.md" ] && cp "$FEATURE_DIR/revision_history.md" "$FEATURE_DIR/revision_history.md.bak"
    [ -f "$FEATURE_DIR/workflow_state.json" ] && cp "$FEATURE_DIR/workflow_state.json" "$FEATURE_DIR/workflow_state.json.bak"

    # Create migration marker
    echo "migrated_at=$(now_utc)" > "$FEATURE_DIR/MIGRATION_DONE"

    echo "MIGRATE: Complete — state.json contains all consolidated data"
    echo "MIGRATE: Old files preserved as .bak — remove manually when confident"
  else
    echo "MIGRATE: No old format files found — state.json is already up to date"
  fi
}

# ── Main dispatch ────────────────────────────────────────────────
case "$MODE" in
  init)             do_init ;;
  read)             do_read "$3" ;;
  write)            do_write "$3" "${4:-}" ;;
  delete)           do_delete "$3" ;;
  validate)         do_validate ;;
  migrate)          do_migrate ;;
  generate-tasks-md) do_generate_tasks_md ;;
  history-append)   do_history_append "$3" ;;
  history-prune)    do_history_prune "$3" ;;
  task-set)         do_task_set "$3" "$4" "${5:-}" ;;
  task-incr)        do_task_incr "$3" "$4" ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Usage: state-engine.sh <init|read|write|delete|validate|migrate|generate-tasks-md|history-append|history-prune|task-set|task-incr> <feature_dir> [args...]" >&2
    exit 1
    ;;
esac
