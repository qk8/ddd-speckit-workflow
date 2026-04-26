# Test Data Strategy Guide

Every test must set up its own data and clean up after itself.
Tests must never depend on data created by other tests.
Tests must be runnable in any order and in parallel.

## Approach Options

### test_containers_per_test
- Cleanest isolation, slowest startup
- Use for: integration tests with real databases
- Each test gets its own Testcontainers instance

### shared_db_with_cleanup
- Single test DB, each test cleans up in `@AfterEach` / `afterEach`
- Use for: API tests (faster than per-test containers)
- Requires careful cleanup to avoid cross-test pollution

### factory_functions
- Helper functions that create valid domain objects for tests
- Use for: unit tests (no DB needed)
- Use exact class names and invariants from plan.md §4

## E2E Data Setup

### api_seeding
- E2E tests call the API to create their own test data before running
- Most realistic, tests the full stack including auth

### db_seeding
- Direct DB insert via a test helper endpoint or migration-style script
- Faster, but bypasses application logic

### before_each_hook
- Playwright `beforeEach` creates data, `afterEach` cleans up

## Forbidden

- Tests must never share state through static variables or module-level singletons
- Tests must never read data written by a different test
- Tests must never depend on test execution order
- E2E tests must never reuse user accounts created by other tests
