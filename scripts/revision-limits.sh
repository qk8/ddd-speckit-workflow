#!/usr/bin/env bash
set -euo pipefail
# Central revision limits configuration.
# All retry-limit scripts source this file instead of hardcoding values.
# This ensures a single source of truth for "how many retries does this task have left?"
#
# Usage: source scripts/revision-limits.sh
#
# Variables exported:
#   MAX_REVISIONS          — per-task revision limit (default: 3)
#   MAX_DRIFT_REVISIONS   — drift revision limit per retro cycle (default: 2)
#   MAX_SPEC_REVISIONS    — spec revision limit (default: 3)
#   GLOBAL_CORRECTION_CAP — max correction attempts per task (default: 10)
#   STAGNATION_THRESHOLD  — adaptive, computed from total_tasks
#
# Override defaults by setting the variable before sourcing:
#   MAX_REVISIONS=5 source scripts/revision-limits.sh

# ── Per-task revision limit ────────────────────────────────────────
: "${MAX_REVISIONS:=3}"

# ── Drift revision limit (per retro cycle, global) ────────────────
: "${MAX_DRIFT_REVISIONS:=2}"

# ── Spec revision limit (global) ──────────────────────────────────
: "${MAX_SPEC_REVISIONS:=3}"

# ── Global correction cap per task ────────────────────────────────
: "${GLOBAL_CORRECTION_CAP:=10}"

# ── Adaptive stagnation threshold ─────────────────────────────────
# Must be called after TOTAL_TASKS is set.
# Usage: compute_stagnation_threshold <total_tasks>
compute_stagnation_threshold() {
  local total="${1:-10}"
  if [ "$total" -le 10 ]; then
    echo 3
  elif [ "$total" -le 50 ]; then
    local t=$(( (total + 9) / 10 ))
    [ "$t" -lt 4 ] && t=4
    echo "$t"
  else
    local t=$(( (total + 19) / 20 ))
    [ "$t" -lt 5 ] && t=5
    echo "$t"
  fi
}
