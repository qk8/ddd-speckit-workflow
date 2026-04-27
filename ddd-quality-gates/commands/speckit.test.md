Read CLAUDE.md fully.
Read the feature preamble from templates/preamble.md.

This command runs a targeted test session or debug session on demand —
independently of the implement loop.

ACCEPTED MODES (pass directly after the command, or wait to be asked):
  --regression    run the full test suite (all layers including browser)
  --fast          run arch + unit + integration + API tests (no browser)
  --e2e           run browser E2E tests only, then optionally visual replay
  --target [name] run tests for a specific feature, aggregate, or endpoint
  --debug [desc]  reproduce and diagnose a specific bug

Examples:
  /speckit.test --regression
  /speckit.test --fast
  /speckit.test --target "OrderAggregate"
  /speckit.test --debug "invoice list not loading"

If no mode is given, print the list above and ask: "Which mode?"
Do NOT infer the mode from context. If the user's intent is ambiguous,
ask: "Do you want to run existing tests (--target or --regression)
or investigate a failure (--debug)?"

Proceed only after the mode is explicit.

━━ STEP 1: CONFIRM MODE AND SCOPE ━━━━━━

Print:
  Mode: [--regression | --fast | --e2e | --target NAME | --debug DESC]
  Scope: [full suite | api_only | e2e_only | [feature/aggregate/endpoint name] | [bug description]]
  Commands to run: [derive from plan.md §13 regression_command for the chosen mode]

━━ STEP 2: START DEV ENVIRONMENT ━━━━━━━

Check if the backend and frontend are running on the dev ports from
plan.md §14 task_runner.dev. If not: start now.

  DEV SERVER FAILURE PROTOCOL: follow guides/dev-server-failure-protocol.md.

Print: "Dev environment: [already running | started — backend:[port] frontend:[port]]"

━━ FLAKY TEST DETECTION (applies to all regression modes) ━━━━━

If any test fails, re-run it 5 more times before diagnosing code issues.
If it passes on some runs: it is flaky.
  → Quarantine per guides/flaky-test-protocol.md
  → Do not treat a flaky failure as a code bug

━━ MODE: --regression ━━━━━━━━━━━━━━━━
  Read templates/test-modes/regression.md

━━ MODE: --fast ━━━━━━━━━━━━━━━
  Read templates/test-modes/fast.md

━━ MODE: --e2e ━━━━━━━━━━━━━━━━
  Read templates/test-modes/e2e.md

━━ MODE: --target ━━━━━━━━━━━━━━━━━━━━━━━
  Read templates/test-modes/target.md

━━ MODE: --debug ━━━━━━━━━━━━━━━━━━━━━━━━━━
  Read templates/test-modes/debug.md
