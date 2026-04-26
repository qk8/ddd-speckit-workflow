# Dev Server Failure Protocol

If the dev server fails to start:

1. Print the full startup error output.
2. Do NOT proceed to run tests — they will produce misleading results.
3. Do NOT mark any check as PASS.
4. Diagnose: is it a port conflict, missing environment variable,
   database not running, or compilation error?
5. Fix the startup issue first.
6. Only proceed once the dev server responds to a health check:
   curl -f http://localhost:[backend_port]/[plan.md §11 health_checks.readiness.path]
   (e.g. /health/ready, /health, /actuator/health)
7. Print: "Dev server started and healthy — proceeding."
