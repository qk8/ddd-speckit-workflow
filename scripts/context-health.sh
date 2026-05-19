#!/usr/bin/env bash
# ── Context Health Check ─────────────────────────────────────────
# Tracks context window age and artifact disk health to detect
# context window exhaustion in long LLM sessions.
#
# Usage: context-health.sh <feature_dir>
#
# Output: CONTEXT_HEALTH=HEALTHY|DEGRADED|CRITICAL
#         SESSION_AGE=N
#         RESET_THRESHOLD=N
#         RECOMMENDATION=...
# Always exits 0 (advisory to orchestrator, enforced by command instruction).

set -euo pipefail

FEATURE_DIR="${1:?Usage: context-health.sh <feature_dir}"

STATE_FILE="$FEATURE_DIR/state.json"
ARTIFACTS_DIR="$FEATURE_DIR/.artifacts"

# Default thresholds — sourced from ddd-clean-arch/workflow-config.json
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/ddd-clean-arch/workflow-config.json"

DEFAULT_RESET_THRESHOLD=15
DEFAULT_ARTIFACT_SIZE_THRESHOLD_MB=500
DEFAULT_CORRECTION_SNAPSHOTS_WARN=50

if [ -f "$CONFIG" ]; then
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" context.reset_threshold 2>/dev/null || echo "")
  [ -n "$val" ] && DEFAULT_RESET_THRESHOLD="$val"
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" context.artifact_size_mb 2>/dev/null || echo "")
  [ -n "$val" ] && DEFAULT_ARTIFACT_SIZE_THRESHOLD_MB="$val"
  val=$(bash "$SCRIPT_DIR/workflow-config.sh" context.correction_snapshot_warn 2>/dev/null || echo "")
  [ -n "$val" ] && DEFAULT_CORRECTION_SNAPSHOTS_WARN="$val"
fi

# ── Read context state from state.json ──────────────────────────
SESSION_AGE=0
RESET_THRESHOLD=$DEFAULT_RESET_THRESHOLD

if [ -f "$STATE_FILE" ]; then
  local_age=$(jq -r '.context.session_age // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  local_threshold=$(jq -r '.context.reset_threshold // 0' "$STATE_FILE" 2>/dev/null || echo 0)

  case "$local_age" in ''|*[!0-9]*) local_age=0 ;; esac
  case "$local_threshold" in ''|*[!0-9]*) local_threshold=0 ;; esac

  SESSION_AGE=$local_age
  if [ "$local_threshold" -gt 0 ]; then
    RESET_THRESHOLD=$local_threshold
  fi
fi

# ── Check artifact directory sizes ──────────────────────────────
ARTIFACT_SIZE_MB=0
PROMPT_CONTEXT_COUNT=0
CORRECTION_SNAPSHOT_COUNT=0

if [ -d "$ARTIFACTS_DIR" ]; then
  # Total artifacts size
  if command -v du &>/dev/null; then
    ARTIFACT_SIZE_KB=$(du -sk "$ARTIFACTS_DIR" 2>/dev/null | awk '{print $1}' || echo 0)
    ARTIFACT_SIZE_MB=$((ARTIFACT_SIZE_KB / 1024))
  fi

  # Count prompt contexts
  if [ -d "$ARTIFACTS_DIR/prompts" ]; then
    PROMPT_CONTEXT_COUNT=$(find "$ARTIFACTS_DIR/prompts" -name "context.md" 2>/dev/null | wc -l || echo 0)
  fi

  # Count correction snapshots
  if [ -d "$ARTIFACTS_DIR/correction-snapshots" ]; then
    CORRECTION_SNAPSHOT_COUNT=$(find "$ARTIFACTS_DIR/correction-snapshots" -type d 2>/dev/null | wc -l || echo 0)
  fi
fi

# ── Determine health status ─────────────────────────────────────
HEALTH="HEALTHY"
RECOMMENDATION="Context health is good. No action needed."

# Check session age
if [ "$SESSION_AGE" -ge "$RESET_THRESHOLD" ]; then
  local_ratio=$((SESSION_AGE * 100 / RESET_THRESHOLD))
  if [ "$local_ratio" -ge 200 ]; then
    HEALTH="CRITICAL"
    RECOMMENDATION="Context age ($SESSION_AGE tasks) is 2x the reset threshold ($RESET_THRESHOLD). Consider starting a fresh session. Key decisions and spec details may be forgotten."
  elif [ "$SESSION_AGE" -ge $((RESET_THRESHOLD * 3 / 4)) ]; then
    HEALTH="DEGRADED"
    RECOMMENDATION="Context age ($SESSION_AGE tasks) approaching reset threshold ($RESET_THRESHOLD). Re-read plan.md sections 1-3 and spec.md before continuing. Summarize key decisions from your context window."
  else
    HEALTH="DEGRADED"
    RECOMMENDATION="Context age ($SESSION_AGE tasks) exceeds threshold ($RESET_THRESHOLD). Re-read plan.md and spec.md to refresh context."
  fi
fi

# Check artifact disk usage
if [ "$ARTIFACT_SIZE_MB" -ge "$DEFAULT_ARTIFACT_SIZE_THRESHOLD_MB" ]; then
  if [ "$HEALTH" = "HEALTHY" ]; then
    HEALTH="DEGRADED"
  fi
  RECOMMENDATION="${RECOMMENDATION} Artifacts directory is ${ARTIFACT_SIZE_MB}MB. Consider cleanup."
fi

# Check excessive correction snapshots (indicates many failed corrections)
if [ "$CORRECTION_SNAPSHOT_COUNT" -ge "$DEFAULT_CORRECTION_SNAPSHOTS_WARN" ]; then
  if [ "$HEALTH" = "HEALTHY" ]; then
    HEALTH="DEGRADED"
  fi
  RECOMMENDATION="${RECOMMENDATION} $CORRECTION_SNAPSHOT_COUNT correction snapshots detected. High correction rate may indicate spec ambiguity."
fi

# ── Output results ──────────────────────────────────────────────
SESSION_ROTATE_REQUIRED="false"
if [ "$HEALTH" = "CRITICAL" ]; then
  SESSION_ROTATE_REQUIRED="true"
fi

echo "CONTEXT_HEALTH=${HEALTH}"
echo "SESSION_AGE=${SESSION_AGE}"
echo "RESET_THRESHOLD=${RESET_THRESHOLD}"
echo "ARTIFACT_SIZE_MB=${ARTIFACT_SIZE_MB}"
echo "PROMPT_CONTEXT_COUNT=${PROMPT_CONTEXT_COUNT}"
echo "CORRECTION_SNAPSHOT_COUNT=${CORRECTION_SNAPSHOT_COUNT}"
echo "SESSION_ROTATE_REQUIRED=${SESSION_ROTATE_REQUIRED}"
echo "RECOMMENDATION=${RECOMMENDATION}"

exit 0
