#!/usr/bin/env bash
# validate-workflow-dag.sh — Validate goto references in workflow phase files
#
# Usage: scripts/validate-workflow-dag.sh [--phases-dir DIR]
#
# Parses all phase YAML files for `- goto:` references.
# Validates each goto target exists in a step ID map.
# Validates goto is within same loop scope OR is a valid cross-phase reference.
#
# Outputs: DAG_VALID=true|false, DAG_ERRORS=[list], CROSS_PHASE_GOTOS=[list]

set -euo pipefail

PHASES_DIR="${1:-workflows/phases}"

if [ ! -d "$PHASES_DIR" ]; then
  echo "ERROR: Phases directory not found: $PHASES_DIR" >&2
  echo "DAG_VALID=false"
  exit 1
fi

# Whitelist of allowed cross-phase goto targets (from workflow-config.json)
# abort — control flow keyword (handled separately)
CONFIG_FILE="ddd-clean-arch/workflow-config.json"
if [ -f "$CONFIG_FILE" ]; then
  CROSS_PHASE_WHITELIST=$(jq -r '.dag.cross_phase_goto // [] | .[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
else
  # Fallback: hardcoded whitelist if config missing
  CROSS_PHASE_WHITELIST="cl_round fix_needed_round impl_loop"
fi

ERRORS=()
CROSS_PHASE_GOTOS=()
DAG_VALID=true

# For each phase file, extract step IDs and validate goto references
for phase_file in "$PHASES_DIR"/*.yml; do
  phase_name=$(basename "$phase_file")

  # Extract all step IDs in this phase (lines matching "  - id: <name>" or "    - id: <name>")
  declare -A step_ids=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*(.+) ]]; then
      id=$(echo "${BASH_REMATCH[1]}" | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//')
      step_ids["$id"]=1
    fi
  done < "$phase_file"

  # Find all goto references in this phase file
  while IFS= read -r goto_line; do
    # Extract the goto target (handle "- goto: target" and "            - goto: target")
    if [[ "$goto_line" =~ goto:[[:space:]]*(.+) ]]; then
      target=$(echo "${BASH_REMATCH[1]}" | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//;s/[[:space:]]*$//')

      # Skip empty targets
      if [ -z "$target" ]; then
        continue
      fi

      # Special case: "abort" is a control flow keyword, not a step ID
      if [ "$target" = "abort" ]; then
        continue
      fi

      # Check if target exists in this phase's step IDs
      if [ "${step_ids[$target]+isset}" ]; then
        # Same-phase goto — valid (target exists in this phase)
        continue
      fi

      # Cross-phase goto — check whitelist
      is_whitelisted=false
      for allowed in $CROSS_PHASE_WHITELIST; do
        if [ "$target" = "$allowed" ]; then
          is_whitelisted=true
          CROSS_PHASE_GOTOS+=("${phase_name}:${target}")
          break
        fi
      done

      if $is_whitelisted; then
        # Whitelisted cross-phase goto — valid
        continue
      fi

      # Not found and not whitelisted — error
      DAG_VALID=false
      ERRORS+=("Invalid goto target '${target}' in ${phase_name}: '${target}' not found as step ID and not in cross-phase whitelist")
    fi
  done < <(grep -n 'goto:' "$phase_file" 2>/dev/null || true)

  unset step_ids
done

# Output results
echo "DAG_VALID=${DAG_VALID}"

if [ ${#ERRORS[@]} -gt 0 ]; then
  for err in "${ERRORS[@]}"; do
    echo "DAG_ERROR: ${err}"
  done
fi

if [ ${#CROSS_PHASE_GOTOS[@]} -gt 0 ]; then
  for cp in "${CROSS_PHASE_GOTOS[@]}"; do
    echo "CROSS_PHASE_GOTO: ${cp}"
  done
fi

if $DAG_VALID; then
  echo "DAG validation passed: all goto targets resolved"
  exit 0
else
  echo "DAG validation failed: ${#ERRORS[@]} error(s) found" >&2
  exit 1
fi
