#!/usr/bin/env python3
"""state.py — Python + SQLite replacement for state-engine.sh.

CLI interface (identical to state-engine.sh):
    python3 state.py <command> <feature_dir> [args...]

Commands:
    init, read, write, delete, validate, migrate, generate-tasks-md,
    history-append, history-prune, spec-increment, cadence-increment,
    cadence-reset, context-increment, context-reset, task-set, task-incr,
    fix-cycles-increment, fix-cycles-reset

SQLite uses WAL mode for proper concurrency — no flock needed.
"""

import sys
import os
import re
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

# ── Constants ──────────────────────────────────────────────────────

CADENCE_KNOWN_KEYS = ("traceability_counter",)

VALID_TASK_STATUSES = {"TODO", "IN_PROGRESS", "DONE", "ABANDONED", "BLOCKED"}

_SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "state.py")

REQUIRED_TOP_KEYS = ("version", "tasks", "history", "stagnation", "revisions", "metadata")

DEFAULT_STATE = {
    "version": 1,
    "tasks": {},
    "history": [],
    "stagnation": {
        "consecutive_no_progress": 0,
        "consecutive_continues": 0,
        "drift_violations": 0,
        "total_abort_count": 0,
        "last_done_count": 0,
    },
    "revisions": {
        "plan_review": 0,
        "tasks_phase": 0,
        "fix_needed": 0,
        "per_task": {},
    },
    "fix_cycles": 0,
    "spec": {
        "version": 1,
        "last_revision_at": None,
    },
    "auto_revise": {
        "count": 0,
        "last_gate": None,
    },
    "cadence": {
        "traceability_counter": 0,
        "traceability_interval": 15,
    },
    "context": {
        "generation_count": 0,
        "last_snapshot": None,
        "rotation_threshold": 10,
        "session_age": 0,
        "reset_threshold": 15,
    },
    "context_summary": {
        "last_compacted": None,
        "patterns_count": 0,
        "corrections_count": 0,
        "decisions_count": 0,
        "pruned_checkpoints": 0,
        "pruned_error_memory": 0,
    },
    "risk_profile": "low",
    "workflow": {
        "skip_commits": False,
        "commit_policy": "per-task",
        "last_commit_sha": None,
    },
    "token_budget": {
        "actual_input_tokens": 0,
        "actual_output_tokens": 0,
        "cache_creation_tokens": 0,
        "cache_read_tokens": 0,
        "sessions_count": 0,
        "projected_total": 0,
        "avg_tokens_per_task": 0,
        "risk": "OK",
        "estimated_cost": "0.00",
        "projected_cost": "0.00",
    },
    "_impl": {
        "loop_count": 0,
    },
    "metadata": {
        "created_at": None,
        "updated_at": None,
        "feature_dir": None,
        "workflow_version": "2.0.0",
    },
}


# ── Helpers ────────────────────────────────────────────────────────

def now_utc():
    """Return current UTC timestamp in ISO 8601 format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def get_db_path(feature_dir):
    """Return path to the SQLite database for a feature directory."""
    db_dir = Path(feature_dir) / ".artifacts"
    db_dir.mkdir(parents=True, exist_ok=True)
    return db_dir / "workflow.db"


def get_conn(feature_dir):
    """Open a SQLite connection with WAL mode and foreign keys."""
    db_path = get_db_path(feature_dir)
    conn = sqlite3.connect(str(db_path), timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.row_factory = sqlite3.Row
    return conn


def ensure_schema(conn):
    """Create tables if they don't exist."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS state_blob (
            feature_dir TEXT PRIMARY KEY,
            state_json TEXT NOT NULL,
            updated_at TEXT DEFAULT (datetime('now', 'utc'))
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS kv_store (
            feature_dir TEXT NOT NULL,
            dot_path TEXT NOT NULL,
            value TEXT NOT NULL,
            updated_at TEXT DEFAULT (datetime('now', 'utc')),
            PRIMARY KEY (feature_dir, dot_path)
        )
    """)
    conn.commit()


def load_state(conn, feature_dir):
    """Load state_json from state_blob, falling back to state.json on disk."""
    # Try the feature_dir as given
    row = conn.execute(
        "SELECT state_json FROM state_blob WHERE feature_dir = ?",
        (feature_dir,),
    ).fetchone()
    if row and row["state_json"]:
        return json.loads(row["state_json"])
    # Try resolved path (in case init resolved it but caller didn't)
    resolved = str(Path(feature_dir).resolve())
    if resolved != feature_dir:
        row = conn.execute(
            "SELECT state_json FROM state_blob WHERE feature_dir = ?",
            (resolved,),
        ).fetchone()
        if row and row["state_json"]:
            return json.loads(row["state_json"])
    # Fallback: read state.json from disk (backward compatibility)
    state_file = Path(feature_dir) / "state.json"
    if state_file.exists():
        try:
            return json.loads(state_file.read_text())
        except (json.JSONDecodeError, ValueError):
            pass
    return {}


def save_state(conn, feature_dir, state):
    """Save state_json to state_blob AND write state.json to disk."""
    ts = now_utc()
    state["metadata"]["updated_at"] = ts
    state["metadata"]["feature_dir"] = str(Path(feature_dir).resolve())
    json_str = json.dumps(state, indent=2, default=str)
    conn.execute(
        """INSERT OR REPLACE INTO state_blob (feature_dir, state_json, updated_at)
           VALUES (?, ?, ?)""",
        (feature_dir, json_str, ts),
    )
    # Also write to disk for backward compatibility with scripts
    # that read state.json directly (e.g., increment-iteration.sh)
    state_file = Path(feature_dir) / "state.json"
    state_file.write_text(json_str + "\n")


def ensure_exists(feature_dir):
    """Auto-create state.json scaffold if no blob exists yet."""
    conn = get_conn(feature_dir)
    ensure_schema(conn)
    if load_state(conn, feature_dir) == {}:
        state = json.loads(json.dumps(DEFAULT_STATE))
        save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()


def coerce_value(value_str):
    """Coerce string value to JSON type (int, bool, null, or str)."""
    if re.match(r"^[0-9]+$", value_str):
        return int(value_str)
    if value_str in ("true", "false", "null"):
        return json.loads(value_str)
    return value_str


def set_nested(state, dot_path, value):
    """Set a value at a dot-notation path in a nested dict."""
    parts = dot_path.split(".")
    obj = state
    for part in parts[:-1]:
        if part not in obj or not isinstance(obj[part], dict):
            obj[part] = {}
        obj = obj[part]
    obj[parts[-1]] = value


def get_nested(state, dot_path):
    """Get a value at a dot-notation path from a nested dict."""
    parts = dot_path.split(".")
    obj = state
    for part in parts:
        if not isinstance(obj, dict) or part not in obj:
            return None
        obj = obj[part]
    return obj


def del_nested(state, dot_path):
    """Delete a value at a dot-notation path from a nested dict."""
    parts = dot_path.split(".")
    obj = state
    for part in parts[:-1]:
        if not isinstance(obj, dict) or part not in obj:
            return
        obj = obj[part]
    if isinstance(obj, dict) and parts[-1] in obj:
        del obj[parts[-1]]


def resolve_feature_dir(feature_dir):
    """Resolve feature directory to absolute path."""
    return str(Path(feature_dir).resolve())


# ── Commands ───────────────────────────────────────────────────────

def cmd_init(args):
    """Create empty state.json scaffold."""
    feature_dir = resolve_feature_dir(args.feature_dir)
    os.makedirs(feature_dir, exist_ok=True)
    state = json.loads(json.dumps(DEFAULT_STATE))
    conn = get_conn(feature_dir)
    ensure_schema(conn)
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()
    state_file = Path(feature_dir) / "state.json"
    print(f"INIT: state.json created at {state_file}")


def cmd_read(args):
    """Read any value using dot notation."""
    key = args.key
    if not key:
        print("Usage: state.py read <feature_dir> <key>", file=sys.stderr)
        sys.exit(1)
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    conn.close()
    value = get_nested(state, key)
    if value is None:
        print("", end="")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value))
    else:
        print(value)


def cmd_write(args):
    """Atomic write with type coercion."""
    key = args.key
    value = args.value if args.value is not None else ""
    if not key:
        print("Usage: state.py write <feature_dir> <key> <value>", file=sys.stderr)
        sys.exit(1)
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    coerced = coerce_value(value)
    set_nested(state, key, coerced)
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()


def cmd_delete(args):
    """Delete a key at dot-notation path."""
    key = args.key
    if not key:
        print("Usage: state.py delete <feature_dir> <key>", file=sys.stderr)
        sys.exit(1)
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    del_nested(state, key)
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()


def cmd_validate(args):
    """Validate state.json schema."""
    feature_dir = resolve_feature_dir(args.feature_dir)
    ensure_exists(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    conn.close()

    # Check required top-level keys
    missing = [k for k in REQUIRED_TOP_KEYS if k not in state]
    if missing:
        print(f"VALIDATION: FAIL — missing keys: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    # Check version is 1
    if state.get("version") != 1:
        print(f"VALIDATION: FAIL — version must be 1, got {state.get('version')}", file=sys.stderr)
        sys.exit(1)

    # Check tasks is object
    if not isinstance(state.get("tasks"), dict):
        print("VALIDATION: FAIL — tasks must be an object", file=sys.stderr)
        sys.exit(1)

    # Check each task has status and type
    bad_tasks = []
    for tid, task in state["tasks"].items():
        if not isinstance(task, dict) or "status" not in task or "type" not in task:
            bad_tasks.append(tid)
    if bad_tasks:
        print(f"VALIDATION: FAIL — tasks missing status/type: {', '.join(bad_tasks)}", file=sys.stderr)
        sys.exit(1)

    # Check task statuses are valid enum
    bad_statuses = []
    for tid, task in state["tasks"].items():
        status = task.get("status")
        if status and status not in VALID_TASK_STATUSES:
            bad_statuses.append(f"{tid}={status}")
    if bad_statuses:
        print("VALIDATION: FAIL — invalid task statuses:", file=sys.stderr)
        for entry in bad_statuses:
            print(f"  {entry} (valid: {', '.join(sorted(VALID_TASK_STATUSES))})", file=sys.stderr)
        sys.exit(1)

    # Check for self-referential dependencies
    self_refs = []
    for tid, task in state["tasks"].items():
        deps = task.get("depends_on", []) or task.get("dependencies", [])
        if isinstance(deps, list) and tid in deps:
            self_refs.append(tid)
    if self_refs:
        print(f"VALIDATION: FAIL — self-referential dependencies: {', '.join(self_refs)}", file=sys.stderr)
        sys.exit(1)

    # Check metadata.updated_at
    if not state.get("metadata", {}).get("updated_at"):
        print("VALIDATION: FAIL — metadata.updated_at is missing", file=sys.stderr)
        sys.exit(1)

    # Warn about tasks missing scope.creates
    missing_creates = []
    for tid, task in state["tasks"].items():
        scope = task.get("scope", {})
        if not isinstance(scope, dict) or not scope.get("creates"):
            missing_creates.append(tid)
    if missing_creates:
        print(f"WARNING: Tasks missing scope.creates: {', '.join(missing_creates)}", file=sys.stderr)

    print("VALIDATION: PASS")


def cmd_generate_tasks_md(args):
    """Generate tasks.md from state.json (output to stdout)."""
    feature_dir = resolve_feature_dir(args.feature_dir)
    ensure_exists(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    conn.close()

    lines = []
    lines.append("# Implementation Backlog")
    lines.append("")
    lines.append("One task = one speckit.implement session (max 5 files, max 1 aggregate).")
    lines.append("")
    lines.append("# HOW TDD WORKS")
    lines.append("# TDD is used throughout — see plan.md for the full explanation.")
    lines.append("Task order:")
    lines.append("1. backend-domain  (aggregate root, value objects, events, repo interface — one task per aggregate)")
    lines.append("2. backend-infra   (repo implementation, DB migration, external adapters — one task per aggregate)")
    lines.append("3. backend-api     (controller, use case, wired together — one task per endpoint group)")
    lines.append("4. shared          (contract types, generated code — after API contract is stable)")
    lines.append("5. integration     (cross-context boundary tests — one task per bounded context relationship)")
    lines.append("6. frontend-data   (data layer module — one task per bounded context)")
    lines.append("7. frontend-feature (feature components with Playwright E2E TDD — one task per major feature)")
    lines.append("8. e2e             (cross-feature journey tests — after all dependent features are DONE)")
    lines.append("")
    lines.append("-" * 75)

    tasks = state.get("tasks", {})
    for tid in sorted(tasks.keys()):
        task = tasks[tid]
        title = task.get("title", "Untitled")
        status = task.get("status", "TODO")
        task_type = task.get("type", "backend-domain")
        depends = task.get("depends_on", []) or task.get("dependencies", [])
        if isinstance(depends, list):
            depends_str = ", ".join(depends) if depends else "none"
        else:
            depends_str = "none"

        scope = task.get("scope", {})
        if not isinstance(scope, dict):
            scope = {}
        creates = scope.get("creates", []) or []
        modifies = scope.get("modifies", []) or []

        ac = task.get("acceptance_criteria", []) or []
        dn = task.get("do_not", []) or []

        lines.append(f"## {tid}:{title}")
        lines.append(f"Status: {status}")
        lines.append(f"Type: {task_type}")
        lines.append(f"Depends on: {depends_str}")
        lines.append("Scope:")
        lines.append("  Creates:")
        if creates:
            for c in creates:
                lines.append(f"    - {c}")
        else:
            lines.append("    - none")
        lines.append("  Modifies:")
        if modifies:
            for m in modifies:
                lines.append(f"    - {m}")
        else:
            lines.append("    - none")
        lines.append("Acceptance criteria:")
        if ac:
            for a in ac:
                lines.append(f"  - {a}")
        else:
            lines.append("  - (none)")
        lines.append("Do NOT:")
        if dn:
            for d in dn:
                lines.append(f"  - {d}")
        else:
            lines.append("  - Nothing specific")

        rev_count = task.get("revision_count", 0)
        if rev_count and rev_count > 0:
            lines.append(f"Revision count: {rev_count}")

        files = task.get("files_modified", []) or []
        if files:
            lines.append(f"Files: {', '.join(files)}")
        lines.append("")

    lines.append("-" * 75)
    print("\n".join(lines))


def cmd_history_append(args):
    """Append an entry to the history array."""
    entry_str = args.entry
    if not entry_str:
        print("Usage: state.py history-append <feature_dir> <json_entry>", file=sys.stderr)
        sys.exit(1)
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    try:
        entry = json.loads(entry_str)
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid JSON entry: {e}", file=sys.stderr)
        sys.exit(1)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    state.setdefault("history", []).append(entry)
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()


def cmd_history_prune(args):
    """Keep last N history entries."""
    keep = int(args.keep)
    if keep < 0:
        print("Usage: state.py history-prune <feature_dir> <keep>", file=sys.stderr)
        sys.exit(1)
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    history = state.get("history", [])
    state["history"] = history[-keep:] if keep > 0 else []
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()


def cmd_spec_increment(args):
    """Increment spec version and revisions."""
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    state["spec"]["version"] = state.get("spec", {}).get("version", 1) + 1
    state["spec"]["last_revision_at"] = now_utc()
    state["revisions"]["spec_total"] = state.get("revisions", {}).get("spec_total", 0) + 1
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()
    print(f"SPEC: version incremented to {state['spec']['version']}")


def cmd_cadence_increment(args):
    """Increment a cadence counter."""
    counter_key = args.counter_key
    if counter_key not in CADENCE_KNOWN_KEYS:
        print(f"ERROR: Unknown cadence counter key: {counter_key}. Known: {' '.join(CADENCE_KNOWN_KEYS)}", file=sys.stderr)
        sys.exit(1)
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    cadence = state.setdefault("cadence", {})
    cadence[counter_key] = cadence.get(counter_key, 0) + 1
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()
    print(f"CADENCE: {counter_key} incremented to {cadence[counter_key]}")


def cmd_cadence_reset(args):
    """Reset a cadence counter to 0."""
    counter_key = args.counter_key
    if counter_key not in CADENCE_KNOWN_KEYS:
        print(f"ERROR: Unknown cadence counter key: {counter_key}. Known: {' '.join(CADENCE_KNOWN_KEYS)}", file=sys.stderr)
        sys.exit(1)
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    state.setdefault("cadence", {})[counter_key] = 0
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()
    print(f"CADENCE: {counter_key} reset to 0")


def cmd_context_increment(args):
    """Increment session_age."""
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    state.setdefault("context", {})["session_age"] = state.get("context", {}).get("session_age", 0) + 1
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()
    print(f"CONTEXT: session_age incremented to {state['context']['session_age']}")


def cmd_context_reset(args):
    """Reset session_age and set last_snapshot."""
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    state.setdefault("context", {})["session_age"] = 0
    state.setdefault("context", {})["last_snapshot"] = now_utc()
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()
    print("CONTEXT: session_age reset to 0")


def cmd_fix_cycles_increment(args):
    """Increment fix_cycles counter."""
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    state["fix_cycles"] = state.get("fix_cycles", 0) + 1
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()
    print(f"FIX_CYCLES: incremented to {state['fix_cycles']}")


def cmd_fix_cycles_reset(args):
    """Reset fix_cycles to 0."""
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    state["fix_cycles"] = 0
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()
    print("FIX_CYCLES: reset to 0")


def cmd_task_set(args):
    """Set a field on a specific task."""
    tid = args.task_id
    tkey = args.field
    tval = args.value if args.value is not None else ""
    if not tid or not tkey:
        print("Usage: state.py task-set <feature_dir> <task_id> <key> <value>", file=sys.stderr)
        sys.exit(1)
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    state.setdefault("tasks", {}).setdefault(tid, {})
    state["tasks"][tid][tkey] = coerce_value(tval)
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()


def cmd_task_incr(args):
    """Increment a numeric field on a specific task."""
    tid = args.task_id
    tkey = args.field
    if not tid or not tkey:
        print("Usage: state.py task-incr <feature_dir> <task_id> <key>", file=sys.stderr)
        sys.exit(1)
    ensure_exists(args.feature_dir)
    feature_dir = resolve_feature_dir(args.feature_dir)
    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    state.setdefault("tasks", {}).setdefault(tid, {})
    current = state["tasks"][tid].get(tkey, 0)
    if not isinstance(current, (int, float)):
        current = 0
    state["tasks"][tid][tkey] = current + 1
    save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()


def cmd_migrate(args):
    """Migrate legacy files into state.json.

    Parses tasks.md, .workflow-state.json, revision counts, created files,
    stagnation state, check results, test health, and revision history.
    """
    feature_dir = resolve_feature_dir(args.feature_dir)
    rollback = getattr(args, "rollback", False)
    dry_run = getattr(args, "dry_run", False)

    if rollback:
        backup = f"{feature_dir}/state.json.pre-migration.bak"
        if os.path.exists(backup):
            import shutil
            shutil.copy2(backup, f"{feature_dir}/state.json")
            print("ROLLBACK: Restored state.json from pre-migration backup")
            sys.exit(0)
        else:
            print(f"ROLLBACK: No pre-migration backup found at {backup}")
            sys.exit(1)

    ensure_exists(args.feature_dir)
    state_file = Path(feature_dir) / "state.json"

    # Pre-migration backup
    backup_file = f"{feature_dir}/state.json.pre-migration.bak"
    if state_file.exists():
        import shutil
        shutil.copy2(str(state_file), backup_file)
        print(f"MIGRATE: Pre-migration backup saved to {backup_file}")

    # Dry-run mode
    if dry_run:
        changes = []
        if (Path(feature_dir) / "tasks.md").exists():
            changes.append(f"  - Would parse tasks.md ({feature_dir}/tasks.md)")
        if (Path(feature_dir) / ".workflow-state.json").exists():
            changes.append("  - Would merge .workflow-state.json")
        task_rev_dir = Path(feature_dir) / ".artifacts" / "task-revisions"
        if task_rev_dir.exists():
            changes.append("  - Would parse task revision counts")
        created_files_dir = Path(feature_dir) / ".artifacts" / "created-files"
        if created_files_dir.exists():
            changes.append("  - Would parse created files")
        if (Path(feature_dir) / ".stagnation_state").exists():
            changes.append("  - Would parse stagnation state")
        if (Path(feature_dir) / ".stagnation_total").exists():
            changes.append("  - Would parse stagnation total")
        check_results_dir = Path(feature_dir) / ".artifacts" / "check-results"
        if check_results_dir.exists():
            changes.append("  - Would parse check results")
        if (Path(feature_dir) / ".artifacts" / "test-health.json").exists():
            changes.append("  - Would parse test health data")
        if (Path(feature_dir) / "revision_history.md").exists():
            changes.append("  - Would parse revision history")
        if changes:
            print("MIGRATE DRY-RUN: The following changes would be made:")
            for c in changes:
                print(c)
            print("MIGRATE DRY-RUN: Run without --dry-run to apply.")
            sys.exit(0)
        else:
            print("MIGRATE DRY-RUN: No changes needed — state.json is up to date.")
            sys.exit(0)

    conn = get_conn(feature_dir)
    state = load_state(conn, feature_dir)
    migrated = False

    # 1. Parse tasks.md
    tasks_md = Path(feature_dir) / "tasks.md"
    if tasks_md.exists():
        print("MIGRATE: Parsing tasks.md...")
        tasks = _parse_tasks_md(tasks_md)
        if tasks:
            state["tasks"] = tasks
            migrated = True

    # 2. Merge .workflow-state.json
    workflow_state = Path(feature_dir) / ".workflow-state.json"
    if workflow_state.exists():
        print("MIGRATE: Merging .workflow-state.json...")
        try:
            with open(workflow_state) as f:
                ws = json.load(f)
            existing_tasks = state.get("tasks", {})
            checkpoint_tasks = ws.get("tasks", {})
            for tid, cp_task in checkpoint_tasks.items():
                if tid in existing_tasks and isinstance(cp_task, dict):
                    existing_tasks[tid].update(cp_task)
            state["tasks"] = existing_tasks
            migrated = True
        except (json.JSONDecodeError, KeyError):
            pass

    # 3. Parse .artifacts/task-revisions/*.count
    task_rev_dir = Path(feature_dir) / ".artifacts" / "task-revisions"
    if task_rev_dir.exists():
        print("MIGRATE: Parsing task revision counts...")
        rev_json = {}
        for count_file in sorted(task_rev_dir.glob("*.count")):
            tid = count_file.stem
            try:
                count = int(count_file.read_text().strip() or "0")
            except ValueError:
                count = 0
            rev_json[tid] = count
        state.setdefault("revisions", {})["per_task"] = rev_json
        migrated = True

    # 4. Parse .artifacts/created-files/*.files
    created_files_dir = Path(feature_dir) / ".artifacts" / "created-files"
    if created_files_dir.exists():
        print("MIGRATE: Parsing created files...")
        for files_file in sorted(created_files_dir.glob("*.files")):
            tid = files_file.stem
            lines = [l.strip() for l in files_file.read_text().strip().split("\n") if l.strip()]
            if lines:
                state.setdefault("tasks", {}).setdefault(tid, {})["files_modified"] = lines
                migrated = True

    # 5. Parse .stagnation_state
    stagnation_state = Path(feature_dir) / ".stagnation_state"
    if stagnation_state.exists():
        print("MIGRATE: Parsing stagnation state...")
        content = stagnation_state.read_text().strip().split("\n")
        prev_done = int(content[0]) if len(content) > 0 and content[0].lstrip("-").isdigit() else -1
        consec = int(content[1]) if len(content) > 1 and content[1].isdigit() else 0
        if prev_done < 0:
            prev_done = 0

        consec_val = 0
        continue_val = 0
        drift_val = 0
        consec_file = Path(feature_dir) / ".stagnation_state.consec"
        continue_file = Path(feature_dir) / ".stagnation_state.continue_count"
        drift_file = Path(feature_dir) / ".stagnation_state.drift_count"
        if consec_file.exists():
            try:
                consec_val = int(consec_file.read_text().strip() or "0")
            except ValueError:
                consec_val = 0
        if continue_file.exists():
            try:
                continue_val = int(continue_file.read_text().strip() or "0")
            except ValueError:
                continue_val = 0
        if drift_file.exists():
            try:
                drift_val = int(drift_file.read_text().strip() or "0")
            except ValueError:
                drift_val = 0

        state.setdefault("stagnation", {}).update({
            "consecutive_no_progress": consec_val,
            "consecutive_continues": continue_val,
            "drift_violations": drift_val,
            "last_done_count": prev_done,
        })
        migrated = True

    # 6. Parse .stagnation_total
    stagnation_total = Path(feature_dir) / ".stagnation_total"
    if stagnation_total.exists():
        print("MIGRATE: Parsing stagnation total...")
        try:
            abort_count = int(stagnation_total.read_text().strip() or "0")
        except ValueError:
            abort_count = 0
        state.setdefault("stagnation", {})["total_abort_count"] = abort_count
        migrated = True

    # 7. Parse .artifacts/check-results/*.result
    check_results_dir = Path(feature_dir) / ".artifacts" / "check-results"
    if check_results_dir.exists():
        print("MIGRATE: Parsing check results...")
        all_results = {}
        for result_file in sorted(check_results_dir.glob("*.result")):
            check_id = result_file.stem
            first_line = result_file.read_text().strip().split("\n")[0] if result_file.read_text().strip() else "SKIP"
            all_results[check_id] = first_line
        state["check_results"] = all_results
        migrated = True

    # 8. Parse .artifacts/test-health.json
    test_health = Path(feature_dir) / ".artifacts" / "test-health.json"
    if test_health.exists():
        print("MIGRATE: Parsing test health data...")
        try:
            with open(test_health) as f:
                th = json.load(f)
            entries = th.get("entries", [])
            for entry in entries:
                state.setdefault("history", []).append({
                    "phase": "test-health",
                    "task": entry.get("task_id", "unknown"),
                    "iteration": 0,
                    "result": "PASS" if entry.get("pass_rate") == 100 else "FAIL",
                    "timestamp": entry.get("completed_at", now_utc()),
                })
            migrated = True
        except (json.JSONDecodeError, KeyError):
            pass

    # 9. Parse revision_history.md
    rev_history = Path(feature_dir) / "revision_history.md"
    if rev_history.exists():
        print("MIGRATE: Parsing revision history...")
        state.setdefault("history", []).append({
            "phase": "revision",
            "task": "unknown",
            "iteration": 0,
            "result": "REVISION",
            "timestamp": now_utc(),
        })
        migrated = True

    if migrated:
        save_state(conn, feature_dir, state)
        conn.commit()

        # Validate
        task_count = len(state.get("tasks", {}))
        if task_count == 0:
            print("MIGRATE WARNING: state.json has 0 tasks — migration may have failed")
        else:
            print(f"MIGRATE: Validated {task_count} tasks in state.json")

        # Backup old files
        print("MIGRATE: Backing up old state files...")
        old_files = [
            "tasks.md",
            ".workflow-state.json",
            ".tasks-state.json",
            ".stagnation_state",
            ".stagnation_state.consec",
            ".stagnation_state.continue_count",
            ".stagnation_state.drift_count",
            ".stagnation_total",
            "revision_history.md",
            "workflow_state.json",
        ]
        backup_partial = False
        for old_name in old_files:
            old_path = Path(feature_dir) / old_name
            if old_path.exists():
                import shutil
                shutil.copy2(str(old_path), str(old_path) + ".bak")
            else:
                backup_partial = True

        # Create migration marker
        marker_path = Path(feature_dir) / "MIGRATION_DONE"
        marker_path.write_text(f"migrated_at={now_utc()}\n")

        print("MIGRATE: Complete — state.json contains all consolidated data")
        if backup_partial:
            print("MIGRATE WARNING: Some old files not found (may have been cleaned up previously)")
        else:
            print("MIGRATE: Old files preserved as .bak — remove manually when confident")

        # Post-migration validation
        print("MIGRATE: Validating post-migration state.json...")
        if state_file.exists():
            try:
                with open(state_file) as f:
                    json.load(f)
                print(f"MIGRATE: Validation passed — state.json is valid JSON with {task_count} tasks")
            except json.JSONDecodeError:
                print("MIGRATE: VALIDATION FAILED — state.json is corrupted after migration")
                if os.path.exists(backup_file):
                    import shutil
                    shutil.copy2(backup_file, str(state_file))
                    print(f"MIGRATE: Restored from {backup_file}")
                else:
                    print("MIGRATE: ERROR — no backup available, state.json is corrupted")
                sys.exit(1)
    else:
        print("MIGRATE: No old format files found — state.json is already up to date")

    conn.close()


def _parse_tasks_md(tasks_md_path):
    """Parse tasks.md into a dict of task objects.

    This mirrors the Bash migrate_tasks_md() function.
    """
    tasks = {}
    in_task = False
    in_section = ""
    tid = ""
    title = ""
    status = "TODO"
    task_type = "backend-domain"
    depends = []
    creates = []
    modifies = []
    ac = []
    do_not = []

    def _save_task():
        nonlocal tid, title, status, task_type, depends, creates, modifies, ac, do_not
        if not tid:
            return
        tasks[tid] = {
            "status": status,
            "type": task_type,
            "title": title,
            "depends_on": depends,
            "scope": {"creates": creates, "modifies": modifies},
            "acceptance_criteria": ac,
            "do_not": do_not,
            "revision_count": 0,
            "last_changed": "",
            "files_modified": [],
            "blocking_reason": None,
            "check_results": {},
            "interfaces_produced": [],
            "interfaces_consumed": [],
        }

    with open(tasks_md_path) as f:
        for line in f:
            raw = line.rstrip("\n")

            # Task header
            m = re.match(r"^## (TASK-\d+): (.*)", raw)
            if m:
                _save_task()
                tid = m.group(1)
                title = m.group(2)
                status = "TODO"
                task_type = "backend-domain"
                depends = []
                creates = []
                modifies = []
                ac = []
                do_not = []
                in_task = True
                in_section = ""
                continue

            if not in_task:
                continue

            # Section headers
            m = re.match(r"^Status: (.*)", raw)
            if m:
                status = m.group(1).strip()
                in_section = ""
                continue
            m = re.match(r"^Type: (.*)", raw)
            if m:
                task_type = m.group(1).strip()
                in_section = ""
                continue
            m = re.match(r"^Depends on: (.*)", raw)
            if m:
                dep_raw = m.group(1).strip()
                if dep_raw.lower() == "none":
                    depends = []
                else:
                    depends = [d.strip() for d in dep_raw.split(",")]
                in_section = ""
                continue

            if re.match(r"^Scope:", raw):
                in_section = "scope"
                continue
            if re.match(r"^\s{2}Creates:", raw):
                in_section = "creates"
                continue
            if re.match(r"^\s{2}Modifies:", raw):
                in_section = "modifies"
                continue
            if re.match(r"^Acceptance criteria:", raw):
                in_section = "ac"
                continue
            if re.match(r"^Do NOT:", raw):
                in_section = "do_not"
                continue

            # Items under active section
            if in_section:
                m4 = re.match(r"^\s{4}- (.*)", raw)
                if m4 and in_section in ("creates", "modifies"):
                    item = m4.group(1).strip()
                    if item != "none":
                        if in_section == "creates":
                            creates.append(item)
                        else:
                            modifies.append(item)
                    continue

                m2 = re.match(r"^\s{2}- (.*)", raw)
                if m2 and in_section in ("ac", "do_not"):
                    item = m2.group(1).strip()
                    if in_section == "ac":
                        ac.append(item)
                    else:
                        do_not.append(item)
                    continue

                # Blank line or non-matching line resets section
                if not raw.strip():
                    pass  # keep section
                else:
                    in_section = ""

    _save_task()
    return tasks


# ── Self-test ──────────────────────────────────────────────────────

def cmd_test(args):
    """Run self-tests against a temporary feature directory."""
    import tempfile
    import shutil

    tmpdir = tempfile.mkdtemp(prefix="state_test_")
    feature_dir = os.path.join(tmpdir, "test_feature")
    passed = 0
    failed = 0

    def check(name, actual, expected):
        nonlocal passed, failed
        # Normalize: compare as strings for mixed bool/str
        a = str(actual).lower()
        e = str(expected).lower()
        if a == e or actual == expected:
            passed += 1
        else:
            failed += 1
            print(f"  FAIL {name}: expected {expected!r}, got {actual!r}")

    def cli(*cmd_args):
        """Run state.py with args in CLI order: command, feature_dir, [rest...]"""
        import subprocess
        full = ["state.py"] + list(cmd_args)
        result = subprocess.run(
            [sys.executable, _SCRIPT_PATH] + full[1:],
            capture_output=True, text=True,
        )
        if result.returncode != 0 and full[1] not in ("validate",):
            print(f"  CLI error for {' '.join(full)}: {result.stderr}", file=sys.stderr)
        return result.stdout

    try:
        # init
        cmd_init(type("Args", (), {"feature_dir": feature_dir})())
        assert os.path.exists(os.path.join(feature_dir, "state.json"))

        # read
        val = cli("read", feature_dir, "version")
        check("read version", val.strip(), "1")

        val = cli("read", feature_dir, "tasks")
        check("read tasks (empty)", val.strip(), "{}")

        # write
        cli("write", feature_dir, "tasks.TASK-1.status", "TODO")
        val = cli("read", feature_dir, "tasks.TASK-1.status")
        check("write/read string", val.strip(), "TODO")

        cli("write", feature_dir, "tasks.TASK-1.count", "42")
        val = cli("read", feature_dir, "tasks.TASK-1.count")
        check("write/read int", val.strip(), "42")

        cli("write", feature_dir, "tasks.TASK-1.flag", "true")
        val = cli("read", feature_dir, "tasks.TASK-1.flag")
        check("write/read bool", val.strip(), "True")

        # task-set
        cli("task-set", feature_dir, "TASK-1", "status", "DONE")
        cli("task-set", feature_dir, "TASK-1", "type", "backend-domain")
        val = cli("read", feature_dir, "tasks.TASK-1.status")
        check("task-set", val.strip(), "DONE")

        # task-incr
        cli("task-incr", feature_dir, "TASK-1", "revision_count")
        val = cli("read", feature_dir, "tasks.TASK-1.revision_count")
        check("task-incr", val.strip(), "1")

        cli("task-incr", feature_dir, "TASK-1", "revision_count")
        val = cli("read", feature_dir, "tasks.TASK-1.revision_count")
        check("task-incr x2", val.strip(), "2")

        # validate
        out = cli("validate", feature_dir)
        check("validate", out.strip(), "VALIDATION: PASS")

        # history-append
        entry = json.dumps({"phase": "test", "task": "TASK-1", "result": "PASS"})
        cli("history-append", feature_dir, entry)
        val = cli("read", feature_dir, "history")
        check("history-append", '"phase": "test"' in val, "true")

        # history-prune
        cli("history-prune", feature_dir, "10")
        val = cli("read", feature_dir, "history")
        check("history-prune", '"phase": "test"' in val, "true")

        # cadence-increment
        out = cli("cadence-increment", feature_dir, "traceability_counter")
        check("cadence-increment", "incremented to 1" in out, "true")

        # cadence-reset
        out = cli("cadence-reset", feature_dir, "traceability_counter")
        check("cadence-reset", "reset to 0" in out, "true")

        # context-increment
        out = cli("context-increment", feature_dir)
        check("context-increment", "incremented to 1" in out, "true")

        # context-reset
        out = cli("context-reset", feature_dir)
        check("context-reset", "reset to 0" in out, "true")

        # fix-cycles-increment
        out = cli("fix-cycles-increment", feature_dir)
        check("fix-cycles-increment", "incremented to 1" in out, "true")

        # fix-cycles-reset
        out = cli("fix-cycles-reset", feature_dir)
        check("fix-cycles-reset", "reset to 0" in out, "true")

        # spec-increment
        out = cli("spec-increment", feature_dir)
        check("spec-increment", "incremented to 2" in out, "true")

        # delete
        cli("write", feature_dir, "tasks.TASK-2.name", "test")
        cli("delete", feature_dir, "tasks.TASK-2.name")
        val = cli("read", feature_dir, "tasks.TASK-2.name")
        check("delete", val.strip(), "")

        # generate-tasks-md
        cli("task-set", feature_dir, "TASK-1", "title", "Test Task")
        cli("task-set", feature_dir, "TASK-1", "type", "backend-domain")
        md = cli("generate-tasks-md", feature_dir)
        check("generate-tasks-md has TASK-1", "TASK-1" in md, "true")
        check("generate-tasks-md has title", "Test Task" in md, "true")

        print(f"\nSelf-test: {passed} passed, {failed} failed")
        if failed:
            sys.exit(1)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# ── Main dispatch ──────────────────────────────────────────────────

def main():
    if "--test" in sys.argv:
        cmd_test(type("Args", (), {})())
        return

    if len(sys.argv) < 3:
        print(
            "Usage: state.py <command> <feature_dir> [args...]",
            file=sys.stderr,
        )
        print(
            "Commands: init|read|write|delete|validate|migrate|generate-tasks-md|"
            "history-append|history-prune|spec-increment|cadence-increment|"
            "cadence-reset|context-increment|context-reset|task-set|task-incr|"
            "fix-cycles-increment|fix-cycles-reset",
            file=sys.stderr,
        )
        sys.exit(1)

    mode = sys.argv[1]
    feature_dir = sys.argv[2]
    remaining = sys.argv[3:]

    # Parse --flags from remaining
    rollback = "--rollback" in remaining
    dry_run = "--dry-run" in remaining
    remaining = [a for a in remaining if not a.startswith("--")]

    # Simple namespace for command handlers
    class Args:
        pass

    args = Args()
    args.feature_dir = feature_dir
    args.rollback = rollback
    args.dry_run = dry_run

    # Dispatch based on mode, assign remaining positional args
    if mode == "init":
        pass
    elif mode == "read":
        args.key = remaining[0] if len(remaining) > 0 else None
    elif mode == "write":
        args.key = remaining[0] if len(remaining) > 0 else None
        args.value = remaining[1] if len(remaining) > 1 else None
    elif mode == "delete":
        args.key = remaining[0] if len(remaining) > 0 else None
    elif mode == "validate":
        pass
    elif mode == "migrate":
        pass
    elif mode == "generate-tasks-md":
        pass
    elif mode == "history-append":
        args.entry = remaining[0] if len(remaining) > 0 else None
    elif mode == "history-prune":
        args.keep = remaining[0] if len(remaining) > 0 else None
    elif mode == "spec-increment":
        pass
    elif mode == "cadence-increment":
        args.counter_key = remaining[0] if len(remaining) > 0 else None
    elif mode == "cadence-reset":
        args.counter_key = remaining[0] if len(remaining) > 0 else None
    elif mode == "context-increment":
        pass
    elif mode == "context-reset":
        pass
    elif mode == "task-set":
        args.task_id = remaining[0] if len(remaining) > 0 else None
        args.field = remaining[1] if len(remaining) > 1 else None
        args.value = remaining[2] if len(remaining) > 2 else None
    elif mode == "task-incr":
        args.task_id = remaining[0] if len(remaining) > 0 else None
        args.field = remaining[1] if len(remaining) > 1 else None
    elif mode == "fix-cycles-increment":
        pass
    elif mode == "fix-cycles-reset":
        pass
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        print(
            "Usage: state.py <init|read|write|delete|validate|migrate|generate-tasks-md|"
            "history-append|history-prune|spec-increment|cadence-increment|cadence-reset|"
            "context-increment|context-reset|task-set|task-incr|fix-cycles-increment|"
            "fix-cycles-reset> <feature_dir> [args...]",
            file=sys.stderr,
        )
        sys.exit(1)

    commands = {
        "init": cmd_init,
        "read": cmd_read,
        "write": cmd_write,
        "delete": cmd_delete,
        "validate": cmd_validate,
        "migrate": cmd_migrate,
        "generate-tasks-md": cmd_generate_tasks_md,
        "history-append": cmd_history_append,
        "history-prune": cmd_history_prune,
        "spec-increment": cmd_spec_increment,
        "cadence-increment": cmd_cadence_increment,
        "cadence-reset": cmd_cadence_reset,
        "context-increment": cmd_context_increment,
        "context-reset": cmd_context_reset,
        "task-set": cmd_task_set,
        "task-incr": cmd_task_incr,
        "fix-cycles-increment": cmd_fix_cycles_increment,
        "fix-cycles-reset": cmd_fix_cycles_reset,
    }

    commands[mode](args)


if __name__ == "__main__":
    main()
