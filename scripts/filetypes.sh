#!/usr/bin/env bash
# Shared file type list for grep --include options.
# Source this file: source scripts/filetypes.sh
# Usage: grep -rl $FILETYPES_PATTERNS <pattern> <dirs...>

FILETYPES_PATTERNS=(
  --include="*.java" --include="*.ts" --include="*.tsx" --include="*.js"
  --include="*.py" --include="*.go" --include="*.rs" --include="*.kt"
  --include="*.scala" --include="*.rb" --include="*.cs" --include="*.swift"
  --include="*.php" --include="*.cpp" --include="*.h" --include="*.hpp"
  --include="*.sql" --include="*.yaml" --include="*.yml"
  --include="*.json" --include="*.md"
)
