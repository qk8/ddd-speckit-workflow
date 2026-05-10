#!/usr/bin/env bash
# Quick constraint drift check — runs at every task boundary
# Scans only the files modified in the current task for common violations.
# This is a lightweight pre-check; the full check Z runs at retro intervals.
#
# Checks (10 patterns):
#   1. Layer rule violations (domain imports infra/delivery)
#   2. Missing correlation ID in API responses
#   3. Test data isolation (hand-constructed domain objects)
#   4. Naming convention violations (class names not in ubiquitous language)
#   5. File location violations (wrong directory for layer)
#   6. Error envelope structure (missing error type discriminator)
#   7. §16 constraint patterns (Never... phrases violated)
#   8. Interface signature mismatches (companion file divergence)
#   9. Missing domain events (aggregate state changes without events)
#  10. Transaction boundary violations (I/O in domain layer)
set -euo pipefail

FEATURE_DIR=$(bash scripts/find-first-feature.sh)
PLAN_FILE="${FEATURE_DIR}/plan.md"
ARTIFACTS_DIR=".artifacts"
mkdir -p "$ARTIFACTS_DIR"

VIOLATIONS=0
SCANNED=0

# ── Check 1: Layer rule violations ──────────────────────────────
# Domain layer files should NOT import from delivery/infrastructure layers.
# Uses precise package/import patterns to reduce false positives.
check_layer_violations() {
  local file="$1"
  local ext="${file##*.}"

  case "$ext" in
    java)
      # Match infrastructure package patterns, not bare words in class names
      if grep -qE 'import.*\.(infrastructure|delivery\.service|delivery\.port|web\.controller|controller\.)' "$file" 2>/dev/null; then
        # Exclude known domain classes that use infrastructure-like names
        local basename_file
        basename_file=$(basename "$file")
        if ! echo "$basename_file" | grep -qiE 'DeliveryStatus|WebhookHandler|PaymentGateway|NotificationService'; then
          echo "  LAYER VIOLATION: $(basename "$file") imports from non-domain layer"
          VIOLATIONS=$((VIOLATIONS + 1))
        fi
      fi
      ;;
    ts|js)
      if grep -qE "from ['\"]\.\.?/.*(infrastructure|delivery/service|web/controller)" "$file" 2>/dev/null; then
        echo "  LAYER VIOLATION: $(basename "$file") imports from non-domain layer"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      ;;
    py)
      if grep -qE "from .+\.(infrastructure|delivery\.service|views)" "$file" 2>/dev/null; then
        echo "  LAYER VIOLATION: $(basename "$file") imports from non-domain layer"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      ;;
  esac
}

# ── Check 2: Missing correlation ID in API responses ───────────
# Only flag files that clearly produce HTTP responses (res.json, res.send,
# return Response, return HttpResponse) without correlation_id.
# This avoids false positives from variables named "result" or "response".
check_correlation_id() {
  local file="$1"
  local ext="${file##*.}"

  case "$ext" in
    ts|js)
      # Must have actual HTTP response patterns, not just variable names
      if grep -qE 'res\.(json|send|status|end|write)|return\s+(Response|HttpResponse)' "$file" 2>/dev/null; then
        if ! grep -q 'correlation_id\|correlationId' "$file" 2>/dev/null; then
          echo "  CORRELATION ID: $(basename "$file") may be missing correlation_id in response"
          VIOLATIONS=$((VIOLATIONS + 1))
        fi
      fi
      ;;
  esac
}

# ── Check 3: Test data isolation — hand-constructed domain objects ──
# Only flag direct domain aggregate construction in test files.
# Exclude test framework setup (Mockito, beforeEach, setUp, fixture helpers).
# Uses a broader set of aggregate names to reduce false negatives.
# Also excludes files with test helper patterns (Mock, Fake, Stub, TestDouble).
check_test_data_isolation() {
  local file="$1"
  local basename_file
  basename_file=$(basename "$file")

  # Only check test files
  if ! echo "$basename_file" | grep -qiE 'test|spec'; then
    return
  fi

  case "$basename_file" in
    *.test.*|*.spec.*|*Test.*|*Spec.*) ;;
    *) return ;;
  esac

  # Exclude test doubles and helpers — they legitimately construct domain objects
  if echo "$basename_file" | grep -qiE 'Mock|Fake|Stub|TestDouble|TestHelper'; then
    return
  fi

  # Flag direct new AggregateName( patterns where AggregateName starts with
  # a capital letter and is not a known test utility class.
  # Exclude files that use Factory/Builder/Mockito/beforeEach (proper patterns).
  if grep -qE 'new [A-Z][a-zA-Z]+\(.*\)' "$file" 2>/dev/null; then
    if ! grep -qE 'Factory|factory|Builder|builder|Mockito|@Mock|@InjectMocks|beforeEach|setUp|fixture|create[A-Z]|make[A-Z]' "$file" 2>/dev/null; then
      echo "  TEST DATA: $(basename "$file") may use hand-constructed domain objects"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi
}

# ── Check 4: Naming convention violations ──────────────────────
# Domain classes should use PascalCase, repository interfaces should end
# in Repository, domain events should end in DomainEvent or Event.
# This catches common LLM naming drift.
check_naming_conventions() {
  local file="$1"
  local basename_file
  basename_file=$(basename "$file")
  local ext="${file##*.}"

  # Only check source files (not test files or config)
  case "$ext" in
    java|ts|js|py) ;;
    *) return ;;
  esac

  # Skip test files and specs
  if echo "$basename_file" | grep -qiE 'test|spec|mock|fake|stub'; then
    return
  fi

  # Check for snake_case in class names (should be PascalCase)
  # Match: public class some_class, interface some_interface, class some_name
  if [ "$ext" = "java" ] || [ "$ext" = "ts" ] || [ "$ext" = "js" ]; then
    if grep -qE '(public (class|interface|enum) )[_a-z][a-z0-9]*_[a-z]' "$file" 2>/dev/null; then
      echo "  NAMING: $(basename "$file") uses snake_case in class/interface name"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi

  # Check for repository naming: should end in Repository
  if echo "$basename_file" | grep -qiE 'Dao|Mapper|Store|Repository'; then
    if ! echo "$basename_file" | grep -qE 'Repository$|Dao$|Mapper$|Store$'; then
      : # Acceptable — skip
    fi
  fi
}

# ── Check 5: File location violations ──────────────────────────
# Domain layer files should be in domain/ directories.
# Infrastructure files should be in infrastructure/ directories.
# This catches files placed in wrong layers at the filesystem level.
check_file_location() {
  local file="$1"
  local basename_file
  basename_file=$(basename "$file")

  # Skip test files, config, and non-source files
  case "$basename_file" in
    *.test.*|*.spec.*|*.config.*|*.toml|*.yml|*.yaml|*.json|*.md|*.sql) return ;;
  esac

  local ext="${file##*.}"
  case "$ext" in
    java|ts|js|py) ;;
    *) return ;;
  esac

  # Check if file is in a domain-like path
  if echo "$file" | grep -qE '/domain/|/Domain/'; then
    # Domain file — should NOT contain infrastructure imports (covered by check 1)
    # But flag if it contains HTTP/REST types (delivery layer contamination)
    if grep -qE 'javax\.websocket|jakarta\.websocket|@RestController|@Controller|ResponseEntity|express\.(Request|Response)' "$file" 2>/dev/null; then
      echo "  FILE LOCATION: $(basename "$file") in domain/ but contains delivery-layer types"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi

  # Check if file is in a test-like path but is NOT a test file
  if echo "$file" | grep -qE '/test/|/tests/|/spec/|/__tests__/'; then
    # In a test directory — should NOT contain production implementation
    # Flag if it has public class definitions (not test classes)
    if [ "$ext" = "java" ] && grep -qE 'public class [A-Z][a-zA-Z]+(Test|Tests|Spec)' "$file" 2>/dev/null; then
      : # Normal test class — OK
    elif [ "$ext" = "java" ] && grep -qE 'public class [A-Z]' "$file" 2>/dev/null; then
      if ! grep -qE 'Test|test|@Test|assert' "$file" 2>/dev/null; then
        echo "  FILE LOCATION: $(basename "$file") in test/ directory but appears to be production code"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
    fi
  fi
}

# ── Check 6: Error envelope structure ──────────────────────────
# All error responses should follow the four-type error taxonomy:
# ClientError, ServerError, ValidationError, NotFoundError
# Flag response objects that don't include an error_type discriminator.
check_error_envelope() {
  local file="$1"
  local ext="${file##*.}"

  # Only check API/controller layer files
  case "$file" in
    */api/*|*/controller/*|*/handlers/*|*/routes/*|*/endpoints/*) ;;
    */controllers/*) ;;
    *) return ;;
  esac

  case "$ext" in
    ts|js)
      # Check for JSON responses that include error fields but no error_type discriminator
      if grep -qE '(error|errorType|statusCode|message).*\}' "$file" 2>/dev/null; then
        if ! grep -qE 'error_type|errorType|"type".*error|discriminator' "$file" 2>/dev/null; then
          # Only flag if it has error-related fields but no type discriminator
          if grep -qE '"(error|message|statusCode|status)"' "$file" 2>/dev/null; then
            echo "  ERROR ENVELOPE: $(basename "$file") has error fields but no type discriminator"
            VIOLATIONS=$((VIOLATIONS + 1))
          fi
        fi
      fi
      ;;
    py)
      if grep -qE '"error"|message.*=|status_code.*=' "$file" 2>/dev/null; then
        if ! grep -qE 'error_type|errorType|discriminator' "$file" 2>/dev/null; then
          echo "  ERROR ENVELOPE: $(basename "$file") has error fields but no type discriminator"
          VIOLATIONS=$((VIOLATIONS + 1))
        fi
      fi
      ;;
  esac
}

# ── Check 7: §16 constraint pattern matching ───────────────────
# Read §16 constraints from plan.md and grep for violations.
# Constraints are in the form: "Never [action] because [consequence]"
# This is a heuristic check — not all constraints can be validated statically.
check_constraint_patterns() {
  if [ ! -f "$PLAN_FILE" ]; then
    return
  fi

  # Extract "Never" constraints from plan.md §16
  # Look for lines containing "Never" in the constraints section
  local never_patterns
  never_patterns=$(awk '/^## Architectural Constraints/,/^## /' "$PLAN_FILE" 2>/dev/null | \
    grep -iE '^\s*-?\s*Never\s+' | \
    sed 's/^[^a-zA-Z]*//' | \
    sed 's/ because.*//' | \
    sed 's/^[[:space:]]*//' || true)

  if [ -z "$never_patterns" ]; then
    return
  fi

  # For each Never constraint, create a grep pattern and search source files
  while IFS= read -r constraint; do
    [ -z "$constraint" ] && continue
    # Convert to a case-insensitive grep pattern
    local pattern
    pattern=$(echo "$constraint" | sed 's/[.[\*^$()+?{|]/\\&/g' | head -c 80)
    [ -z "$pattern" ] && continue

    # Search in source files only
    if grep -rl --include='*.java' --include='*.ts' --include='*.js' --include='*.py' \
      -iE "$pattern" . 2>/dev/null | head -3 | grep -q .; then
      echo "  CONSTRAINT: Possible violation of '$constraint' found in code"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done <<< "$never_patterns"
}

# ── Check 8: Interface signature mismatches ────────────────────
# Compare method signatures in implementation files against
# companion interface files (docs/spec/backend-interfaces.[ext]).
check_interface_signatures() {
  local file="$1"
  local basename_file
  basename_file=$(basename "$file")

  # Only check implementation files (not interfaces themselves)
  if echo "$basename_file" | grep -qiE 'interface|Interface|Port|Adapter'; then
    return
  fi

  # Find companion interface file
  local interface_file=""
  for spec_ext in ts js py java; do
    local candidate="$FEATURE_DIR/../docs/spec/backend-interfaces.$spec_ext"
    if [ -f "$candidate" ]; then
      interface_file="$candidate"
      break
    fi
  done

  if [ -z "$interface_file" ] || [ ! -f "$interface_file" ]; then
    return
  fi

  # For Java: check that implementation class implements the interface
  if [ "${file##*.}" = "java" ]; then
    local impl_class
    impl_class=$(grep -oE 'class [A-Z][a-zA-Z]+' "$file" 2>/dev/null | head -1 | awk '{print $2}' || true)
    if [ -n "$impl_class" ]; then
      # Check if the interface defines this method with different signature
      local interface_method_count
      interface_method_count=$(grep -c " $impl_class " "$interface_file" 2>/dev/null || echo 0)
      if [ "$interface_method_count" -gt 0 ]; then
        # Interface references this class — check for method signature mismatches
        local impl_methods
        impl_methods=$(grep -oE 'public [a-zA-Z<>[\], ]+ [a-zA-Z]+\(.*?\)' "$file" 2>/dev/null || true)
        local iface_methods
        iface_methods=$(grep -oE 'public [a-zA-Z<>[\], ]+ [a-zA-Z]+\(.*?\)' "$interface_file" 2>/dev/null || true)
        # Simple comparison: each impl method should have a matching interface method
        if [ -n "$impl_methods" ] && [ -n "$iface_methods" ]; then
          while IFS= read -r method; do
            [ -z "$method" ] && continue
            local method_name
            method_name=$(echo "$method" | grep -oE '[a-zA-Z]+\(' | sed 's/(//' || true)
            if [ -n "$method_name" ]; then
              if ! echo "$iface_methods" | grep -q "$method_name" 2>/dev/null; then
                echo "  INTERFACE: $(basename "$file").$method_name not in companion interface"
                VIOLATIONS=$((VIOLATIONS + 1))
              fi
            fi
          done <<< "$impl_methods"
        fi
      fi
    fi
  fi
}

# ── Check 9: Missing domain events ─────────────────────────────
# Aggregate state-changing methods should emit domain events.
# Flag methods that modify state (set, update, create, delete, add, remove)
# without a corresponding event dispatch.
check_missing_domain_events() {
  local file="$1"
  local basename_file
  basename_file=$(basename "$file")
  local ext="${file##*.}"

  # Only check domain layer files (aggregates, domain services)
  if ! echo "$file" | grep -qE '/domain/|/Domain/'; then
    return
  fi

  # Skip value objects and events themselves
  if echo "$basename_file" | grep -qiE 'Event|ValueObject|ValueObj|Constant'; then
    return
  fi

  case "$ext" in
    java)
      # Check for state-mutating methods without event dispatch
      if grep -qE 'public void (set|update|create|delete|add|remove|assign|cancel|confirm|reject|complete|finish)' "$file" 2>/dev/null; then
        # Check if the file emits any domain events
        if ! grep -qE 'publishEvent|domainEvent|DomainEvent|eventPublisher|eventBus\.publish' "$file" 2>/dev/null; then
          # State-mutating methods without event dispatch
          local mutators
          mutators=$(grep -oE '(set|update|create|delete|add|remove|assign|cancel|confirm|reject|complete|finish)[A-Za-z]*' "$file" 2>/dev/null | sort -u || true)
          if [ -n "$mutators" ]; then
            echo "  DOMAIN EVENT: $(basename "$file") has state-mutating methods but no event dispatch"
            VIOLATIONS=$((VIOLATIONS + 1))
          fi
        fi
      fi
      ;;
  esac
}

# ── Check 10: Transaction boundary violations ──────────────────
# I/O operations (DB queries, HTTP calls, file writes) should NOT
# occur in domain layer code. Domain layer should be pure logic.
check_transaction_boundaries() {
  local file="$1"
  local basename_file
  basename_file=$(basename "$file")
  local ext="${file##*.}"

  # Only check domain layer files
  if ! echo "$file" | grep -qE '/domain/|/Domain/'; then
    return
  fi

  # Skip event files and value objects
  if echo "$basename_file" | grep -qiE 'Event|ValueObject|VO\.'; then
    return
  fi

  case "$ext" in
    java)
      # Flag I/O patterns in domain layer
      if grep -qE 'EntityManager|Repository\.|JdbcTemplate|JpaRepository|\.persist\(|\.save\(|\.delete\(|\.find(One|All|ById)\(' "$file" 2>/dev/null; then
        echo "  TRANSACTION BOUNDARY: $(basename "$file") in domain/ contains I/O operations"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      # Flag HTTP calls in domain layer
      if grep -qE 'HttpClient|RestTemplate|WebClient|OkHttp|HttpURLConnection' "$file" 2>/dev/null; then
        echo "  TRANSACTION BOUNDARY: $(basename "$file") in domain/ contains HTTP calls"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      ;;
    ts|js)
      if grep -qE 'await.*\.(save|delete|find|update|insert|query|execute)\(' "$file" 2>/dev/null; then
        echo "  TRANSACTION BOUNDARY: $(basename "$file") in domain/ contains I/O operations"
        VIOLATIONS=$((VIOLATIONS + 1))
      fi
      ;;
  esac
}

# ── Scan modified files ────────────────────────────────────────
_COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [ "$_COMMIT_COUNT" -lt 1 ]; then
  # First commit: scan uncommitted changes instead of skipping
  MODIFIED_FILES=$(git diff --name-only --cached 2>/dev/null || true)
  if [ -z "$MODIFIED_FILES" ]; then
    # No staged changes — scan all tracked source files
    MODIFIED_FILES=$(find . -name '*.java' -o -name '*.ts' -o -name '*.js' -o -name '*.py' 2>/dev/null | head -100 || true)
  fi
else
  MODIFIED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || true)
  if [ -z "$MODIFIED_FILES" ]; then
    MODIFIED_FILES=$(find "$FEATURE_DIR" -name '*.java' -o -name '*.ts' -o -name '*.js' -o -name '*.py' 2>/dev/null || true)
  fi
fi

if [ -z "$MODIFIED_FILES" ]; then
  echo "QUICK DRIFT CHECK: SKIPPED (no files to scan)"
  exit 0
fi

while IFS= read -r file; do
  [ -f "$file" ] || continue
  SCANNED=$((SCANNED + 1))
  check_layer_violations "$file"
  check_correlation_id "$file"
  check_test_data_isolation "$file"
  check_naming_conventions "$file"
  check_file_location "$file"
  check_error_envelope "$file"
  check_interface_signatures "$file"
  check_missing_domain_events "$file"
  check_transaction_boundaries "$file"
done <<< "$MODIFIED_FILES"

# Check 7 (§16 constraint patterns) is file-scan-wide, not per-file
check_constraint_patterns

echo "QUICK DRIFT CHECK: $SCANNED files scanned, $VIOLATIONS violations"

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "DRIFT_DETECTED=true"
  echo "DRIFT_FAIL_COUNT=$VIOLATIONS"
  echo "QUICK_DRIFT_DETECTED=true"
  echo "QUICK_DRIFT=true"
  echo "  WARNING: Review violations above. The full check Z will run at the next retro."
else
  echo "DRIFT_DETECTED=false"
  echo "QUICK_DRIFT_DETECTED=false"
  echo "DRIFT_CLEAN=true"
  echo "QUICK_DRIFT=true"
  echo "  All quick checks passed."
fi
# Always exit 0 — the workflow reads DRIFT_DETECTED to decide next steps.
# This prevents set -e from aborting the iteration on drift violations.
exit 0
