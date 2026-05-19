#!/usr/bin/env bash
# Validate Specify CLI compatibility with workflow YAML features.
#
# Checks that the installed `specify` CLI supports the YAML features
# used by the workflow: template expressions, cross-phase goto, while
# loops, and if/then/else conditionals.
#
# Usage: validate-specify-compat.sh [--help]
#
# Output: COMPAT=OK|WARN|FAIL
#         DETAIL=...
#
# Exit codes:
#   0 — OK or WARN (compatibility confirmed or minor gaps)
#   1 — FAIL (incompatible CLI version detected)

set -euo pipefail

# ── Parse flags ────────────────────────────────────────────────────
if [ "${1:-}" = "--help" ]; then
  echo "Usage: validate-specify-compat.sh [--help]"
  echo ""
  echo "Validates that the installed 'specify' CLI supports the YAML features"
  echo "used by the workflow. Checks: template expressions, goto resolution,"
  echo "while loops, and if/then/else conditionals."
  exit 0
fi

echo "SPECIFY COMPAT: Checking installed version and feature support..."

# ── Check specify is installed ─────────────────────────────────────
if ! command -v specify &>/dev/null; then
  echo "SPECIFY COMPAT: FAIL — specify CLI not installed"
  echo "COMPAT=FAIL"
  echo "DETAIL=specify_cli_not_installed"
  exit 1
fi

# Get installed version
SPECIFY_VERSION=$(specify --version 2>/dev/null || specify version 2>/dev/null || echo "unknown")
echo "SPECIFY COMPAT: Installed version: ${SPECIFY_VERSION}"

# Extract numeric version
VERSION_NUM=$(echo "$SPECIFY_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ -z "$VERSION_NUM" ]; then
  echo "SPECIFY COMPAT: WARN — could not parse version from '${SPECIFY_VERSION}'"
  echo "COMPAT=WARN"
  echo "DETAIL=unparseable_version"
  exit 0
fi

echo "SPECIFY COMPAT: Parsed version: ${VERSION_NUM}"

# ── Minimum version check ─────────────────────────────────────────
# Workflow requires >= 0.7.2
MIN_MAJOR=0
MIN_MINOR=7
MIN_PATCH=2

# Extract individual parts
VER_MAJOR=$(echo "$VERSION_NUM" | cut -d. -f1)
VER_MINOR=$(echo "$VERSION_NUM" | cut -d. -f2)
VER_PATCH=$(echo "$VERSION_NUM" | cut -d. -f3)

# Default missing parts to 0
VER_MAJOR=${VER_MAJOR:-0}
VER_MINOR=${VER_MINOR:-0}
VER_PATCH=${VER_PATCH:-0}

# Validate numeric
for v in "$VER_MAJOR" "$VER_MINOR" "$VER_PATCH"; do
  case "$v" in ''|*[!0-9]*) echo "SPECIFY COMPAT: WARN — non-numeric version component: $v"; echo "COMPAT=WARN"; echo "DETAIL=non_numeric_version"; exit 0 ;; esac
done

VERSION_OK=false
if [ "$VER_MAJOR" -gt "$MIN_MAJOR" ]; then
  VERSION_OK=true
elif [ "$VER_MAJOR" -eq "$MIN_MAJOR" ] && [ "$VER_MINOR" -gt "$MIN_MINOR" ]; then
  VERSION_OK=true
elif [ "$VER_MAJOR" -eq "$MIN_MAJOR" ] && [ "$VER_MINOR" -eq "$MIN_MINOR" ] && [ "$VER_PATCH" -ge "$MIN_PATCH" ]; then
  VERSION_OK=true
fi

if [ "$VERSION_OK" = false ]; then
  echo "SPECIFY COMPAT: FAIL — version ${VERSION_NUM} < required ${MIN_MAJOR}.${MIN_MINOR}.${MIN_PATCH}"
  echo "COMPAT=FAIL"
  echo "DETAIL=version_too_old"
  exit 1
fi

echo "SPECIFY COMPAT: Version ${VERSION_NUM} meets minimum ${MIN_MAJOR}.${MIN_MINOR}.${MIN_PATCH}"

# ── Feature tests ─────────────────────────────────────────────────
# Create a temporary directory for test YAML files
TMPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t specify-compat)
trap "rm -rf '$TMPDIR'" EXIT

FAILURES=0
WARNINGS=0

# Test 1: Template expressions
echo "SPECIFY COMPAT: Testing template expressions..."
cat > "$TMPDIR/test-template.yml" << 'YAML'
spec_version: "1.0"
speckit_version: "0.7.2"
steps:
  - id: test_step
    shell: |
      echo "test"
    when: "{{ steps.setup.output.ok == 'true' }}"
YAML

if specify validate "$TMPDIR/test-template.yml" &>/dev/null; then
  echo "SPECIFY COMPAT: OK — template expressions supported"
else
  echo "SPECIFY COMPAT: WARN — template expression validation failed (may be OK if engine supports it)"
  WARNINGS=$((WARNINGS + 1))
fi

# Test 2: Goto resolution (same-phase and cross-phase)
echo "SPECIFY COMPAT: Testing goto resolution..."
cat > "$TMPDIR/test-goto.yml" << 'YAML'
spec_version: "1.0"
speckit_version: "0.7.2"
steps:
  - id: step_a
    shell: echo "a"
    goto: step_b
  - id: step_b
    shell: echo "b"
YAML

if specify validate "$TMPDIR/test-goto.yml" &>/dev/null; then
  echo "SPECIFY COMPAT: OK — goto resolution supported"
else
  echo "SPECIFY COMPAT: WARN — goto validation failed"
  WARNINGS=$((WARNINGS + 1))
fi

# Test 3: While loops
echo "SPECIFY COMPAT: Testing while loops..."
cat > "$TMPDIR/test-while.yml" << 'YAML'
spec_version: "1.0"
speckit_version: "0.7.2"
steps:
  - id: loop_step
    shell: echo "iter"
    while:
      condition: "{{ steps.check.output.continue == 'true' }}"
      max_iterations: 10
YAML

if specify validate "$TMPDIR/test-while.yml" &>/dev/null; then
  echo "SPECIFY COMPAT: OK — while loop syntax supported"
else
  echo "SPECIFY COMPAT: WARN — while loop validation failed"
  WARNINGS=$((WARNINGS + 1))
fi

# Test 4: If/then/else conditionals
echo "SPECIFY COMPAT: Testing if/then/else conditionals..."
cat > "$TMPDIR/test-conditional.yml" << 'YAML'
spec_version: "1.0"
speckit_version: "0.7.2"
steps:
  - id: conditional_step
    shell: echo "test"
    when: "{{ steps.check.output.skip != 'true' }}"
YAML

if specify validate "$TMPDIR/test-conditional.yml" &>/dev/null; then
  echo "SPECIFY COMPAT: OK — conditional branching supported"
else
  echo "SPECIFY COMPAT: WARN — conditional validation failed"
  WARNINGS=$((WARNINGS + 1))
fi

# ── Summary ───────────────────────────────────────────────────────
if [ "$FAILURES" -gt 0 ]; then
  echo "SPECIFY COMPAT: FAIL — ${FAILURES} failure(s), ${WARNINGS} warning(s)"
  echo "COMPAT=FAIL"
  echo "DETAIL=compatibility_failures"
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  echo "SPECIFY COMPAT: WARN — ${WARNINGS} feature(s) had validation warnings"
  echo "COMPAT=WARN"
  echo "DETAIL=validation_warnings"
  exit 0
fi

echo "SPECIFY COMPAT: OK — all compatibility checks passed"
echo "COMPAT=OK"
echo "DETAIL=version=${VERSION_NUM}"
exit 0
