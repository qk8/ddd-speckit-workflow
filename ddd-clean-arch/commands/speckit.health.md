# ── speckit.health — Project Health Dashboard ────────────────────
# Single command showing project health: task progress, check pass
# rates, error memory, test trends, complexity, drift, and risk.
#
# Process:
#   1. Run health dashboard script
#   2. Review grade and factors
#   3. Investigate low-scoring areas

─────────────────────────────────────────
STEP 1 — SHOW HEALTH DASHBOARD
─────────────────────────────────────────
Run: bash scripts/health-dashboard.sh "$(bash scripts/find-first-feature.sh)" --detailed
Read the output showing:
  - Overall health grade (A/B/C/D/F) and score (0-100)
  - Task progress (done/total, in-progress, todo, abandoned)
  - Check pass/fail rates with per-check breakdown
  - Error memory summary (corrections, drift patterns)
  - Test health (alerts, trends)
  - Complexity violations
  - Drift violations
  - Risk factors (abandoned, blocked, stagnation)
  - Detailed score breakdown by factor

─────────────────────────────────────────
STEP 2 — INVESTIGATE LOW-SCORING AREAS
─────────────────────────────────────────
Based on the dashboard, investigate areas with low scores:

If CHECKS have failures:
  Run: bash scripts/check-runner.sh "$(bash scripts/find-first-feature.sh)" <task_type> --tier critical
  Read failed results in .artifacts/check-results/<check_id>.result and fix them.

If ERROR_MEMORY has many corrections:
  Run: bash scripts/error-memory.sh summary "$(bash scripts/find-first-feature.sh)"
  Review the patterns and address root causes.

If COMPLEXITY violations are high:
  Read .artifacts/code-quality-results.txt
  Identify files with the most violations and refactor.

If DRIFT violations exist:
  Read .artifacts/post-implementation-drift.md
  Fix constraint violations.

─────────────────────────────────────────
STEP 3 — ACTION ITEMS
─────────────────────────────────────────
Print a summary of action items based on health grade:

Grade A (>= 85): Project is healthy. Continue current approach.
Grade B (>= 70): Good health. Address any FAIL checks and drift.
Grade C (>= 55): Fair health. Investigate error memory patterns and complexity.
Grade D (>= 40): Poor health. Prioritize fixing check failures and drift.
Grade F (< 40): Critical. May need to rollback or significant rework.
