# Script Tests

Automated tests for the shell scripts in the parent directory.
These are the tests for the infrastructure that everything else depends on.

## Adding a new test

1. Create `test_<script-name>.sh` in this directory.
2. Source it from `run-tests.sh` (automatically picked up via glob).
3. Use `assert_eq`, `assert_contains`, `assert_not_contains` helpers.
4. Use `mktemp -d` for any temporary state. Clean up in a `trap`.

## Running tests

```bash
bash scripts/tests/run-tests.sh
```

## Design principles

- Each test is self-contained and idempotent.
- No test depends on another test's side effects.
- No test modifies files outside its `mktemp -d` directory.
- Tests run in bash 3.2 compatible mode (no bash 4+ features).
