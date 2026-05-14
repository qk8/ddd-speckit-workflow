#!/usr/bin/env bash
# Dependency Vulnerability Scan (Check E)
# Auto-detects the package manager, runs the appropriate vulnerability scanner,
# and reports PASS/FAIL — verifying no high/critical vulnerabilities.
# Includes timeout and retry logic for network-dependent scanners.
set -euo pipefail

# ── Network retry helper ─────────────────────────────────────────
# Network-dependent tools (npm audit, pip-audit, cargo audit, etc.)
# may fail due to transient network issues. Retry up to 3 times with
# exponential backoff before failing.
run_with_retry() {
  local cmd="$1"
  local max_attempts="${2:-3}"
  local attempt=0
  local exit_code=1
  local output=""

  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    output=$(timeout 120 bash -c "$cmd" 2>&1) || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
      echo "$output"
      return 0
    fi
    # Exit code 124 = timeout, 126/127 = command not found (don't retry)
    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 126 ] || [ "$exit_code" -eq 127 ]; then
      echo "ERROR: $cmd failed (exit $exit_code) after $attempt attempt(s)" >&2
      echo "$output"
      return "$exit_code"
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      local sleep_time=$((2 ** attempt))
      echo "WARNING: $cmd failed (exit $exit_code), retrying in ${sleep_time}s (attempt $attempt/$max_attempts)" >&2
      sleep "$sleep_time"
    fi
  done

  echo "$output"
  return "$exit_code"
}

FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || echo "")
fi
if [ -z "$FEATURE_DIR" ]; then
  echo "DEP SCAN: SKIP (no feature directory)"
  exit 0
fi

# ── Auto-detect package manager and return scanner command ──────
# Returns the command string; caller executes it.
detect_scanner() {
  # Check in feature dir first, then current dir
  for search_dir in "$FEATURE_DIR" "."; do
    [ -d "$search_dir" ] || continue

    # Node.js / npm
    if [ -f "$search_dir/package.json" ]; then
      echo "npm audit --audit-level=high"
      return 0
    fi

    # Python
    if [ -f "$search_dir/requirements.txt" ]; then
      # Prefer pip-audit, fall back to safety, then bandit
      if command -v pip-audit >/dev/null 2>&1; then
        echo "pip-audit -r requirements.txt"
        return 0
      elif command -v safety >/dev/null 2>&1; then
        echo "safety check -r requirements.txt"
        return 0
      elif command -v bandit >/dev/null 2>&1; then
        echo "bandit -r ${search_dir}/src/ 2>/dev/null || true"
        return 0
      else
        echo "pip-audit -r requirements.txt"
        return 0
      fi
    fi

    # Python (pyproject.toml / Pipfile without requirements.txt — still warn)
    if [ -f "$search_dir/pyproject.toml" ] || [ -f "$search_dir/Pipfile" ]; then
      if command -v pip-audit >/dev/null 2>&1; then
        echo "pip-audit"
        return 0
      elif command -v safety >/dev/null 2>&1; then
        echo "safety check"
        return 0
      elif command -v bandit >/dev/null 2>&1; then
        echo "bandit -r ${search_dir}/src/ 2>/dev/null || true"
        return 0
      fi
    fi

    # Rust / Cargo
    if [ -f "$search_dir/Cargo.toml" ]; then
      if command -v cargo >/dev/null 2>&1 && cargo audit --help >/dev/null 2>&1; then
        echo "cargo audit"
        return 0
      elif command -v cargo-audit >/dev/null 2>&1; then
        echo "cargo-audit"
        return 0
      else
        echo "cargo audit"
        return 0
      fi
    fi

    # Go
    if [ -f "$search_dir/go.mod" ]; then
      if command -v govulncheck >/dev/null 2>&1; then
        echo "govulncheck ./..."
        return 0
      elif command -v gosec >/dev/null 2>&1; then
        echo "gosec ./..."
        return 0
      else
        echo "govulncheck ./..."
        return 0
      fi
    fi

    # Ruby
    if [ -f "$search_dir/Gemfile" ]; then
      if command -v bundle >/dev/null 2>&1 && bundle audit --help >/dev/null 2>&1; then
        echo "bundle audit"
        return 0
      elif command -v bundler-audit >/dev/null 2>&1; then
        echo "bundler-audit"
        return 0
      else
        echo "bundle audit"
        return 0
      fi
    fi
  done

  # No manifest found
  return 1
}

# ── Determine the scanner name for reporting ────────────────────
scanner_name() {
  local cmd="$1"
  case "$cmd" in
    npm\ audit*) echo "npm audit" ;;
    pip-audit*) echo "pip-audit" ;;
    safety\ check*) echo "safety check" ;;
    bandit*) echo "bandit" ;;
    cargo\ audit*) echo "cargo audit" ;;
    cargo-audit*) echo "cargo-audit" ;;
    govulncheck*) echo "govulncheck" ;;
    gosec*) echo "gosec" ;;
    bundle\ audit*) echo "bundle audit" ;;
    bundler-audit*) echo "bundler-audit" ;;
    *) echo "$cmd" ;;
  esac
}

# ── Parse vulnerability count from scanner output ───────────────
# Each tool formats its summary differently.
parse_vuln_count() {
  local output="$1"
  local cmd="$2"
  local count=0

  case "$cmd" in
    npm\ audit)
      # "found 3 vulnerabilities" or "found 5 vulnerabilities"
      count=$(echo "$output" | grep -oE "found [0-9]+ vulnerabilities?" | grep -oE "[0-9]+" | head -1 || true)
      # Also check for "found 0 vulnerabilities"
      if [ -z "$count" ]; then
        count=$(echo "$output" | grep -oE "found [0-9]+ vulnerabilities?" | grep -oE "[0-9]+" | head -1 || true)
      fi
      ;;
    pip-audit*)
      # "Found 2 known vulnerabilities, 2 vulnerabilities reported" or "no vulnerabilities found"
      count=$(echo "$output" | grep -oE "Found [0-9]+ known" | grep -oE "[0-9]+" | head -1 || true)
      if [ -z "$count" ]; then
        count=$(echo "$output" | grep -oE "[0-9]+ known" | grep -oE "[0-9]+" | head -1 || true)
      fi
      if [ -z "$count" ]; then
        count=$(echo "$output" | grep -i "found" | grep -oE "[0-9]+" | head -1 || true)
      fi
      ;;
    safety\ check*)
      # "Vulnerabilities found" or "Found N vulnerabilities"
      count=$(echo "$output" | grep -oE "[0-9]+ found" | grep -oE "[0-9]+" | head -1 || true)
      if [ -z "$count" ]; then
        count=$(echo "$output" | grep -i "vulnerabilities found" | grep -oE "[0-9]+" | head -1 || true)
      fi
      ;;
    bandit*)
      # "total lines of code=... local lines of code=... 0" (last 0 = total issues)
      count=$(echo "$output" | tail -1 | grep -oE "[0-9]+$" | head -1 || true)
      ;;
    cargo\ audit*|cargo-audit*)
      # "warning: Vulnerability (2) found" or "1 yanked crate"
      count=$(echo "$output" | grep -oE "Vulnerability \([0-9]+\)" | grep -oE "[0-9]+" | head -1 || true)
      if [ -z "$count" ]; then
        count=$(echo "$output" | grep -oE "[0-9]+ advisory" | grep -oE "[0-9]+" | head -1 || true)
      fi
      ;;
    govulncheck*)
      # "Found 2 issues" or just "2"
      count=$(echo "$output" | grep -oE "Found [0-9]+ issue" | grep -oE "[0-9]+" | head -1 || true)
      if [ -z "$count" ]; then
        # Last line might just be the count
        count=$(echo "$output" | tail -1 | grep -oE "^[0-9]+$" | head -1 || true)
      fi
      ;;
    gosec*)
      # "Golang Security Checker - findings: N"
      count=$(echo "$output" | grep -oE "findings: [0-9]+" | grep -oE "[0-9]+" | head -1 || true)
      ;;
    bundle\ audit*|bundler-audit*)
      # "Vulnerabilities found" or "N vulnerabilities"
      count=$(echo "$output" | grep -i "vulnerabilities" | grep -oE "[0-9]+" | head -1 || true)
      if [ -z "$count" ]; then
        count=$(echo "$output" | grep -i "vulnerable gems" | grep -oE "[0-9]+" | head -1 || true)
      fi
      ;;
  esac

  : "${count:=0}"
  echo "$count"
}

# ── Main ────────────────────────────────────────────────────────
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${FEATURE_DIR}/.artifacts"
RESULTS_DIR="${ARTIFACTS_DIR}/check-results"
mkdir -p "$RESULTS_DIR"
RESULT_FILE="${RESULTS_DIR}/E.result"

SCANNER_CMD=$(detect_scanner 2>/dev/null || true)

if [ -z "$SCANNER_CMD" ]; then
  echo "DEP SCAN: SKIP (no package manifest found)"
  {
    echo "SKIP"
    echo "DEP SCAN: SKIP (no package manifest found)"
  } > "$RESULT_FILE"
  exit 0
fi

SCANNER_NAME=$(scanner_name "$SCANNER_CMD")

# Execute the scanner
OUTPUT=""
EXIT_CODE=0
if [ -f "$SCRIPTS_DIR/validate-tests.sh" ]; then
  VALIDATE_OUTPUT=$(bash "$SCRIPTS_DIR/validate-tests.sh" "$SCANNER_CMD" "pass" 2>&1 || true)
  # Extract exit code from validate-tests.sh output
  VALIDATE_EXIT=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_EXIT_CODE=" | cut -d= -f2 || true)
  : "${VALIDATE_EXIT:=0}"

  # If validate-tests.sh succeeded (exit 0), the command output is after TEST_SUMMARY
  # Extract the actual output from TEST_OUTPUT_FILE
  OUTPUT_FILE=$(echo "$VALIDATE_OUTPUT" | grep "^TEST_OUTPUT_FILE=" | cut -d= -f2 || true)
  if [ -n "$OUTPUT_FILE" ] && [ -f "$OUTPUT_FILE" ]; then
    OUTPUT=$(cat "$OUTPUT_FILE")
    rm -f "$OUTPUT_FILE" 2>/dev/null || true
  else
    # Fallback: output might be embedded in the validation output
    OUTPUT="$VALIDATE_OUTPUT"
  fi

  EXIT_CODE="$VALIDATE_EXIT"
else
  # Run with retry for network resilience
  OUTPUT=$(run_with_retry "$SCANNER_CMD" 3) || EXIT_CODE=$?
fi

# Parse vulnerability count
VULN_COUNT=$(parse_vuln_count "$OUTPUT" "$SCANNER_NAME")
: "${VULN_COUNT:=0}"

# If exit code is 0 but parser found vulnerabilities, trust the parser
# If exit code is non-zero but parser found 0, still treat as having issues
if [ "$EXIT_CODE" -ne 0 ] && [ "$VULN_COUNT" -eq 0 ]; then
  # Exit code non-zero but no explicit count — assume at least 1 vulnerability
  VULN_COUNT=1
fi

# ── Write results ───────────────────────────────────────────────
if [ "$VULN_COUNT" -eq 0 ] && [ "$EXIT_CODE" -eq 0 ]; then
  echo "DEP SCAN: ${SCANNER_NAME}"
  if [ -n "$OUTPUT" ]; then
    echo "$OUTPUT"
  fi
  echo "DEP SCAN: PASS — 0 high/critical vulnerability(ies)"
  {
    echo "PASS"
    echo "DEP SCAN: PASS — 0 high/critical vulnerability(ies)"
  } > "$RESULT_FILE"
  exit 0
else
  echo "DEP SCAN: ${SCANNER_NAME}"
  if [ -n "$OUTPUT" ]; then
    echo "$OUTPUT"
  fi
  echo "DEP SCAN: FAIL — ${VULN_COUNT} high/critical vulnerability(ies)"
  {
    echo "FAIL"
    echo "DEP SCAN: FAIL — ${VULN_COUNT} high/critical vulnerability(ies)"
  } > "$RESULT_FILE"
  exit 1
fi
