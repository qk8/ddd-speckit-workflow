# DDD + Clean Architecture — Spec Kit Boilerplate

Production-grade software development workflow built on Spec Kit.
Adds Domain-Driven Design depth, Clean Architecture enforcement,
browser and API live testing, and quality gates.

## Repository structure

```
project-brief.md                           ← Fill this in first (single source of truth)
.gitignore                                 ← Covers .env, build outputs, OS files
.gitleaks.toml                             ← Secret scan config (created by setup-hooks.sh)
ddd-workflow.yml                           ← Full workflow definition
.claude/
  settings.json                            ← MCP server configuration (Playwright + Chrome DevTools)
scripts/
  setup-mcp.sh                             ← One-time MCP + Playwright setup (run once per machine)
  setup-hooks.sh                           ← One-time pre-commit hook setup (run once per machine)
  check-tasks.sh                           ← Task progress helper (used by workflow)
  validate-tasks.sh                        ← Task dependency graph validation (used by workflow)
  check-naming.sh                          ← Ubiquitous language validation (used by pre-commit hook)
  validate-api-contract.sh                 ← API contract enforcement (Check [K])
  ci-local.sh                              ← Run full CI pipeline locally (--fast | --e2e-only)
ddd-clean-arch/                            ← Preset
  preset.yml
  templates/
    plan-template.md                       ← 20-section architecture doc template
    tasks-template.md                      ← Structured backlog format
    constitution-template.md              ← Layer rules and constraints
  commands/
    speckit.implement.md                   ← Build override (11 checks: TDD + regression + security + browser + perf budget + contract)
ddd-quality-gates/                         ← Extension
  extension.yml
  commands/
    speckit.verify.md
    speckit.review.md
    speckit.retrospect.md
    speckit.status.md
    speckit.context.md
    speckit.test.md                        ← Standalone live test + debug command
```

## Prerequisites

```bash
# Spec Kit CLI
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
specify --version   # 0.7.x or later required

# Node.js 18+ (required for Playwright MCP)
node --version
```

## Setup

### Step 1 — Fill in project-brief.md

Edit `project-brief.md`. Fill in every field:
- Project name
- What the system does (2-5 sentences)
- Users and scale
- Stack (all 6 fields)
- Complexity: simple | medium | complex (controls retrospective cadence)
- Hard constraints, out of scope, external integrations, security posture

**This is the only place you enter project details.** The workflow reads from here.

### Step 2 — Initialize and configure

```bash
specify init <your-project-name> --integration claude
cd <your-project-name>

specify preset add --dev /path/to/ddd-clean-arch --priority 5
specify extension add --dev /path/to/ddd-quality-gates --priority 5
specify workflow add /path/to/ddd-workflow.yml

cp /path/to/boilerplate/project-brief.md .
cp /path/to/boilerplate/.gitignore .
mkdir -p scripts .claude
cp /path/to/boilerplate/scripts/check-tasks.sh scripts/
cp /path/to/boilerplate/scripts/validate-tasks.sh scripts/
cp /path/to/boilerplate/scripts/check-naming.sh scripts/
cp /path/to/boilerplate/scripts/validate-api-contract.sh scripts/
cp /path/to/boilerplate/scripts/setup-mcp.sh scripts/
cp /path/to/boilerplate/scripts/setup-hooks.sh scripts/
cp /path/to/boilerplate/scripts/ci-local.sh scripts/
cp /path/to/boilerplate/.claude/settings.json .claude/
chmod +x scripts/*.sh
```

### Step 3 — Set up pre-commit hooks (local only)

```bash
bash scripts/setup-hooks.sh
```

Installs three pre-commit hooks that run on every `git commit`:
- **gitleaks** — blocks commits that contain secrets or credentials
- **Linter** — blocks commits with lint errors (auto-detected from project config)
- **Naming validation** — blocks commits with ubiquitous language violations (compares code names against plan.md §2)

Also creates `.gitleaks.toml` with the default ruleset.
If gitleaks produces a false positive, add an allowlist entry to `.gitleaks.toml`.

⚠️ Each developer must run this once per machine — git hooks are not committed.
Add `bash scripts/setup-hooks.sh` to your new developer onboarding checklist.

### Step 4 — Set up MCP for browser testing (local only)

```bash
bash scripts/setup-mcp.sh
```

Installs Playwright browsers and registers two MCP servers:
- **Playwright MCP** — browser testing (frontend-feature and e2e tasks)
- **Chrome DevTools MCP** — debugging (network, console, performance)

⚠️ **Local Claude Code only.** Does not work in the claude.ai/code web sandbox.
If you use the web sandbox, check [G] is skipped with a warning — all other checks still run.

### Step 5 — Run

```bash
specify workflow run ddd-full-cycle
```

To resume an interrupted workflow:
```bash
specify workflow list-runs
specify workflow resume <run-id>
```

## The 11 quality checks

| Check | What it does | Applies to |
|-------|-------------|-----------|
| [A] Arch tests | ArchUnit / dependency-cruiser layer enforcement | All |
| [B] New tests pass | Written before implementation (TDD, failing-first) | All |
| [C] Regression suite | Full test suite — zero new failures allowed | All |
| [D] Linter | No errors | All |
| [E] Dependency scan | No CRITICAL/HIGH CVEs in direct deps | All |
| [F] Migration test | Schema matches plan.md §12 exactly | backend-infra only |
| [G] Observability | Correlation ID, logging, error taxonomy assertions | backend-api, frontend-data |
| [H] Browser verification | Headless E2E + optional Playwright MCP visual replay | frontend-feature, e2e |
| [I] Secret scan | gitleaks — no credentials or secrets in committed files | All |
| [J] Performance budget | p95 response time / LCP within §10 budget | backend-api, frontend-feature |
| [K] Contract enforcement | API endpoints match api-contract.yaml | backend-api, shared |

### TDD and regression (checks [B] + [C])

Every task starts by writing a failing test, then implements until it passes ([B]).
After the new tests pass, the **full test suite** runs ([C]).
Zero new failures allowed — any regression must be fixed before the task is DONE.
This means every task automatically verifies all previously implemented features still work.

### How the test type is decided per task

| Task type | Test written first (TDD) | Tool |
|-----------|--------------------------|------|
| `backend-domain` | Unit test | JUnit 5 / Vitest / pytest |
| `backend-infra` | Integration test (real DB) | Testcontainers |
| `backend-api` | API test (full stack, running server) | REST Assured / Playwright API / pytest-httpx |
| `shared` | Contract test | Generated type diffing |
| `integration` | Integration test (cross-context) | Context-specific test framework |
| `frontend-data` | Unit test | Vitest / Jest |
| `frontend-feature` | E2E test (single feature) | Playwright |
| `e2e` | E2E test (cross-feature journey) | Playwright |

### Why e2e tasks come last (and why that's correct TDD)

`frontend-feature` tasks use TDD: Playwright E2E test written first, then feature implemented.
`e2e` tasks test journeys spanning multiple already-built features (e.g. "register → order → view history").
These cross-feature journeys can only be written after all dependent features are DONE.
Writing them last is not a TDD violation — it is the correct outside-in sequence.

### Check [H] — browser verification

After headless E2E passes, Playwright MCP opens a visible browser to replay the journey visually.
Chrome DevTools MCP reads console errors and network requests if anything fails.

⚠️ Playwright MCP requires local Claude Code. In the claude.ai/code web sandbox,
check [H] runs headless only — all other checks are unaffected.

### Debug protocol (check [H] fails)

1. Playwright MCP navigates to the failure state and takes a screenshot
2. Chrome DevTools MCP reads console errors and network requests
3. Correlation ID in the API response links the browser error to the backend log
4. Root cause is traced to its source layer before any fix

## Quality gate commands

| Command | When |
|---------|------|
| `/speckit.implement` | One task or batch (with --parallel) — main build loop |
| `/speckit.test` | Standalone test or debug session |
| `/speckit.verify` | Spec-code drift check |
| `/speckit.review` | Design quality review |
| `/speckit.retrospect` | Adaptive cadence (simple: 15, medium: 10, complex: 5 tasks) |
| `/speckit.status` | Progress dashboard |
| `/speckit.context` | Targeted spec loading |

### /speckit.test modes

| Mode | Use when |
|------|----------|
| `API_TEST` | Backend issue, no UI needed |
| `BROWSER_TEST` | UI interaction, form, navigation |
| `BROWSER_DEBUG` | Unknown bug — opens browser + DevTools |
| `FULL_JOURNEY` | End-to-end scenario verification |
