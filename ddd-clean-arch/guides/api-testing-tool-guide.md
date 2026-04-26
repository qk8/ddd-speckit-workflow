# API Testing Tool Selection Guide

Derived from `backend_language` in `project-brief.md`.
Do not change this decision after the first task is implemented.

## Java

- **Tool**: REST Assured
- **Reason**: JUnit 5 ecosystem fit, expressive DSL, Spring Boot Test integration,
  runs as part of the existing Maven/Gradle test task
- **Runner**: `mvn test` or `gradle test` (same as unit tests)
- **Location**: `[backend-module]/src/test/java/api/`

## TypeScript / JavaScript (Node.js)

- **Tool**: Playwright (request API)
- **Reason**: single tool for both API and E2E, no additional dependency
- **Runner**: `npx playwright test --project=api`
- **Location**: `[backend-module]/tests/api/`

## Python

- **Tool**: pytest + httpx
- **Reason**: async-native, integrates with pytest fixtures
- **Runner**: `pytest tests/api/`
- **Location**: `[backend-module]/tests/api/`
