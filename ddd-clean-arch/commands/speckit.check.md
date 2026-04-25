# speckit.check

Run all quality checks for the current task.

This command:
1. Reads the current task from tasks.md
2. Loads preset.yml, finds the routing entry for the task type
3. For each applicable check [X]:
   - Reads the sub-check file from commands/checks/check_[X]_[name].mdc
   - Executes the check instructions
   - Records result
4. Prints results summary: "CHECK [X] NAME: PASS | FAIL — details"

─────────────────────────────────────────
ROUTING TABLE (from preset.yml)
─────────────────────────────────────────
  backend-domain    → [A] [B] [C] [D] [M] [P]
  backend-infra     → [A] [B] [C] [D] [E] [F] [M] [O] [Q]
  backend-api       → [A] [B] [C] [D] [E] [G] [I] [J] [K] [L] [M] [N] [O] [Q] [T] [U]
  shared            → [A] [B] [C] [D] [E] [K] [L] [M] [N] [T]
  frontend-data     → [B] [C] [D] [G] [L] [O] [P]
  frontend-feature  → [B] [C] [D] [G] [H] [L] [O] [P]
  e2e               → [B] [C] [D] [H] [P]
─────────────────────────────────────────

Run only the checks in the applicable set. Do not run checks outside the set.
