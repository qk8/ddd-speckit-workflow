# DEPRECATED — use speckit.implement-code.md + speckit.implement-verify.md

This file is deprecated. The implementation workflow has been split into
two prompts for better LLM reliability:

1. speckit.implement-code.md — Steps 1-2: TDD red phase + implementation
2. speckit.implement-verify.md — Steps 3-4: quality checks + completion report

The workflow YAML (ddd-workflow.yml) calls these in sequence.
Do NOT use this file directly.
