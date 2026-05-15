# ── Context window overflow protection (Fix 9) ──────────────────
# Usage: speckit.context [--max-lines N]
# Default max-lines: 500. Reduces context when plan.md sections are too large.
# Priority-based truncation: high-priority sections always included,
# medium-priority truncated to 200 lines, low-priority elided.

# Parse --max-lines from input.args if provided
MAX_LINES=500
if input.args contains "--max-lines "; then
  MAX_LINES = extract the number after "--max-lines "
fi

# Load unified context for the next task
FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
if [ -z "$FEATURE_DIR" ]; then
  echo "No feature directory found. Run /speckit.plan first."
  exit 0
fi

# Find next TODO task and generate targeted context with --max-lines
NEXT_TASK=$(bash scripts/prompt-context.sh --max-lines "$MAX_LINES" "$FEATURE_DIR" || echo "")
if [ -z "$NEXT_TASK" ]; then
  echo "No unblocked tasks. Run /speckit.status."
  exit 0
fi

# Extract task_id and task_type from prompt-context output
TASK_ID=$(echo "$NEXT_TASK" | grep -oE 'TASK-[0-9]+' | head -1 || echo "TASK-1")
TASK_TYPE=$(echo "$NEXT_TASK" | grep -oE 'backend-domain|backend-infra|backend-api|shared|integration|frontend-data|frontend-feature|e2e' | head -1 || echo "backend-domain")

# Generate unified context with truncation
bash scripts/unified-context.sh --max-lines "$MAX_LINES" "$FEATURE_DIR" "$TASK_ID" "$TASK_TYPE" > /dev/null 2>&1

# Read unified context
Read .artifacts/unified-context.json.

# Check for IN_PROGRESS tasks first
# If unified-context shows an IN_PROGRESS task:
#   Print compact context for this IN_PROGRESS task.
#   Stop.

Print: Next task: [task.id] — [task.title] | Type: [task.type] | Scope: [task.scope]

# ── Apply --max-lines truncation (Issue E) ──────────────────────
# If --max-lines N was specified:
#   Count the total lines of the context output.
#   If lines > N, remove the least critical sections first:
#     1. Remove CONSTRAINTS TO WATCH (keep only most relevant 1-2)
#     2. Trim KEY NAMES to only the 3-5 most relevant terms
#     3. Compress RELEVANT SPEC to bullet points (no verbatim)
#   If still over N: truncate RELEVANT SPEC to first N/3 lines.
#   Append: "[Output truncated to --max-lines N. Full details in plan.md]"

Print compact context:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CONTEXT LOADED — [task.id]: [task.title] | Type: [task.type]

RELEVANT SPEC:
  [from plan_sections — verbatim content]

KEY NAMES (§2 + §4):
  [from plan_sections with section matching §2 or §4]

LAYER RULES:
  [from layer_rules for relevant layers]

CONSTRAINTS TO WATCH (§16):
  [from constraints.rules]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TASK SUMMARY (confirm before coding):
  What I will build: [one sentence from task title + acceptance criteria]
  Files I will create: [from Scope.Creates]
  Files I will modify: [from Scope.Modifies]
  Files I will NOT touch: [adjacent files that should remain unchanged]
  Definition of done: [checkable conditions from task]
  Assumptions I am making: [list, or "none"]

Wait for user confirmation before implementing.
Do NOT write any code until the user confirms this summary is correct.

Context ready. Run /speckit.implement to begin.
Do not implement from this command.
