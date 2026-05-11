#!/usr/bin/env bash
# restore-checkpoint.sh — DEPRECATED: delegates to recovery-engine.sh
#
# Legacy interface: user-facing checkpoint restore with --list, --dry-run, --confirm
# New code should use: recovery-engine.sh restore <feature_dir> <checkpoint_id>

set -euo pipefail

FEATURE_DIR="${1:?Usage: restore-checkpoint.sh <feature_dir> <checkpoint_id|--list> [--dry-run] [--confirm]}"
CHECKPOINT_ARG="${2:?Usage: restore-checkpoint.sh <feature_dir> <checkpoint_id|--list> [--dry-run] [--confirm]}"
DRY_RUN=false
CONFIRM=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=true ;;
    --confirm)  CONFIRM=true ;;
  esac
  shift
done

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Delegate to recovery-engine.sh
if [ "$CHECKPOINT_ARG" = "--list" ]; then
  bash "$SCRIPTS_DIR/recovery-engine.sh" list "$FEATURE_DIR"
elif [ "$DRY_RUN" = true ]; then
  # Dry-run: show what would be restored
  echo "DRY RUN — checkpoint $CHECKPOINT_ARG:"
  bash "$SCRIPTS_DIR/recovery-engine.sh" list "$FEATURE_DIR"
  echo "  (Full dry-run diff requires legacy check-point.sh snapshot format)"
  echo "Run with --confirm to perform the restore."
elif [ "$CONFIRM" = true ]; then
  bash "$SCRIPTS_DIR/recovery-engine.sh" restore "$FEATURE_DIR" "$CHECKPOINT_ARG" --hard
else
  echo "ERROR: --confirm flag required to perform restore."
  echo "  Run with --list to see available checkpoints."
  echo "  Run with --dry-run to preview changes."
fi
