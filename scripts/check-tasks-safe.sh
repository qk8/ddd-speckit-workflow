#!/usr/bin/env bash
# Wrapper for check-tasks.sh that handles failures gracefully.
# If check-tasks.sh fails (malformed tasks.md, missing files), outputs
# safe defaults AND signals TASKS_PARSE_ERROR=1 so the workflow can detect
# the condition instead of silently proceeding with wrong state.
# Usage: bash scripts/check-tasks-safe.sh
#
# Output: same key=value format as check-tasks.sh, plus TASKS_PARSE_ERROR=1
# on failure. Guaranteed to never exit non-zero.

set -euo pipefail

OUTPUT=$(bash scripts/check-tasks.sh 2>/dev/null) || {
  echo "TASKS_PARSE_ERROR=1"
  echo "ERROR: check-tasks.sh failed — tasks.md may be malformed or missing" >&2
  echo "       Run: bash scripts/check-tasks.sh (without safe wrapper) to diagnose" >&2
  set +e
  source scripts/cadence-defaults.sh
  set -e
  cat <<DEFAULTS
has_todo=false
done_count=0
todo_count=0
in_progress=
in_progress_all=
abandoned_count=0
total_tasks=0
complexity=medium
retro_interval=${CADENCE_RETRO_INTERVAL_MEDIUM}
first_retro_threshold=${CADENCE_FIRST_RETRO_THRESHOLD}
retro_trigger=false
feature_dir=
DEFAULTS
  exit 0
}

echo "$OUTPUT"
exit 0
