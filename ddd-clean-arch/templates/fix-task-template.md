## FIX-TASK-FORMAT
Title: [Specific fix action, not generic "fix drift"]
Type: [type matching existing tasks — see plan.md §2]
Depends on: [tasks that produce the code being fixed — must be DONE]
Scope:
  Creates:
    - [exact file path to be created]
  Modifies:
    - [exact file path]
Acceptance criteria:
  - [Verifiable. Names exact class/method. Form: "calling X.Y() returns Z"]
  - [Test: [exact test file path] passes]
Do NOT:
  - [One scope-creep guard specific to this fix task.]
