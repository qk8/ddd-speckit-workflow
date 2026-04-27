# speckit.check

Run all quality checks for the current task.

This command:
1. Reads the current task from tasks.md
2. Loads preset.yml, derives routing from checks[].applies_to for the task type
3. For each applicable check [X]:
   - Verifies the sub-check file exists at commands/checks/check_[X]_[name].mdc
   - If missing: reports "CHECK [X] SKIPPED — sub-check file not found" and continues
   - If found but empty or malformed: reports "CHECK [X] SKIPPED — file empty" and continues
   - Executes the check instructions
   - Records result
4. Prints results summary: "CHECK [X] NAME: PASS | FAIL — details"

Run only the checks in the applicable set. Do not run checks outside the set.
