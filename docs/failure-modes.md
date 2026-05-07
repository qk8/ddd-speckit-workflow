# Failure Mode Catalog

Known failure patterns in the Spec Kit workflow and their recovery procedures.

## 1. Silent Spec Drift

**Symptom:** Code passes all checks but implements something different from the spec.

**Root Cause:** The LLM agent interprets ambiguous spec requirements differently than intended. The anti-hallucination check (L) catches this, but it only compares class/method names — not behavioral semantics.

**Detection:**
- Run `speckit.verify` with scope "full" before merging
- Check `.artifacts/drift_check_report.md` for constraint violations
- Review spec learnings in `pending-learnings.md` for unrecorded decisions

**Recovery:**
1. Run `speckit.verify full`
2. For each drift: decide fix in code (align to spec) or fix in spec (intentional deviation)
3. If fixing in code: add fix tasks to tasks.md and loop back to implement
4. If fixing in spec: update plan.md and tasks.md, re-run drift check

**Prevention:**
- Ensure spec has CITE-enforced findings from adversarial audit
- Every acceptance criterion must reference exact class/method names
- Run `speckit.check [Z]` after each task, not just periodically

---

## 2. Test Fixing to Match Broken Implementation

**Symptom:** Tests pass but the implementation is wrong. Tests were modified to match the buggy code.

**Root Cause:** LLM agents have a strong bias toward making tests pass. When implementation is wrong, the agent may "fix" the test instead of the implementation.

**Detection:**
- The diagnostic classifier (`diagnostic-classifier.sh`) catches this by classifying failures as FIX_TEST vs FIX_IMPL
- Test quality review (check P) flags trivial assertions
- Adversarial audit of tests before implementation

**Recovery:**
1. Revert test changes
2. Run `diagnostic-classifier.sh` on the original failure
3. If classification is FIX_TEST: fix the test, not the implementation
4. If classification is FIX_IMPL: fix the implementation, not the test
5. If classification is HUMAN: escalate to human review

**Prevention:**
- Never let the agent self-classify failures
- Always run diagnostic classifier before any fix attempt
- TDD gate (`review-tdd`) requires red phase evidence

---

## 3. Parallel Batch File Conflicts

**Symptom:** Two tasks in the same parallel batch modify the same file, causing merge conflicts or lost changes.

**Root Cause:** The DAG-based parallel batching doesn't validate that tasks in the same batch don't modify the same files.

**Detection:**
- `validate-tasks.sh --batch-plan` computes dependency levels but doesn't check file overlap
- Build fails after a parallel batch with unmergeable conflicts

**Recovery:**
1. Identify conflicting tasks from `tasks.md`
2. Reset conflicting tasks to TODO
3. Run tasks sequentially in dependency order
4. Report the conflict for plan.md revision

**Prevention:**
- `validate-tasks.sh` now detects batch file conflicts (I3 fix)
- Tasks in the same batch MUST NOT modify the same files
- If they do, the batch is serialized automatically

---

## 4. Stagnation Loop

**Symptom:** The implement loop runs many iterations but no tasks complete. Revision count increases without progress.

**Root Cause:** The agent keeps attempting to fix the same issue without making progress. This can happen when:
- The spec is impossible to implement with the given stack
- The task is too large (should be split)
- Tests are flaky or incorrectly written

**Detection:**
- `check-stagnation.sh` detects when no new tasks complete for N consecutive iterations
- `check-task-revisions.sh` tracks revision count per task

**Recovery:**
1. Run `speckit.status` to diagnose
2. Run `speckit.context` for focused context on the stuck task
3. If the task is too large: abort, split into smaller tasks in tasks.md
4. If the spec is unrealistic: revise spec.md and plan.md
5. If tests are broken: abandon the task and create a new one

**Prevention:**
- Stagnation gate offers "troubleshoot" option
- Revision limit per task (default: 3) prevents infinite loops
- Auto-approve at revision threshold prevents wasted iterations

---

## 5. Check Runner Script Crash

**Symptom:** `check-runner.sh` exits with a crash instead of PASS/FAIL. No result file is written.

**Root Cause:** A check script has a syntax error, missing dependency, or unexpected output format.

**Detection:**
- `check-runner.sh` reports "CRASH (no result file)"
- `.artifacts/check-results/` directory is empty or missing expected files

**Recovery:**
1. Check the exit code of the failing check script directly
2. Run the check script manually with verbose output
3. Fix the script or remove the check from the routing table
4. Re-run the workflow

**Prevention:**
- `scripts/tests/test-workflow-scripts.sh` tests all check scripts (C3 fix)
- Each check script should have a clear exit code convention (0=PASS, 1=FAIL)
- Check scripts should write result files even on crash

---

## 6. Checkpoint Corruption

**Symptom:** The workflow can't resume after an interruption. `.workflow-state.json` is corrupted or missing.

**Root Cause:** The checkpoint write failed mid-write, leaving a partial JSON file. Or the file was manually edited incorrectly.

**Detection:**
- `check-point.sh read` returns invalid JSON
- `check-tasks-safe.sh` can't find checkpoint data

**Recovery:**
1. Check `.tasks-state.json` (fallback checkpoint from check-tasks.sh)
2. If both are corrupted: parse tasks.md directly
3. Re-run `check-point.sh write task_done` for each completed task
4. Verify against tasks.md DONE entries

**Prevention:**
- Checkpoint writes use atomic mv (write to temp, then mv)
- `.tasks-state.json` is written by check-tasks.sh on every run
- Regular backups via `backup-tasks.sh`

---

## 7. False Confidence from Passing Checks

**Symptom:** All 21 checks PASS but the system doesn't work in production.

**Root Cause:** The checks validate static properties (naming, layer rules, lint) but not dynamic behavior (correct error handling, proper transaction boundaries, race conditions).

**Detection:**
- Integration smoke test (`integration-smoke.sh`) fails after all per-task checks pass
- End-to-end tests fail in staging
- Production incidents reveal gaps

**Recovery:**
1. Run `integration-smoke.sh` to identify integration-level failures
2. Run `regression-baseline.sh` to compare against golden baseline
3. Add specific tests for the failure scenario
4. Consider adding a new check to the routing table

**Prevention:**
- C1: Full regression baseline after implement loop
- C2: Integration smoke test before code review
- N5: Post-deployment verification phase
- Check profiles (I1): Don't run irrelevant checks that give false confidence

---

## 8. Auto-Approve Without Visibility

**Symptom:** Gates auto-approve but the human reviewer has no visibility into why.

**Root Cause:** When `auto_approve.enabled: true`, the gate skips to approve without showing the check results.

**Detection:**
- Review gate shows "APPROVED" with no detail
- Later discovery that a critical check was skipped

**Recovery:**
1. Run `check-gate-preconditions.sh` manually to see results
2. Check `.artifacts/check-results/` for individual check results
3. If issues found: re-run the gate with `GATE_FORCE_HUMAN=true`

**Prevention:**
- C4: Auto-approve now outputs `AUTO_APPROVE_SUMMARY` with check results
- Always review the summary before approving
- Non-auto-approvable gates (TDD, plan revision, speckit-review) always require human approval

---

## 9. Shell Script Silent Failure

**Symptom:** A shell script fails silently and the workflow proceeds with incorrect state.

**Root Cause:** A script uses `set -e` but the calling code doesn't check the exit code. Or the script outputs to stderr which is captured but not checked.

**Detection:**
- Unexpected state in tasks.md or checkpoint files
- Check results are missing or stale

**Recovery:**
1. Run the failing script manually
2. Check the script's exit code
3. Fix the script and re-run the workflow from the checkpoint

**Prevention:**
- All scripts should use `set -euo pipefail`
- All scripts should exit with clear codes (0=success, non-zero=failure)
- `test-workflow-scripts.sh` validates script output formats (C3 fix)

---

## 10. Context Window Overflow

**Symptom:** The LLM produces truncated or incoherent output. The workflow hangs or produces garbled tasks.md.

**Root Cause:** The prompt context (plan.md + spec.md + CLAUDE.md + task details) exceeds the model's context window.

**Detection:**
- LLM output is truncated mid-sentence
- tasks.md has partial task entries
- Plan sections are missing

**Recovery:**
1. Check the prompt context size (plan.md line count + spec.md line count)
2. Reduce context by using `speckit.context` for targeted loading
3. Split large tasks into smaller ones
4. Consider a simpler project profile (I1) with fewer checks

**Prevention:**
- CLAUDE.md target: 100 lines
- Plan sections loaded per-task via `spec-sections.md` mapping
- `prompt-context.sh` generates targeted context for each task
- Check profiles (I1) reduce check-related context
