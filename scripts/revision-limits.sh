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

# ── Stagnation threshold by task type ─────────────────────────────
# Returns type-specific thresholds to reduce false positives for complex tasks.
# Usage: compute_stagnation_threshold_by_type <task_type>
# Thresholds: backend-domain=10, backend-api=7, e2e=8, shared=5,
#             backend-infra=7, frontend-data=6, frontend-feature=7, default=5
compute_stagnation_threshold_by_type() {
  local task_type="${1:-default}"
  case "$task_type" in
    backend-domain)    echo 10 ;;
    backend-api)       echo 7 ;;
    e2e)               echo 8 ;;
    shared)            echo 5 ;;
    backend-infra)     echo 7 ;;
    frontend-data)     echo 6 ;;
    frontend-feature)  echo 7 ;;
    spec_revision)     echo 5 ;;
    *)                 echo 5 ;;
  esac
}
