#!/usr/bin/env python3
# preflight.py — Batch preflight checks for the implement loop.
#
# Replaces 7 separate shell script invocations with a single Python call:
#   workflow-resume.sh     → check_resume()
#   token-budget-check.sh  → check_token_budget()
#   check-tasks-safe.sh    → check_tasks()
#   increment-iteration.sh → increment_iteration()
#   check-spec-revisions.sh → check_spec_revisions()
#   check-stagnation.sh    → check_stagnation()
#
# CLI: python3 scripts/preflight.py <feature_dir>
# Output: JSON to stdout (parsed by YAML orchestrator).

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def now_utc():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def load_config(feature_dir=None):
    scripts_dir = Path(__file__).resolve().parent
    config_path = scripts_dir.parent / "ddd-clean-arch" / "workflow-config.json"
    if config_path.exists():
        with open(config_path) as f:
            return json.load(f)
    return {}


def _import_state():
    scripts_dir = Path(__file__).resolve().parent
    if str(scripts_dir) not in sys.path:
        sys.path.insert(0, str(scripts_dir))
    import state as _state_module
    return _state_module


def load_state(feature_dir):
    state_mod = _import_state()
    conn = state_mod.get_conn(feature_dir)
    state = state_mod.load_state(conn, feature_dir)
    conn.close()
    return state


def save_state(feature_dir, state):
    state_mod = _import_state()
    conn = state_mod.get_conn(feature_dir)
    state_mod.save_state(conn, feature_dir, state)
    conn.commit()
    conn.close()


# ── Check: workflow resume ────────────────────────────────────────

def check_resume(feature_dir):
    pause_file = Path(feature_dir) / "workflow_state.json"
    if not pause_file.exists():
        return {"RESUME_OK": False, "RESUME_TASK": "", "REASON": "no-pause-state"}

    try:
        pause_data = json.loads(pause_file.read_text())
    except (json.JSONDecodeError, ValueError):
        return {"RESUME_OK": False, "RESUME_TASK": "", "REASON": "empty-pause-step"}

    pause_step = pause_data.get("step", "")
    if not pause_step or pause_step == "null":
        return {"RESUME_OK": False, "RESUME_TASK": "", "REASON": "empty-pause-step"}

    state = load_state(feature_dir)
    tasks = state.get("tasks", {})
    in_progress_task = None
    for tid, tdata in tasks.items():
        if isinstance(tdata, dict) and tdata.get("status") == "IN_PROGRESS":
            in_progress_task = tid
            break

    if not in_progress_task:
        return {"RESUME_OK": False, "RESUME_TASK": "", "REASON": "no-in-progress-task"}

    # Reset pause state
    pause_file.unlink(missing_ok=True)

    return {
        "RESUME_OK": True,
        "RESUME_TASK": in_progress_task,
        "RESUME_STEP": pause_step,
    }


# ── Check: tasks ──────────────────────────────────────────────────

def check_tasks(state, feature_dir):
    tasks = state.get("tasks", {})
    total_tasks = len(tasks)
    done_count = sum(1 for t in tasks.values()
                     if isinstance(t, dict) and t.get("status") == "DONE")
    abandoned_count = sum(1 for t in tasks.values()
                          if isinstance(t, dict) and t.get("status") == "ABANDONED")
    in_progress_list = [tid for tid, t in tasks.items()
                        if isinstance(t, dict) and t.get("status") == "IN_PROGRESS"]
    in_progress = in_progress_list[0] if in_progress_list else ""
    in_progress_all = ",".join(in_progress_list)

    todo_list = [tid for tid, t in tasks.items()
                 if isinstance(t, dict) and t.get("status") in ("TODO", "IN_PROGRESS")]
    todo_task_id = todo_list[0] if todo_list else ""
    todo_task_type = ""
    if todo_task_id and todo_task_id in tasks:
        todo_task_type = tasks[todo_task_id].get("type", "") if isinstance(tasks[todo_task_id], dict) else ""

    has_todo = len(todo_list) > 0

    # Read complexity from state
    metadata = state.get("metadata", {})
    complexity = metadata.get("risk_profile", metadata.get("complexity", "medium"))

    # Read cadence from state
    cadence = state.get("cadence", {})
    retro_interval = cadence.get("retro_interval", 10)
    first_retro_threshold = cadence.get("first_retro_threshold", 5)
    retro_trigger = done_count >= first_retro_threshold and done_count % retro_interval == 0

    return {
        "has_todo": has_todo,
        "done_count": done_count,
        "todo_count": len(todo_list),
        "in_progress": in_progress,
        "in_progress_all": in_progress_all,
        "abandoned_count": abandoned_count,
        "total_tasks": total_tasks,
        "complexity": complexity,
        "retro_interval": retro_interval,
        "first_retro_threshold": first_retro_threshold,
        "retro_trigger": retro_trigger,
        "feature_dir": str(Path(feature_dir).resolve()),
        "todo_task_id": todo_task_id,
        "todo_task_type": todo_task_type,
        "state_source": "state_json",
        "TASKS_PARSE_ERROR": 0,
    }


# ── Check: token budget ──────────────────────────────────────────

def check_token_budget(state):
    tb = state.get("token_budget", {})
    risk = tb.get("risk", "OK")
    return {
        "BUDGET": risk,
        "risk": risk,
        "actual_input": tb.get("actual_input_tokens", 0),
        "actual_output": tb.get("actual_output_tokens", 0),
        "projected_total": tb.get("projected_total", 0),
        "estimated_cost": tb.get("estimated_cost", "0.00"),
        "projected_cost": tb.get("projected_cost", "0.00"),
        "sessions": tb.get("sessions_count", 0),
    }


# ── Check: spec revisions ────────────────────────────────────────

def check_spec_revisions(state, config):
    rev_config = config.get("revision_thresholds", {})
    max_spec = rev_config.get("spec", 3)

    revisions = state.get("revisions", {})
    spec_total = int(revisions.get("spec_total", 0))
    cascade = int(revisions.get("spec_cascade", 0))

    exhausted = spec_total >= max_spec
    cascade_exhausted = cascade >= max_spec

    return {
        "SPEC_REVISIONS": spec_total,
        "SPEC_REVISION_OK": not exhausted,
        "SPEC_REVISION_EXHAUSTED": exhausted,
        "CASCADE_EXHAUSTED": cascade_exhausted,
    }


# ── Check: stagnation ────────────────────────────────────────────

def compute_stagnation_threshold(total_tasks):
    total = int(total_tasks) if total_tasks else 10
    if total <= 10:
        return 3
    elif total <= 50:
        t = (total + 9) // 10
        return max(t, 4)
    else:
        t = (total + 19) // 20
        return max(t, 5)


STAGNATION_THRESHOLDS_BY_TYPE = {
    "backend-domain": 10,
    "backend-api": 7,
    "e2e": 8,
    "shared": 5,
    "backend-infra": 7,
    "frontend-data": 6,
    "frontend-feature": 7,
    "spec_revision": 5,
}


def check_stagnation(state, total_tasks, task_type):
    """Read stagnation state (read-only). Called by preflight before update."""
    stagnation = state.get("stagnation", {})
    last_done = int(stagnation.get("last_done_count", 0))
    consec_no_progress = int(stagnation.get("consecutive_no_progress", 0))
    consec_continues = int(stagnation.get("consecutive_continues", 0))

    threshold = compute_stagnation_threshold(total_tasks)
    by_type_threshold = STAGNATION_THRESHOLDS_BY_TYPE.get(task_type, 5)
    effective_threshold = max(threshold, by_type_threshold)

    return {
        "STAGNANT": False,
        "CONSECUTIVE_NO_PROGRESS": consec_no_progress,
        "CONSECUTIVE_CONTINUES": consec_continues,
        "REVISION_ONLY": False,
        "SPEC_REVISION_LOOP": False,
        "SPEC_REVISION_LOOP_TASKS": "",
        "DRIFT_VIOLATION_COUNT": int(stagnation.get("drift_violations", 0)),
        "_threshold": effective_threshold,
    }


def update_stagnation(state, total_tasks, task_type):
    """Update stagnation counters in state and return results."""
    stagnation = state.setdefault("stagnation", {})
    last_done = int(stagnation.get("last_done_count", 0))
    consec_no_progress = int(stagnation.get("consecutive_no_progress", 0))
    consec_continues = int(stagnation.get("consecutive_continues", 0))

    threshold = compute_stagnation_threshold(total_tasks)
    by_type_threshold = STAGNATION_THRESHOLDS_BY_TYPE.get(task_type, 5)
    effective_threshold = max(threshold, by_type_threshold)

    # Count current DONE tasks
    tasks = state.get("tasks", {})
    current_done_count = sum(1 for t in tasks.values()
                             if isinstance(t, dict) and t.get("status") == "DONE")

    stagnant = False
    revision_only = False

    if current_done_count == last_done and last_done > 0:
        consec_no_progress += 1
    else:
        if current_done_count != last_done:
            consec_no_progress = 0

    if consec_no_progress >= effective_threshold:
        stagnant = True
        # Check revision_only: was the last iteration a revision that didn't complete a task?
        if current_done_count == last_done:
            revision_only = True

    # Check spec revision loop (last 8 history entries)
    history = state.get("history", [])
    window = history[-8:] if len(history) >= 8 else history
    spec_rev_count = 0
    spec_rev_tasks = []
    for entry in window:
        if isinstance(entry, dict):
            phase = entry.get("phase", "")
            entry_type = entry.get("type", "")
            if "spec_revision" in str(phase) or "spec_revision" in str(entry_type):
                spec_rev_count += 1
                task_id = entry.get("task_id", entry.get("key", "unknown"))
                spec_rev_tasks.append(task_id)

    spec_revision_loop = spec_rev_count >= 2

    # Update state
    state["stagnation"]["consecutive_no_progress"] = consec_no_progress
    state["stagnation"]["consecutive_continues"] = consec_continues
    state["stagnation"]["last_done_count"] = current_done_count

    return {
        "STAGNANT": stagnant,
        "CONSECUTIVE_NO_PROGRESS": consec_no_progress,
        "CONSECUTIVE_CONTINUES": consec_continues,
        "REVISION_ONLY": revision_only,
        "SPEC_REVISION_LOOP": spec_revision_loop,
        "SPEC_REVISION_LOOP_TASKS": ",".join(spec_rev_tasks),
    }


# ── Check: increment iteration ───────────────────────────────────

def increment_iteration(state):
    impl = state.setdefault("_impl", {})
    loop_count = int(impl.get("loop_count", 0)) + 1
    state["_impl"]["loop_count"] = loop_count
    state["metadata"]["updated_at"] = now_utc()
    return {"count": loop_count}


# ── Orchestrator ──────────────────────────────────────────────────

def preflight(feature_dir):
    config = load_config(feature_dir)
    state = load_state(feature_dir)

    results = {}

    # 1. Workflow resume
    resume = check_resume(feature_dir)
    results.update(resume)

    # 2. Tasks check
    tasks = check_tasks(state, feature_dir)
    results.update(tasks)

    # 3. Token budget
    budget = check_token_budget(state)
    results.update(budget)

    # 4. Spec revisions
    spec_revs = check_spec_revisions(state, config)
    results.update(spec_revs)

    # 5. Stagnation (read + update)
    current_done_count = sum(1 for t in tasks.values()
                             if isinstance(t, dict) and t.get("status") == "DONE")
    updated_stag = update_stagnation(state, tasks["total_tasks"], tasks.get("todo_task_type", ""))
    updated_stag.pop("_threshold", None)
    results.update(updated_stag)

    # 6. Increment iteration
    inc = increment_iteration(state)
    results.update(inc)

    # Save state (writes to SQLite + state.json)
    save_state(feature_dir, state)

    # Output JSON
    print(json.dumps(results, indent=2))
    return 0


def main():
    if len(sys.argv) < 2:
        print("Usage: preflight.py <feature_dir>", file=sys.stderr)
        sys.exit(1)

    sys.exit(preflight(sys.argv[1]))


if __name__ == '__main__':
    main()
