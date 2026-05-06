DEPRECATED — use speckit.write-test.md + speckit.implement.md

This file is deprecated. The implementation workflow has been split into
three prompts for better LLM reliability:

1. speckit.write-test.md — Steps 1-1.5: TDD red phase (write failing tests,
   capture red evidence, test audit report)
2. speckit.implement.md — Step 2: implementation + inline correction loop
3. speckit.implement-verify.md — Steps 3-4: quality checks + completion report

The workflow YAML (ddd-workflow.yml) calls these in sequence.
Do NOT use this file directly.
