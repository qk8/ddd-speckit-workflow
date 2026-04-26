Read the feature preamble from templates/preamble.md.

This command reviews design quality — not tests (implement does that),
not spec compliance (verify does that).
It asks: is this code well-designed and free of hidden problems?

Ask: "Which task(s) to review?" (task number, file path, or "last task")
Resolve to a list of files. Read each file fully.
Read from plan.md: §2, §4, §6.

━━ DIMENSION 1: UBIQUITOUS LANGUAGE ━━━━

Compare all names in reviewed files against §2 and §4.
  NAMING: [found] in [file:line] | Spec: [exact name] | Severity: breaking | cosmetic
  NEW TERM: "[name]" in [file:line] — add to §2? [yes — definition | no — rename to existing]

━━ DIMENSION 2: INVARIANT ENFORCEMENT ━━

(Domain layer only: aggregates, value objects, domain services)
For each aggregate invariant from §4:
  INVARIANT: [text] | Enforcement: present | missing | relies on caller (violation)
  File: [file:line] | Risk: [production consequence]

Can any value object be constructed with an invalid value?
  VALUE OBJECT: [name] | Invalid construction: yes | no

━━ DIMENSION 3: HIDDEN COUPLING ━━━━━━━

Check for coupling not caught by static analysis:
  - Domain class knowing persistence concepts (table/column names in fields or comments)
  - Use case querying more than one aggregate root directly
  - Controller with conditional logic beyond input mapping
  - Repository returning more than the aggregate owns
  - Mutable value object (setters or public mutable fields)
  - Domain service with infrastructure imports
  - Feature component importing from data layer bypassing the intended interface
  - Two modules sharing a concrete class instead of an interface

  COUPLING: [description] | File: [file:line] | Rule: [from §6] | Fix: [one sentence]

━━ DIMENSION 4: CONVENTIONS CONSISTENCY ━

Compare code against .specify/memory/conventions.md.
  CONVENTION DRIFT: [name] | Says: [rule] | Code: [file:line]
  NEW PATTERN: [description] | In: [file:line] | Add to conventions.md? yes | no

━━ DIMENSION 5: READABILITY ━━━━━━━━━━━

Answer with specific file:line references:
  1. Method >20 lines that could be extracted? [file:line — how]
  2. Conditional branch purpose unclear without comments? [file:line — why complex]
  3. Public function with ambiguous success/failure contract? [file:line — what unclear]
  4. Error handling silently swallowing exception? [file:line — what lost]
  5. Magic number/string/unexplained constant? [file:line — where it should be]

━━ SUMMARY ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

REVIEW REPORT — [scope]
  Language: [N] violations, [N] new terms
  Invariants: [N] gaps
  Coupling: [N]
  Convention drift: [N], [N] new patterns
  Readability: [N]
  Assessment: CLEAN | REVISIT | REWORK

For blocking findings and new patterns: ask user. Apply only after confirmation.
New §2 terms: confirm then add to plan.md §2.
New conventions: confirm then add to .specify/memory/conventions.md with entry:
  [YYYY-MM-DD] [decision title]
    Context: [what situation prompted this]
    Decision: [what was chosen]
    Rationale: [why]
    Applied in: TASK-[N]
