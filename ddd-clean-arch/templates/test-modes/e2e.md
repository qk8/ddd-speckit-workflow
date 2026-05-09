Run: plan.md §13 regression_command.e2e_only  (headless first)
Print full output.
Apply flaky test detection protocol (see above).
E2E tests are the most prone to flakiness — apply extra scrutiny.

After headless pass, ask: "Replay with Playwright MCP visible browser?"
If yes and Playwright MCP is available: replay and take screenshots.
