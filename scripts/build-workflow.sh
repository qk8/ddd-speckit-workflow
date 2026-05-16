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

# Parse arguments: positional args for orchestrator/output, --validate flag
POS_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --validate) VALIDATE="--validate" ;;
    *) POS_ARGS+=("$arg") ;;
  esac
done

ORCHESTRATOR="${POS_ARGS[0]:-ddd-workflow.yml}"
OUTPUT="${POS_ARGS[1]:-/dev/stdout}"

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
    # Text-based fallback: require steps: at column 0 (no leading whitespace) to avoid
    # matching "steps:" inside YAML strings or comments.
    local IN_STEPS=false SKIP_BLANKS=true
    while IFS= read -r line; do
      if [[ "$line" =~ ^steps:[[:space:]]*$ ]] || [[ "$line" == "steps:" ]]; then
        IN_STEPS=true
        SKIP_BLANKS=true
        continue
      fi
      if $IN_STEPS; then
        if $SKIP_BLANKS; then
          if [[ -z "$line" ]]; then
            continue
          fi
          SKIP_BLANKS=false
        fi
        if [[ -z "$line" ]]; then
          echo ""
          continue
        fi
        if [[ "$line" =~ ^[[:space:]] ]]; then
          echo "  $line"
        else
          break
        fi
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

    # Discover and process sub-phase files (NN-name-*.yml, excluding main)
    PHASE_DIR=$(dirname "$phase_file")
    PHASE_BASE=$(basename "$phase_file")
    PHASE_PREFIX="${PHASE_BASE%.yml}"
    # Match files like NN-name-sub.yml (prefix followed by -, at least one sub-char, then .yml)
    for sub_file in "$PHASE_DIR"/${PHASE_PREFIX}-*.yml; do
      [ -f "$sub_file" ] || continue
      # Skip the main phase file itself
      [ "$(basename "$sub_file")" = "$PHASE_BASE" ] && continue
      extract_steps "$sub_file"
    done

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
