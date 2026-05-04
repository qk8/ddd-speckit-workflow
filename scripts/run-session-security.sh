#!/usr/bin/env bash
# Automated session & token security checks (Check U).
# Replaces LLM self-judgment for common, detectable patterns.
# This is a FIRST PASS — not a replacement for full adversarial review.
#
# Usage: run-session-security.sh <feature_dir>
# Exits 0 if all checks pass, 1 if any critical issues found.
#
# Checks:
#   - JWT alg:none vulnerability (no algorithm confusion)
#   - Cookie security flags (HttpOnly, Secure, SameSite)
#   - Token refresh rotation
#   - Session fixation prevention
#   - Token leakage in URLs/logs

set -euo pipefail

FEATURE_DIR="${1:?Usage: run-session-security.sh <feature_dir>}"
SRC_DIRS=()

# Find source directories
while IFS= read -r dir; do
  SRC_DIRS+=("$dir")
done < <(find "$FEATURE_DIR" -type d \( -name node_modules -o -name vendor -o -name .git -o -name dist -o -name build \) -prune -o -type d -print 2>/dev/null | grep -E 'src|lib|app|core|domain|api' | sort -u | head -20)

if [ ${#SRC_DIRS[@]} -eq 0 ]; then
  while IFS= read -r dir; do
    SRC_DIRS+=("$dir")
  done < <(find "$FEATURE_DIR" -type d \( -name node_modules -o -name vendor -o -name .git -o -name dist -o -name build \) -prune -o -type d -print 2>/dev/null | head -20)
fi

ISSUES=0

echo "━━━ Session & Token Security Checks ━━━"
echo "Scanning: $FEATURE_DIR"
echo ""

# ── JWT alg:none vulnerability ─────────────────────────────────
echo "Check U1: JWT algorithm validation"
JWT_WEAK=$(grep -rn -E '(alg.*none|algorithm.*none|ALG_NONE|allowNone|ignoreAlgo|acceptNone)' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' --include='*.go' 2>/dev/null | \
  grep -v 'test\|spec\|mock\|fake' || true)
if [ -n "$JWT_WEAK" ]; then
  echo "  FAIL: JWT alg:none vulnerability detected"
  echo "$JWT_WEAK" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
else
  echo "  PASS: No JWT alg:none vulnerability"
fi

# ── Cookie security flags ─────────────────────────────────────
echo "Check U2: Cookie security flags"
COOKIE_FLAGS=$(grep -rn -E '(cookie\(|setCookie|res\.cookie|Response\.Cookie|Set-Cookie)' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' --include='*.go' 2>/dev/null | \
  grep -v 'test\|spec\|mock\|fake' | grep -v 'httponly\|HttpOnly\|secure\|Secure\|samesite\|SameSite\|maxAge\|max_age\|expires' | head -10 || true)
if [ -n "$COOKIE_FLAGS" ]; then
  echo "  WARN: Cookie settings found without security flags"
  echo "$COOKIE_FLAGS" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
else
  echo "  PASS: Cookie security flags present"
fi

# ── Token refresh rotation ────────────────────────────────────
echo "Check U3: Token refresh rotation"
# Look for refresh token patterns — if found, verify rotation exists
REFRESH_TOKENS=$(grep -rn -E '(refresh.*token|refreshToken|refresh_token|rotat)' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' --include='*.go' 2>/dev/null | \
  grep -v 'test\|spec\|mock\|fake' | head -10 || true)
if [ -n "$REFRESH_TOKENS" ]; then
  # Check if rotation is implemented
  HAS_ROTATION=$(grep -rn -E '(rotate|revoke|invalidate|blacklist|oldToken|previousToken)' \
    "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' --include='*.go' 2>/dev/null | \
    grep -v 'test\|spec\|mock\|fake' | head -5 || true)
  if [ -n "$HAS_ROTATION" ]; then
    echo "  PASS: Token rotation pattern detected"
  else
    echo "  WARN: Refresh tokens used but rotation not detected"
    echo "$REFRESH_TOKENS" | head -3 | sed 's/^/    /'
    ISSUES=$((ISSUES + 1))
  fi
else
  echo "  SKIP: No refresh token patterns found"
fi

# ── Session fixation prevention ───────────────────────────────
echo "Check U4: Session fixation prevention"
# Look for session regeneration after login
SESSION_REGEN=$(grep -rn -E '(regenerate|renew.*session|newSession|sessionId.*=.*uuid|randomUUID|crypto\.random)' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' --include='*.go' 2>/dev/null | \
  grep -v 'test\|spec\|mock\|fake' | head -5 || true)
if [ -n "$SESSION_REGEN" ]; then
  echo "  PASS: Session regeneration detected"
else
  # Check if sessions are used at all
  SESSIONS=$(grep -rn -E '(session|req\.session|request\.session)' \
    "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' --include='*.go' 2>/dev/null | \
    grep -v 'test\|spec\|mock\|fake' | head -5 || true)
  if [ -n "$SESSIONS" ]; then
    echo "  WARN: Sessions used but no regeneration pattern detected"
    ISSUES=$((ISSUES + 1))
  else
    echo "  SKIP: No session patterns found (stateless auth assumed)"
  fi
fi

# ── Token leakage in URLs/logs ────────────────────────────────
echo "Check U5: Token leakage in URLs"
TOKEN_IN_URL=$(grep -rn -E '(token|bearer|authorization).*url|url.*token|req\.url.*token' \
  "${SRC_DIRS[@]}" --include='*.ts' --include='*.js' --include='*.py' --include='*.java' --include='*.go' 2>/dev/null | \
  grep -v 'test\|spec\|mock\|fake' || true)
if [ -n "$TOKEN_IN_URL" ]; then
  echo "  WARN: Tokens may appear in URLs (use headers instead)"
  echo "$TOKEN_IN_URL" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
else
  echo "  PASS: No token-in-URL patterns detected"
fi

echo ""
echo "━━━ Results ━━━"
if [ "$ISSUES" -gt 0 ]; then
  echo "WARN: $ISSUES issue(s) found. These are automated checks only — review manually."
  exit 1
else
  echo "PASS: All automated session security checks passed."
  exit 0
fi
