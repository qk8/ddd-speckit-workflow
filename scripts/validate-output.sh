#!/usr/bin/env bash
# Usage: ./scripts/validate-output.sh <script_to_run> [schema_file]
#
# Sources a script's output and validates variable types against a schema.
# Catches format regressions early — before the workflow YAML consumes
# the output and silently gets wrong values.
#
# Schema file format (YAML-like, key=value per line):
#   variable_name: type
# where type is one of: int, bool, path, list, text, optional
#
# If no schema file is provided, uses built-in schemas for known scripts.
#
# Output: PASS or FAIL with details. Exits 0 on pass, 1 on fail.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "ERROR: script path is required" >&2
  echo "Usage: $0 <script_to_run> [schema_file] [script_args...]" >&2
  exit 2
fi

SCRIPT_TO_RUN="$1"
SCHEMA_FILE="${2:-}"
shift 2 2>/dev/null || true
SCRIPT_ARGS=("$@")

# Built-in schemas for known scripts
# Format: "variable_name:type" per line
get_builtin_schema() {
  local script_name
  script_name=$(basename "$1" .sh)
  case "$script_name" in
    check-tasks)
      cat <<'SCHEMA'
has_todo:bool
done_count:int
todo_count:int
in_progress:optional
in_progress_all:optional
abandoned_count:int
total_tasks:int
complexity:text
retro_interval:int
first_retro_threshold:int
retro_trigger:bool
feature_dir:optional
SCHEMA
      ;;
    validate-tests)
      cat <<'SCHEMA'
TEST_EXIT_CODE:int
TEST_RESULT:text
TEST_TOTAL:int
TEST_PASSED:int
TEST_FAILED:int
TEST_SKIPPED:int
TEST_OUTPUT_FILE:path
TEST_SUMMARY:text
SCHEMA
      ;;
    check-tasks-safe)
      cat <<'SCHEMA'
TASKS_PARSE_ERROR:optional
has_todo:bool
done_count:int
todo_count:int
in_progress:optional
in_progress_all:optional
abandoned_count:int
total_tasks:int
complexity:text
retro_interval:int
first_retro_threshold:int
retro_trigger:bool
feature_dir:optional
SCHEMA
      ;;
  esac
}

# Determine schema
if [ -n "$SCHEMA_FILE" ] && [ -f "$SCHEMA_FILE" ]; then
  SCHEMA="$SCHEMA_FILE"
else
  SCHEMA_DATA=$(get_builtin_schema "$SCRIPT_TO_RUN" 2>/dev/null) || {
    echo "ERROR: no schema found for $SCRIPT_TO_RUN" >&2
    echo "Provide a schema file as the second argument." >&2
    exit 2
  }
  # Write schema to temp file for parsing
  SCHEMA=$(mktemp /tmp/schema-XXXXXX)
  echo "$SCHEMA_DATA" > "$SCHEMA"
  trap 'rm -f "$SCHEMA"' EXIT
fi

# Run the script and capture output
OUTPUT=$(bash "$SCRIPT_TO_RUN" "${SCRIPT_ARGS[@]}" 2>/dev/null) || {
  echo "FAIL: $SCRIPT_TO_RUN exited non-zero" >&2
  echo "Raw output:" >&2
  bash "$SCRIPT_TO_RUN" "${SCRIPT_ARGS[@]}" 2>&1 >&2 || true
  exit 1
}

# Parse schema into temp file: "var_name\tvar_type" per line (tab-separated)
SCHEMA_PARSED=$(mktemp /tmp/schema-parsed-XXXXXX)
OUTPUT_PARSED=$(mktemp /tmp/output-parsed-XXXXXX)
trap 'rm -f "$SCHEMA" "$SCHEMA_PARSED" "$OUTPUT_PARSED"' EXIT

while IFS=: read -r var_name var_type; do
  [[ -z "$var_name" || "$var_name" =~ ^# ]] && continue
  printf '%s\t%s\n' "$var_name" "$var_type"
done < "$SCHEMA" > "$SCHEMA_PARSED"

# Parse output into temp file: "key\tvalue" per line
while IFS='=' read -r key value; do
  [[ -z "$key" ]] && continue
  printf '%s\t%s\n' "$key" "$value"
done <<< "$OUTPUT" > "$OUTPUT_PARSED"

# Lookup function: search temp file for var_name, return the value or ""
lookup_var() {
  local target="$1" file="$2"
  grep -m1 "^${target}	" "$file" 2>/dev/null | cut -f2- || true
}

# Validate each expected variable
FAILURES=0
while IFS='	' read -r var_name expected_type; do
  value=$(lookup_var "$var_name" "$OUTPUT_PARSED")

  # Check if variable exists
  if [ -z "$value" ] && [ "$expected_type" != "optional" ]; then
    echo "FAIL: missing required variable '$var_name'" >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  # Skip type check for optional missing variables
  if [ -z "$value" ] && [ "$expected_type" = "optional" ]; then
    continue
  fi

  # Type validation
  case "$expected_type" in
    int)
      if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
        echo "FAIL: '$var_name' expected int, got '$value'" >&2
        FAILURES=$((FAILURES + 1))
      fi
      ;;
    bool)
      if [ "$value" != "true" ] && [ "$value" != "false" ]; then
        echo "FAIL: '$var_name' expected bool (true|false), got '$value'" >&2
        FAILURES=$((FAILURES + 1))
      fi
      ;;
    path)
      # Accept relative paths (.specify/...) OR absolute paths (/)
      if ! [[ "$value" =~ ^(/|\./) ]]; then
        echo "FAIL: '$var_name' expected path, got '$value'" >&2
        FAILURES=$((FAILURES + 1))
      fi
      ;;
    list)
      # List is comma-separated, allow empty
      : # no strict validation needed
      ;;
    text|optional)
      : # any non-empty string is valid
      ;;
    *)
      echo "WARN: unknown type '$expected_type' for '$var_name', skipping" >&2
      ;;
  esac
done < "$SCHEMA_PARSED"

if [ "$FAILURES" -gt 0 ]; then
  echo "FAIL: $FAILURES validation error(s)" >&2
  exit 1
else
  echo "PASS: all variables validated"
  exit 0
fi
