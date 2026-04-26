# speckit.check

Run all quality checks for the current task.

This command:
1. Reads the current task from tasks.md
2. Loads preset.yml, derives routing from checks[].applies_to for the task type
3. For each applicable check [X]:
   - Reads the sub-check file from commands/checks/check_[X]_[name].mdc
   - Executes the check instructions
   - Records result
4. Prints results summary: "CHECK [X] NAME: PASS | FAIL — details"

Run only the checks in the applicable set. Do not run checks outside the set.
