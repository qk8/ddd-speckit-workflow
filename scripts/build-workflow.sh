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

ORCHESTRATOR="ddd-workflow.yml"
OUTPUT="/dev/stdout"
VALIDATE=""

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

if [ ! -f "$ORCHESTRATOR" ]; then
  echo "ERROR: Orchestrator not found: $ORCHESTRATOR" >&2
  exit 1
fi

# Extract header (everything before `imports:`)
HEADER=$(sed '/^imports:/,$d' "$ORCHESTRATOR")

# Extract import paths
IMPORT_PATHS=$(grep -E '^\s+- ' "$ORCHESTRATOR" | sed 's/^  - //' | grep '\.yml$')

# extract_steps FILE — print indented steps from a YAML file
extract_steps() {
  local file="$1"
  local IN_STEPS=false SKIP_BLANKS=true
  while IFS= read -r line; do
    if [[ "$line" =~ ^steps: ]]; then
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
}

# Start building output
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
} > "$OUTPUT"

echo "Build complete: $(wc -l < "$OUTPUT") lines → $OUTPUT" >&2

# Optional DAG validation
if [ "$VALIDATE" = "--validate" ]; then
  echo "" >&2
  echo "Running DAG validation..." >&2
  bash scripts/validate-workflow-dag.sh || {
    echo "DAG validation failed — aborting build" >&2
    exit 1
  }
  echo "DAG validation passed." >&2
fi
