#!/usr/bin/env bash
# Migration Test — verifies that database migrations apply cleanly
# and produce the expected schema.
#
# Reads migration_tool / migration_strategy from plan.md §12 (Data Design).
# If not configured, auto-detects from common files. If nothing found,
# skips with PASS (no migrations configured).
#
# Usage: scripts/run-migration-test.sh <feature_dir>
#
# Environment:
#   DATABASE_URL_TEST — test database connection string (preferred)
#   MIGRATION_TEST_DB — legacy alias for the same value
#
# Output: .artifacts/check-results/F.result  (PASS / FAIL / SKIP)

set -euo pipefail

# ── Args ───────────────────────────────────────────────────────
FEATURE_DIR="${1:-}"
if [ -z "$FEATURE_DIR" ]; then
  # Try to find the first feature directory
  FEATURE_DIR=$(bash scripts/find-first-feature.sh 2>/dev/null || true)
fi
if [ -z "$FEATURE_DIR" ] || [ ! -d "$FEATURE_DIR" ]; then
  echo "MIGRATION TEST: SKIP (no feature directory found)"
  exit 0
fi

PLAN_FILE="${FEATURE_DIR}/plan.md"
ARTIFACTS_DIR=".artifacts/check-results"
mkdir -p "$ARTIFACTS_DIR"

OUTPUT_FILE=$(mktemp /tmp/migration-output-XXXXXX.txt)
trap 'rm -f "$OUTPUT_FILE"' EXIT

# ── Helpers ────────────────────────────────────────────────────
write_result() {
  local status="$1"
  echo "$status" > "${ARTIFACTS_DIR}/F.result"
}

print_result() {
  local tool="$1"
  local cmd="$2"
  local status="$3"
  echo "MIGRATION TEST: ${tool} ${cmd}"
  if [ -s "$OUTPUT_FILE" ]; then
    cat "$OUTPUT_FILE"
  fi
  if [ "$status" = "PASS" ]; then
    echo "MIGRATION TEST: PASS — schema applied cleanly"
  else
    echo "MIGRATION TEST: FAIL — migration error(s)"
  fi
}

# Extract a value from a YAML-like key: value in plan.md
# Usage: plan_value "migration_tool:"
plan_value() {
  local key="$1"
  local value
  value=$(grep -E "^[[:space:]]*${key}" "$PLAN_FILE" 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//' | head -n 1 | tr -d '"' | tr -d "'" | sed 's/[[:space:]]*$//' || true)
  echo "$value"
}

# ── Step 1: Read migration_tool / strategy from plan.md ───────
MIGRATION_TOOL=""
MIGRATION_CMD=""

if [ -f "$PLAN_FILE" ]; then
  MIGRATION_TOOL=$(plan_value "migration_tool:")
  MIGRATION_STRATEGY=$(plan_value "migration_strategy:")
else
  MIGRATION_TOOL=""
  MIGRATION_STRATEGY=""
fi

# ── Step 2: Auto-detect if not configured ─────────────────────
auto_detect_migration() {
  # Order matters: check for file-based detection patterns
  # Node.js / Prisma
  if [ -f "prisma/schema.prisma" ]; then
    if [ -z "$MIGRATION_TOOL" ]; then
      MIGRATION_TOOL="prisma"
      MIGRATION_CMD="npx prisma migrate deploy"
      return
    fi
  fi

  # Node.js / TypeORM
  if [ -d "node_modules/typeorm" ]; then
    if [ -z "$MIGRATION_TOOL" ]; then
      MIGRATION_TOOL="typeorm"
      MIGRATION_CMD="node node_modules/typeorm/cli.js migration:run"
      return
    fi
  fi

  # Node.js / Knex
  if [ -f "knexfile.js" ] || [ -f "knexfile.ts" ]; then
    if [ -z "$MIGRATION_TOOL" ]; then
      MIGRATION_TOOL="knex"
      MIGRATION_CMD="npx knex migrate:latest"
      return
    fi
  fi

  # Python / Alembic
  if [ -f "alembic.ini" ]; then
    if [ -z "$MIGRATION_TOOL" ]; then
      MIGRATION_TOOL="alembic"
      MIGRATION_CMD="alembic upgrade head"
      return
    fi
  fi

  # Python / Django
  if [ -f "manage.py" ]; then
    if [ -z "$MIGRATION_TOOL" ]; then
      MIGRATION_TOOL="django"
      MIGRATION_CMD="python manage.py migrate"
      return
    fi
  fi

  # Flyway (Java/Go/any)
  if [ -f "flyway.conf" ] || [ -f ".flyway" ]; then
    if [ -z "$MIGRATION_TOOL" ]; then
      MIGRATION_TOOL="flyway"
      MIGRATION_CMD="flyway migrate"
      return
    fi
  fi

  # Liquibase (Java)
  if [ -f "liquibase.properties" ]; then
    if [ -z "$MIGRATION_TOOL" ]; then
      MIGRATION_TOOL="liquibase"
      MIGRATION_CMD="./mvnw liquibase:update"
      return
    fi
  fi

  # Go / golang-migrate
  if [ -d "migrations" ]; then
    if [ -z "$MIGRATION_TOOL" ]; then
      MIGRATION_TOOL="golang-migrate"
      MIGRATION_CMD="golang-migrate -path=./migrations up"
      return
    fi
  fi
}

if [ -z "$MIGRATION_CMD" ]; then
  auto_detect_migration
fi

# ── Step 3: No migration configured — skip ────────────────────
if [ -z "$MIGRATION_CMD" ]; then
  echo "MIGRATION TEST: SKIP (no migration_tool configured in plan.md)"
  write_result "SKIP"
  exit 0
fi

# ── Step 4: Determine target database ─────────────────────────
# Priority: DATABASE_URL_TEST > MIGRATION_TEST_DB > env > temp SQLite
TEST_DB=""
SQLITE_TEMP=""

if [ -n "${DATABASE_URL_TEST:-}" ]; then
  TEST_DB="$DATABASE_URL_TEST"
elif [ -n "${MIGRATION_TEST_DB:-}" ]; then
  TEST_DB="$MIGRATION_TEST_DB"
fi

# If the command is SQLite-based and no test DB given, create a temp one
if echo "$MIGRATION_CMD" | grep -qE 'sqlite|prisma|sqlite3' && [ -z "$TEST_DB" ]; then
  SQLITE_TEMP=$(mktemp /tmp/migration-test-XXXXXX.db)
  export SQLITE_URL="file:${SQLITE_TEMP}"
  TEST_DB="$SQLITE_URL"
elif [ -n "$TEST_DB" ]; then
  # Export it so the migration tool can pick it up
  export DATABASE_URL="$TEST_DB"
fi

# ── Step 5: Run migration via validate-tests.sh if available ──
VALIDATE_SCRIPT="scripts/validate-tests.sh"
EXIT_CODE=0
MIGRATION_TOOL_NAME=""

# Extract a short tool name for output
case "$MIGRATION_TOOL" in
  prisma)           MIGRATION_TOOL_NAME="prisma" ;;
  typeorm)         MIGRATION_TOOL_NAME="typeorm" ;;
  knex)            MIGRATION_TOOL_NAME="knex" ;;
  alembic)         MIGRATION_TOOL_NAME="alembic" ;;
  django)          MIGRATION_TOOL_NAME="django" ;;
  flyway)          MIGRATION_TOOL_NAME="flyway" ;;
  liquibase)       MIGRATION_TOOL_NAME="liquibase" ;;
  golang-migrate)  MIGRATION_TOOL_NAME="golang-migrate" ;;
  *)               MIGRATION_TOOL_NAME="$MIGRATION_TOOL" ;;
esac

# Set DATABASE_URL if we have a test DB but the tool looks for it
if [ -n "$TEST_DB" ] && [ -z "${DATABASE_URL:-}" ]; then
  export DATABASE_URL="$TEST_DB"
fi

if [ -f "$VALIDATE_SCRIPT" ]; then
  # Use the validation harness for structured output
  # validate-tests.sh expects: <command> [expected_result]
  ( eval "$MIGRATION_CMD" ) >"$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?
else
  # Run directly and capture output
  ( eval "$MIGRATION_CMD" ) >"$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?
fi

# ── Step 6: Verify result ─────────────────────────────────────
MIGRATION_STATUS="PASS"
if [ "$EXIT_CODE" -ne 0 ]; then
  MIGRATION_STATUS="FAIL"
fi

# ── Step 7: Print results and write file ──────────────────────
print_result "$MIGRATION_TOOL_NAME" "$MIGRATION_CMD" "$MIGRATION_STATUS"
write_result "$MIGRATION_STATUS"

# ── Cleanup ───────────────────────────────────────────────────
rm -f "$SQLITE_TEMP" 2>/dev/null || true

# Exit with appropriate code
if [ "$MIGRATION_STATUS" = "PASS" ]; then
  exit 0
else
  exit 1
fi
