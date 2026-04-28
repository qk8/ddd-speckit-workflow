#!/usr/bin/env bash
# Wrapper for check-tasks.sh that handles failures gracefully.
# If check-tasks.sh fails (malformed tasks.md, missing files), outputs safe defaults.
# Usage: bash scripts/check-tasks-safe.sh
#
# Output: same key=value format as check-tasks.sh, but guaranteed to never fail.

set -euo pipefail

OUTPUT=$(bash scripts/check-tasks.sh 2>/dev/null) || {
  echo "WARNING: check-tasks.sh failed — using safe defaults" >&2
  source scripts/cadence-defaults.sh
  cat <<DEFAULTS
has_todo=false
done_count=0
todo_count=0
in_progress=
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
