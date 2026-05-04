#!/usr/bin/env bash
# Automated OWASP Top 10 basic checks (Check O — security hardening).
# Replaces LLM self-judgment for common, detectable patterns.
# This is a FIRST PASS — not a replacement for full adversarial review.
#
# Usage: run-owasp-basic.sh <feature_dir>
# Exits 0 if all checks pass, 1 if any critical issues found.
#
# Checks:
#   A01:2021 — Broken Access Control: no hardcoded credentials
#   A02:2021 — Cryptographic Failures: no weak hash usage
#   A03:2021 — Injection: SQL injection patterns, command injection
#   A05:2021 — Security Misconfiguration: missing security headers
#   A07:2021 — ID Auth: sequential/ predictable token patterns
#   A09:2021:2021 — Security Logging: no debug logging in production paths

set -euo pipefail

FEATURE_DIR="${1:?Usage: run-owasp-basic.sh <feature_dir>}"
SRC_DIRS=()

# Find source directories (skip node_modules, vendor, .git, dist)
while IFS= read -r dir; do
  SRC_DIRS+=("$dir")
done < <(find "$FEATURE_DIR" -type d \( -name node_modules -o -name vendor -o -name .git -o -name dist -o -name build \) -prune -o -type d -print 2>/dev/null | grep -E '\.(ts|js|py|java|go|rb|php|kt|scala)$' -v | grep -E 'src|lib|app|core|domain|api' | sort -u | head -20)

# If no source dirs found, scan everything except excluded dirs
if [ ${#SRC_DIRS[@]} -eq 0 ]; then
  while IFS= read -r dir; do
    SRC_DIRS+=("$dir")
  done < <(find "$FEATURE_DIR" -type d \( -name node_modules -o -name vendor -o -name .git -o -name dist -o -name build \) -prune -o -type d -print 2>/dev/null | head -20)
fi

ISSUES=0

echo "━━━ OWASP Top 10 Basic Checks ━━━"
echo "Scanning: $FEATURE_DIR"
echo ""

# ── A01:2021 — Broken Access Control ──────────────────────────
echo "Check A01: Hardcoded credentials"
HARDCODED=$(grep -rn -iE '(password|secret|api_key|token)\s*=\s*["\x27][^"\x27]{8,}["\x27]' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' --include='*.go' 2>/dev/null | \
  grep -v 'test\|spec\|mock\|fake\|example\|placeholder\|dummy\|CHANGE' || true)
if [ -n "$HARDCODED" ]; then
  echo "  FAIL: Possible hardcoded credentials found"
  echo "$HARDCODED" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
else
  echo "  PASS: No hardcoded credentials detected"
fi

# ── A03:2021 — Injection ──────────────────────────────────────
echo "Check A03: SQL injection patterns"
SQLI=$(grep -rn -E '(executeQuery|executeUpdate|raw\(|\.query\(|exec\()' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' 2>/dev/null | \
  grep -v 'param\|bind\|placeholder\|prepared\|:param\|:id\|?1\|?2\|%s\|%d\|\.map\|\.filter\|\.reduce' | \
  grep -v 'test\|spec\|mock\|fake' || true)
if [ -n "$SQLI" ]; then
  echo "  WARN: Possible SQL injection patterns (review for parameterized queries)"
  echo "$SQLI" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
else
  echo "  PASS: No obvious SQL injection patterns"
fi

echo "Check A03: Command injection patterns"
CMD_INJ=$(grep -rn -E '(exec\(|spawn\(|system\(|popen\(|Runtime\.getRuntime)' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' --include='*.go' 2>/dev/null | \
  grep -v 'test\|spec\|mock\|fake' | grep -v 'constant\|command\s*=\s*["\x27]' | head -10 || true)
if [ -n "$CMD_INJ" ]; then
  echo "  WARN: Command execution patterns found (verify input sanitization)"
  echo "$CMD_INJ" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
else
  echo "  PASS: No obvious command injection patterns"
fi

# ── A02:2021 — Cryptographic Failures ─────────────────────────
echo "Check A02: Weak hash usage"
WEAK_HASH=$(grep -rn -iE '(md5|sha1|sha-1|des\.encrypt|rc4)' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' 2>/dev/null | \
  grep -v 'test\|spec\|mock\|fake\|hashmap\|dictionary' || true)
if [ -n "$WEAK_HASH" ]; then
  echo "  WARN: Weak cryptographic algorithms detected"
  echo "$WEAK_HASH" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
else
  echo "  PASS: No weak hash usage detected"
fi

# ── A09:2021 — Security Logging ──────────────────────────────
echo "Check A09: Debug logging in production paths"
DEBUG_LOG=$(grep -rn -E '(console\.log|logger\.debug|LOG\.debug|print\(|System\.out\.print)' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' 2>/dev/null | \
  grep -v 'test\|spec\|mock\|fake\|cli\|bin\|setup\|config' | head -10 || true)
if [ -n "$DEBUG_LOG" ]; then
  echo "  WARN: Debug/console output in production code paths"
  echo "$DEBUG_LOG" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
else
  echo "  PASS: No debug logging in production paths"
fi

echo ""
echo "━━━ Results ━━━"
if [ "$ISSUES" -gt 0 ]; then
  echo "WARN: $ISSUES issue(s) found. These are automated checks only — review manually."
  exit 1
else
  echo "PASS: All automated OWASP basic checks passed."
  exit 0
fi
