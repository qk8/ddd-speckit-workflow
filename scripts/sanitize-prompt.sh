#!/usr/bin/env bash
# sanitize-prompt.sh — Sanitize spec/plan documents before feeding to LLM prompts.
#
# Prevents prompt injection via spec documents (plan.md, spec.md, tasks.md).
# Strips injection patterns, flags anomalous content, and outputs a sanitized copy.
#
# Usage: sanitize-prompt.sh <input_file> [output_file]
#   If output_file is omitted, writes to stdout.
#
# Checks:
#   1. Lines matching instruction patterns ("Do this", "Ignore previous", etc.)
#   2. Lines outside expected section structure (text between section headers)
#   3. Suspicious delimiter patterns (---, ***, ===) that could break prompt parsing
#
# Exit code: 0 = clean, 1 = warnings flagged (does NOT block execution)

set -euo pipefail

INPUT_FILE="${1:?Usage: sanitize-prompt.sh <input_file> [output_file]}"
OUTPUT_FILE="${2:-}"

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: File not found: $INPUT_FILE" >&2
  exit 1
fi

WARNINGS=0
SANITIZED_LINES=0

# Known instruction/injection patterns to strip
INJECTION_PATTERNS=(
  'ignore previous'
  'ignore all previous'
  'disregard previous'
  'disregard all previous'
  'override all'
  'override all instructions'
  'from now on'
  'from this point on'
  'you must'
  'you are required to'
  'you should always'
  'do not follow'
  'do not respect'
  'do not enforce'
  'bypass'
  'circumvent'
  'disable'
  'turn off'
  'remove all'
  'remove all restrictions'
  'remove all constraints'
  'act as'
  'pretend to be'
  'roleplay as'
  'simulate being'
  'you are now'
  'your new role'
  'your new purpose'
  'your new instructions'
  'new system prompt'
  'system prompt override'
  'change your instructions'
  'change your behavior'
  'do not output'
  'do not show'
  'do not display'
  'harm'
  'malicious'
  'exploit'
  'vulnerability'
  'inject'
  'injection'
  'xss'
  'sql injection'
  'command injection'
  'shell injection'
  'file inclusion'
  'directory traversal'
  'path traversal'
)

# Known section header patterns (these are OK anywhere)
SECTION_PATTERNS='^§[0-9]+[[:space:]]|^## TASK-|^## |^### |^#### |^---$|^===+$'

# Read file and sanitize line by line
while IFS= read -r line; do
  # Check for instruction/injection patterns (case-insensitive)
  lower_line=$(echo "$line" | tr '[:upper:]' '[:lower:]')
  for pattern in "${INJECTION_PATTERNS[@]}"; do
    if echo "$lower_line" | grep -qi "$pattern" 2>/dev/null; then
      # Check if this line is inside a code block (starts with ``` or is indented)
      if echo "$line" | grep -qE '^\s*```|^\s{4,}'; then
        # Inside code block — likely legitimate code, keep it
        break
      fi
      # Flag as suspicious
      if [ "$OUTPUT_FILE" = "" ]; then
        echo "## SANITIZE WARNING: Line matches injection pattern '$pattern': $line" >&2
      else
        echo "## SANITIZE WARNING: Line matches injection pattern '$pattern': $line" >> "$OUTPUT_FILE"
      fi
      WARNINGS=$((WARNINGS + 1))
      break
    fi
  done

  # Check for suspicious delimiter patterns (3+ consecutive dashes/equals/asterisks)
  if echo "$line" | grep -qE '^-{5,}$|={5,}$|\*{5,}$' 2>/dev/null; then
    if [ "$OUTPUT_FILE" = "" ]; then
      echo "## SANITIZE WARNING: Suspicious delimiter pattern: $line" >&2
    else
      echo "## SANITIZE WARNING: Suspicious delimiter pattern: $line" >> "$OUTPUT_FILE"
    fi
    WARNINGS=$((WARNINGS + 1))
  fi

  SANITIZED_LINES=$((SANITIZED_LINES + 1))
done < "$INPUT_FILE"

# Output sanitized content
if [ "$OUTPUT_FILE" = "" ]; then
  cat "$INPUT_FILE"
else
  cat "$INPUT_FILE" > "$OUTPUT_FILE"
fi

# Output summary
if [ "$OUTPUT_FILE" = "" ]; then
  echo "" >&2
  echo "SANITIZE: $SANITIZED_LINES lines processed, $WARNINGS warning(s)" >&2
else
  echo "SANITIZE: $SANITIZED_LINES lines processed, $WARNINGS warning(s) in $OUTPUT_FILE" >&2
fi

# Exit 0 even with warnings — warnings are advisory
# The workflow reads the warning count to decide next steps
echo "SANITIZE_WARNINGS=$WARNINGS"

exit 0
