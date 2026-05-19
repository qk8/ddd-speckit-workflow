#!/usr/bin/env bash
# build-workflow.sh — Merge orchestrator + phase files into runtime YAML
#
# Usage: scripts/build-workflow.sh [orchestrator_path] [output_path] [--validate]
#
# Reads the orchestrator's imports list, extracts `steps:` sections from
# each phase file (and its auto-discovered sub-phase files), and produces
# a single flat YAML suitable for the workflow engine.
#
# Sub-phase discovery: files matching NN-name-*.yml (excluding the main
# phase file) in the same directory are processed in alphabetical order
# after the main phase file.
#
# Output: merged YAML to stdout (or to output_path).
# --validate: Run DAG validation on goto references after merge.

set -euo pipefail

# ── Check for yq (YAML parser) — use if available for robust parsing ──
HAS_YQ=false
if command -v yq &>/dev/null; then
  HAS_YQ=true
else
  echo "WARNING: yq not found — using text-based YAML parser (less robust). Install yq for reliable parsing." >&2
fi

ORCHESTRATOR="ddd-workflow.yml"
OUTPUT="/dev/stdout"
VALIDATE=""
TMP_BUILD=""

MERGE_PRESET_DIR=""
MERGE_PRESET_NEXT=false
MANIFEST=""
MANIFEST_NEXT=false

# Parse arguments: positional args for orchestrator/output, --validate, --merge-preset, --manifest
POS_ARGS=()
for arg in "$@"; do
  if [ "$MERGE_PRESET_NEXT" = true ]; then
    MERGE_PRESET_DIR="$arg"
    MERGE_PRESET_NEXT=false
    continue
  fi
  if [ "$MANIFEST_NEXT" = true ]; then
    MANIFEST="$arg"
    MANIFEST_NEXT=false
    continue
  fi
  case "$arg" in
    --validate) VALIDATE="--validate" ;;
    --merge-preset)
      MERGE_PRESET_NEXT=true
      ;;
    --manifest)
      MANIFEST_NEXT=true
      ;;
    *) POS_ARGS+=("$arg") ;;
  esac
done

ORCHESTRATOR="${POS_ARGS[0]:-ddd-workflow.yml}"
OUTPUT="${POS_ARGS[1]:-/dev/stdout}"

# Issue 10: Auto-detect manifest in standard location if not specified
if [ -z "$MANIFEST" ]; then
  MANIFEST="workflows/phases/.sub-phase-manifest"
  if [ ! -f "$MANIFEST" ]; then
    MANIFEST=""
  fi
fi

# Use a temp file for the build output to avoid /dev/stdout hang
# when stdout is redirected (wc -l and grep hang reading from /dev/stdout)
TMP_BUILD=$(mktemp "${OUTPUT:-/dev/stdout}.XXXXXX" 2>/dev/null || mktemp /tmp/build-workflow-XXXXXX.yml)
trap 'rm -f "$TMP_BUILD"' EXIT

if [ ! -f "$ORCHESTRATOR" ]; then
  echo "ERROR: Orchestrator not found: $ORCHESTRATOR" >&2
  exit 1
fi

# Extract header (everything before `imports:`)
HEADER=$(sed '/^imports:/,$d' "$ORCHESTRATOR")

# Extract import paths
IMPORT_PATHS=$(grep -E '^\s+- ' "$ORCHESTRATOR" | sed 's/^  - //' | grep '\.yml$')

# extract_steps FILE — print indented steps from a YAML file
# Uses yq if available (robust), falls back to text-based parser.
extract_steps() {
  local file="$1"
  if $HAS_YQ; then
    # yq-based: proper YAML parsing, handles strings containing "steps:", comments, multi-line strings
    yq '.steps[]' "$file" 2>/dev/null | sed 's/^/  /' || true
  else
    # Text-based fallback: improved parser that tracks YAML context.
    # Only matches 'steps:' at depth 0 (no leading whitespace) to avoid
    # matching "steps:" inside YAML strings, comments, or nested keys.
    # Uses parameter expansion instead of grep to avoid stdin consumption.
    local IN_STEPS=false SKIP_BLANKS=true IN_QUOTE=false
    local STEP_DEPTH=0
    while IFS= read -r line; do
      # Skip comment lines
      [[ "$line" =~ ^[[:space:]]*# ]] && continue

      # Track quote state: toggle if we encounter an odd number of quotes
      local stripped="${line#"${line%%[![:space:]]*}"}"
      local quote_count
      local tmp="${stripped//[^\"]/}"
      quote_count="${#tmp}"
      if [ $((quote_count % 2)) -eq 1 ]; then
        if [ "$IN_QUOTE" = true ]; then IN_QUOTE=false; else IN_QUOTE=true; fi
      fi

      # If we're inside a quoted string, skip the line
      if $IN_QUOTE; then
        continue
      fi

      # Calculate indentation depth using parameter expansion (no grep)
      local no_leading="${line#"${line%%[![:space:]]*}"}"
      local leading_spaces=$(( ${#line} - ${#no_leading} ))

      # Detect 'steps:' key at depth 0 (no leading whitespace) only
      if [ "$leading_spaces" -eq 0 ] && [[ "$stripped" =~ ^steps:([[:space:]]|$) ]]; then
        IN_STEPS=true
        SKIP_BLANKS=true
        STEP_DEPTH=0
        continue
      fi

      if $IN_STEPS; then
        # If we hit a non-indented, non-empty line, we've left the steps block
        if [ "$leading_spaces" -eq 0 ] && [[ -n "$stripped" ]]; then
          break
        fi

        if $SKIP_BLANKS; then
          if [[ -z "$stripped" ]]; then
            continue
          fi
          SKIP_BLANKS=false
        fi

        if [[ -z "$stripped" ]]; then
          echo ""
          continue
        fi

        # Output indented content
        echo "  $line"
      fi
    done < "$file"
  fi
}

# Start building output (write to temp file to avoid /dev/stdout hang)
{
  echo "$HEADER"
  echo "steps:"

  for phase_file in $IMPORT_PATHS; do
    if [ ! -f "$phase_file" ]; then
      echo "# WARNING: Phase file not found: $phase_file (skipping)" >&2
      continue
    fi

    # Process main phase file
    extract_steps "$phase_file"

    # Discover and process sub-phase files
    PHASE_DIR=$(dirname "$phase_file")
    PHASE_BASE=$(basename "$phase_file")
    PHASE_PREFIX="${PHASE_BASE%.yml}"

    # Issue 10: Use manifest if provided, otherwise fall back to glob discovery
    if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
      # Use manifest: one sub-phase file per line, in execution order.
      # Only apply manifest to phases whose prefix matches the sub-phase prefix.
      MANIFEST_PREFIX="${PHASE_PREFIX%-*}"
      while IFS= read -r sub_name; do
        # Skip comments and empty lines
        [[ "$sub_name" =~ ^#.*$ ]] && continue
        [ -z "$sub_name" ] && continue
        # Skip sub-phases from other phases (e.g., 05-* when processing 01-*)
        SUB_PREFIX="${sub_name%-*}"
        [ "$SUB_PREFIX" != "$MANIFEST_PREFIX" ] && continue
        sub_file="$PHASE_DIR/$sub_name"
        [ -f "$sub_file" ] || continue
        [ "$sub_name" = "$PHASE_BASE" ] && continue
        extract_steps "$sub_file"
      done < "$MANIFEST"
    else
      # Fallback: glob discovery (with warning)
      echo "WARNING: No manifest specified — using glob discovery for sub-phases. " \
        "Create workflows/phases/.sub-phase-manifest for explicit control." >&2
      for sub_file in "$PHASE_DIR"/${PHASE_PREFIX}-*.yml; do
        [ -f "$sub_file" ] || continue
        # Skip the main phase file itself
        [ "$(basename "$sub_file")" = "$PHASE_BASE" ] && continue
        extract_steps "$sub_file"
      done
    fi

    # Add a comment separator between phases
    echo ""
    echo "  # ── End of phase: $(basename "$phase_file") ──"
    echo ""
  done
} > "$TMP_BUILD"

LINE_COUNT=$(wc -l < "$TMP_BUILD")
echo "Build complete: $LINE_COUNT lines → $OUTPUT" >&2

# Copy temp file to final output (stdout or file)
if [ "$OUTPUT" = "/dev/stdout" ]; then
  cat "$TMP_BUILD"
else
  cp "$TMP_BUILD" "$OUTPUT"
fi

# ── Pre-flight goto validation (always runs) ──────────────────────
# Extract all step IDs and all goto targets from the merged output.
# Report any goto targets that don't match a defined step ID.
echo "" >&2
echo "Running pre-flight goto validation..." >&2

# Collect all step IDs (lines matching "  - id: xxx")
STEP_IDS=$(grep -E '^\s+- id:' "$TMP_BUILD" 2>/dev/null | sed 's/.*- id: *//' | sort -u || true)

# Collect all goto targets (lines matching any indentation + goto: xxx)
GOTO_TARGETS=$(grep -E 'goto:' "$TMP_BUILD" 2>/dev/null | sed 's/.*goto: *//' | sort -u || true)

GOTO_ERRORS=0
for target in $GOTO_TARGETS; do
  # Skip built-in workflow engine keywords
  [ "$target" = "abort" ] && continue
  if ! echo "$STEP_IDS" | grep -qx "$target"; then
    echo "  ERROR: goto references undefined step '$target'" >&2
    GOTO_ERRORS=$((GOTO_ERRORS + 1))
  fi
done

if [ "$GOTO_ERRORS" -gt 0 ]; then
  echo "  Pre-flight validation found $GOTO_ERRORS broken goto reference(s)." >&2
  echo "  The workflow will fail at runtime. Fix the goto targets above and rebuild." >&2
  exit 1
fi

echo "  Pre-flight validation passed: all goto targets resolve to defined steps." >&2

# ── max_iterations sync validation ────────────────────────────────
# Compare YAML max_iterations with workflow-config.json iteration_limits.*
echo "" >&2
echo "Checking max_iterations sync with workflow-config.json..." >&2
CONFIG_FILE="ddd-clean-arch/workflow-config.json"
SYNC_ERRORS=0

if [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null 2>&1; then
  # Loop ID → config key mapping
  declare -A LOOP_TO_KEY
  LOOP_TO_KEY[impl_loop]="implement_loop"
  LOOP_TO_KEY[cl_round]="clarify_round"
  LOOP_TO_KEY[tasks_phase]="tasks_phase"
  LOOP_TO_KEY[spec_audit]="spec_audit"
  LOOP_TO_KEY[pl_review]="plan_review"
  LOOP_TO_KEY[fix_needed_round]="verify_fix_needed"
  LOOP_TO_KEY[cr_round]="code_review_round"

  # Extract max_iterations from merged YAML with loop context
  # We look for: - id: <loop_id> type: while → later max_iterations: N
  CURRENT_LOOP=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE '^\s+- id:'; then
      CURRENT_LOOP=$(echo "$line" | sed 's/.*- id: *//' | tr -d '"' | tr -d "'")
    fi
    if echo "$line" | grep -qE '^\s+max_iterations:' && [ -n "$CURRENT_LOOP" ]; then
      YAML_VAL=$(echo "$line" | sed 's/.*max_iterations: *//' | tr -d '"' | tr -d "'" | tr -d ' ')
      CONFIG_KEY="${LOOP_TO_KEY[$CURRENT_LOOP]:-}"
      if [ -n "$CONFIG_KEY" ]; then
        JSON_VAL=$(jq -r ".iteration_limits.${CONFIG_KEY} // \"MISSING\"" "$CONFIG_FILE" 2>/dev/null)
        case "$JSON_VAL" in
          MISSING|null)
            echo "  ERROR: $CURRENT_LOOP → config key '$CONFIG_KEY' not found in workflow-config.json" >&2
            SYNC_ERRORS=$((SYNC_ERRORS + 1))
            ;;
          *)
            if [ "$YAML_VAL" != "$JSON_VAL" ]; then
              echo "  ERROR: $CURRENT_LOOP — YAML=$YAML_VAL but config=$JSON_VAL" >&2
              SYNC_ERRORS=$((SYNC_ERRORS + 1))
            fi
            ;;
        esac
      fi
    fi
  done < "$TMP_BUILD"

  if [ "$SYNC_ERRORS" -eq 0 ]; then
    echo "  OK: All max_iterations values match workflow-config.json" >&2
  fi
fi

if [ "$SYNC_ERRORS" -gt 0 ]; then
  echo "  max_iterations sync failed — values must match workflow-config.json" >&2
fi

# Optional full DAG validation
if [ "$VALIDATE" = "--validate" ]; then
  echo "" >&2
  echo "Running full DAG validation..." >&2
  bash scripts/validate-workflow-dag.sh || {
    echo "DAG validation failed — aborting build" >&2
    exit 1
  }
  echo "DAG validation passed." >&2
fi

# ── Preset merging (optional) ─────────────────────────────────────
# Merges modular preset section files into a single preset.yml.
# Usage: build-workflow.sh --merge-preset <preset_directory>
if [ -n "$MERGE_PRESET_DIR" ]; then
  PRESET_WRAPPER="$MERGE_PRESET_DIR/preset.yml"
  if [ ! -f "$PRESET_WRAPPER" ]; then
    echo "ERROR: Preset wrapper not found: $PRESET_WRAPPER" >&2
    exit 1
  fi

  # Read _sections list from the wrapper
  SECTION_FILES=$(grep -A 20 '^_sections:' "$PRESET_WRAPPER" | grep '^\s*- ' | sed 's/^  - //' || true)
  if [ -z "$SECTION_FILES" ]; then
    echo "WARNING: No _sections found in $PRESET_WRAPPER — skipping preset merge" >&2
  else
    MERGED=$(mktemp "${PRESET_WRAPPER}.XXXXXX")

    # Write top-level keys (before _sections:)
    sed '/^_sections:/,$d' "$PRESET_WRAPPER" > "$MERGED"

    # Merge each section file
    for section in $SECTION_FILES; do
      SECTION_PATH="$MERGE_PRESET_DIR/$section"
      if [ -f "$SECTION_PATH" ]; then
        cat "$SECTION_PATH" >> "$MERGED"
        echo "" >> "$MERGED"
      else
        echo "WARNING: Section file not found: $SECTION_PATH" >&2
      fi
    done

    echo "Preset merged: $MERGED ($(wc -l < "$MERGED") lines)" >&2
    echo "  Sections merged: $(echo $SECTION_FILES | wc -w)" >&2
  fi
fi
