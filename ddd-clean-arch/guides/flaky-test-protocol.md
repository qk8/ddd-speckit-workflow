# Flaky Test Protocol

A flaky test is one that fails intermittently without a code change.
Flaky tests erode trust in the test suite. Left unaddressed, teams
start ignoring failures — at which point the suite provides no safety net.

## Definition

A test is flaky if it fails at least once without any code change in 20 runs.

## Detection

Monitor CI failure rates. Any test with >5% failure rate without code changes should be investigated.

## On Detection

1. **Quarantine immediately** — move to quarantine suite, do NOT delete
2. **Create a tracking ticket** — every quarantined test needs a tracking issue
3. **Set a deadline** — max 2 weeks in quarantine, then fix or delete with justification

## Fix Approach

1. Reproduce the flakiness locally (run the test 20 times in a loop)
2. Identify root cause category:
   - **Timing**: test doesn't wait for async operation → fix: explicit wait conditions, not fixed `sleep()`
   - **Shared state**: test depends on data from another test → fix: test data isolation
   - **Race condition**: concurrent operations produce non-deterministic result → fix: deterministic test setup or mock the concurrency
   - **Environment**: test depends on network, clock, or OS-specific behavior → fix: mock the external dependency or use test-stable values
3. Fix the root cause (not the symptom — do not add retry logic)
4. While in quarantine: run 5 times to confirm flakiness.
   After fix: run 50 times to confirm stability before removing from quarantine.

## Forbidden

- Never add retry logic to a test to hide flakiness
- Never skip a flaky test without a quarantine ticket
- Never keep a test in quarantine longer than the deadline without action
- Never use fixed `sleep()` / `Thread.sleep()` — use explicit wait conditions
