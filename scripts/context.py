#!/usr/bin/env python3
# context.py — Consolidated context lifecycle management.
#
# Replaces 7 bash scripts with a single Python module:
#   context-health.sh   → health
#   context-compact.sh  → compact
#   context-rotate.sh   → rotate
#   track-context-budget.sh → budget
#   track-token-budget.sh   → log
#   prompt-context.sh       → prompt
#
# CLI: python3 scripts/context.py <subcommand> <feature_dir> [args...]

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# ── Infrastructure ────────────────────────────────────────────────

def now_utc():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def resolve_config_path(feature_dir):
    scripts_dir = Path(__file__).resolve().parent
    config_path = scripts_dir.parent / "ddd-clean-arch" / "workflow-config.json"
    if config_path.exists():
        return config_path
    return None


def load_config(feature_dir=None):
    config_path = resolve_config_path(feature_dir)
    if config_path and config_path.exists():
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


def ensure_context_db(feature_dir):
    artifacts_dir = Path(feature_dir) / ".artifacts"
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    db_path = artifacts_dir / "context.db"
    conn = sqlite3.connect(str(db_path), timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS token_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            feature_dir TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS checkpoint_metadata (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            feature_dir TEXT NOT NULL,
            checkpoint_name TEXT NOT NULL,
            task_id TEXT,
            status TEXT NOT NULL,
            files_count INTEGER DEFAULT 0,
            created_at TEXT NOT NULL,
            UNIQUE(feature_dir, checkpoint_name)
        )
    """)
    conn.commit()
    return conn


def _migrate_jsonl_to_db(feature_dir):
    jsonl_path = Path(feature_dir) / ".artifacts" / "token-log.jsonl"
    if not jsonl_path.exists():
        return 0
    conn = ensure_context_db(feature_dir)
    cursor = conn.cursor()
    count = 0
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                cursor.execute(
                    "INSERT INTO token_log (feature_dir, timestamp, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens) VALUES (?, ?, ?, ?, ?, ?)",
                    (str(Path(feature_dir).resolve()),
                     entry.get("timestamp", now_utc()),
                     int(entry.get("input_tokens", 0)),
                     int(entry.get("output_tokens", 0)),
                     int(entry.get("cache_creation", 0)),
                     int(entry.get("cache_read", 0)))
                )
                count += 1
            except (json.JSONDecodeError, ValueError):
                pass
    conn.commit()
    if count > 0:
        jsonl_path.rename(jsonl_path.with_suffix(".jsonl.bak"))
    return count


def _load_error_memory(feature_dir):
    error_mem_dir = Path(feature_dir) / ".artifacts" / "error-memory"
    entries = []
    if not error_mem_dir.is_dir():
        return entries
    for json_file in sorted(error_mem_dir.glob("*.json")):
        try:
            data = json.loads(json_file.read_text())
        except json.JSONDecodeError:
            continue
        if isinstance(data, list):
            for entry in data:
                if isinstance(entry, dict) and "type" in entry:
                    entries.append(entry)
        elif isinstance(data, dict):
            for entry in data.get("corrections", []):
                entry_copy = dict(entry)
                entry_copy["type"] = "correction"
                entries.append(entry_copy)
            for entry in data.get("abandoned_tasks", []):
                entry_copy = dict(entry)
                entry_copy["type"] = "abandoned"
                entries.append(entry_copy)
            for entry in data.get("drift_patterns", []):
                entry_copy = dict(entry)
                entry_copy["type"] = "pattern"
                entries.append(entry_copy)
    return entries


def estimate_tokens(file_or_dir):
    p = Path(file_or_dir)
    if p.is_file():
        return p.stat().st_size // 4
    if p.is_dir():
        total = 0
        for f in p.rglob("*"):
            if f.is_file():
                total += f.stat().st_size // 4
        return total
    return 0


# ── Subcommand: health ────────────────────────────────────────────

def cmd_health(args):
    feature_dir = str(Path(args.feature_dir).resolve())
    config = load_config(feature_dir)
    ctx_config = config.get("context", {})

    state = load_state(feature_dir)
    session_age = int(state.get("context", {}).get("session_age", 0))
    reset_threshold = int(state.get("context", {}).get("reset_threshold", 0))
    if reset_threshold <= 0:
        reset_threshold = ctx_config.get("reset_threshold", 15)

    artifacts_dir = Path(feature_dir) / ".artifacts"
    artifact_size_mb = 0
    prompt_context_count = 0
    correction_snapshot_count = 0

    if artifacts_dir.is_dir():
        try:
            du_out = shutil.disk_usage(str(artifacts_dir))
            artifact_size_mb = du_out.used // (1024 * 1024)
        except OSError:
            pass
        prompt_dir = artifacts_dir / "prompts"
        if prompt_dir.is_dir():
            prompt_context_count = len(list(prompt_dir.glob("**/context.md")))
        correction_dir = artifacts_dir / "correction-snapshots"
        if correction_dir.is_dir():
            correction_snapshot_count = len([d for d in correction_dir.iterdir() if d.is_dir()])

    health = "HEALTHY"
    recommendation = "Context health is good. No action needed."

    if reset_threshold > 0 and session_age >= reset_threshold:
        ratio = session_age * 100 // reset_threshold
        if ratio >= 200:
            health = "CRITICAL"
            recommendation = f"Context age ({session_age} tasks) is 2x the reset threshold ({reset_threshold}). Consider starting a fresh session. Key decisions and spec details may be forgotten."
        elif session_age >= reset_threshold * 3 // 4:
            health = "DEGRADED"
            recommendation = f"Context age ({session_age} tasks) approaching reset threshold ({reset_threshold}). Re-read plan.md sections 1-3 and spec.md before continuing. Summarize key decisions from your context window."
        else:
            health = "DEGRADED"
            recommendation = f"Context age ({session_age} tasks) exceeds threshold ({reset_threshold}). Re-read plan.md and spec.md to refresh context."

    artifact_size_warn = ctx_config.get("artifact_size_mb", 500)
    if artifact_size_mb >= artifact_size_warn:
        if health == "HEALTHY":
            health = "DEGRADED"
        recommendation += f" Artifacts directory is {artifact_size_mb}MB. Consider cleanup."

    correction_warn = ctx_config.get("correction_snapshot_warn", 50)
    if correction_snapshot_count >= correction_warn:
        if health == "HEALTHY":
            health = "DEGRADED"
        recommendation += f" {correction_snapshot_count} correction snapshots detected. High correction rate may indicate spec ambiguity."

    session_rotate_required = "true" if health == "CRITICAL" else "false"

    print(f"CONTEXT_HEALTH={health}")
    print(f"SESSION_AGE={session_age}")
    print(f"RESET_THRESHOLD={reset_threshold}")
    print(f"ARTIFACT_SIZE_MB={artifact_size_mb}")
    print(f"PROMPT_CONTEXT_COUNT={prompt_context_count}")
    print(f"CORRECTION_SNAPSHOT_COUNT={correction_snapshot_count}")
    print(f"SESSION_ROTATE_REQUIRED={session_rotate_required}")
    print(f"RECOMMENDATION={recommendation}")
    return 0


# ── Subcommand: compact ──────────────────────────────────────────

def cmd_compact(args):
    feature_dir = str(Path(args.feature_dir).resolve())
    config = load_config(feature_dir)
    ctx_config = config.get("context", {})

    keep_checkpoints = getattr(args, 'keep_checkpoints', None) or ctx_config.get("keep_checkpoints", 5)
    keep_error_memory = getattr(args, 'keep_error_memory', None) or ctx_config.get("keep_error_memory", 10)
    keep_patterns = ctx_config.get("keep_patterns", 5)
    keep_decisions = ctx_config.get("keep_decisions", 5)
    keep_corrections = ctx_config.get("keep_decisions", 10)  # reuse keep_decisions default

    artifacts_dir = Path(feature_dir) / ".artifacts"
    artifacts_dir.mkdir(parents=True, exist_ok=True)

    # Load error memory entries
    entries = _load_error_memory(feature_dir)
    pattern_count = sum(1 for e in entries if e.get("type") == "pattern")
    correction_count = sum(1 for e in entries if e.get("type") == "correction")
    decision_count = sum(1 for e in entries if e.get("type") == "decision")

    # Prune checkpoints
    checkpoint_dir = artifacts_dir / "checkpoints"
    pruned_checkpoints = 0
    if checkpoint_dir.is_dir():
        cp_dirs = sorted([d.name for d in checkpoint_dir.iterdir() if d.is_dir()])
        if len(cp_dirs) > keep_checkpoints:
            to_remove = cp_dirs[:len(cp_dirs) - keep_checkpoints]
            for d in to_remove:
                shutil.rmtree(checkpoint_dir / d, ignore_errors=True)
                pruned_checkpoints += 1

    # Prune error memory
    error_mem_dir = artifacts_dir / "error-memory"
    pruned_memory = 0
    if error_mem_dir.is_dir():
        em_files = sorted(f.name for f in error_mem_dir.iterdir() if f.is_file())
        if len(em_files) > keep_error_memory:
            to_remove = em_files[:len(em_files) - keep_error_memory]
            for f in to_remove:
                (error_mem_dir / f).unlink(missing_ok=True)
                pruned_memory += 1

    # Write context summary
    summary = {
        "updated_at": now_utc(),
        "patterns_count": pattern_count,
        "corrections_count": correction_count,
        "decisions_count": decision_count,
        "pruned_checkpoints": pruned_checkpoints,
        "pruned_error_memory": pruned_memory
    }
    summary_file = artifacts_dir / "context-summary.json"
    with open(summary_file, "w") as f:
        json.dump(summary, f, indent=2)

    # Update state.json
    state = load_state(feature_dir)
    state["context_summary"] = summary
    state["metadata"]["updated_at"] = now_utc()
    save_state(feature_dir, state)

    print(f"=== CONTEXT COMPACTION ===")
    print(f"  Patterns:     {pattern_count}")
    print(f"  Corrections:  {correction_count}")
    print(f"  Decisions:    {decision_count}")
    print(f"  Checkpoints pruned: {pruned_checkpoints}")
    print(f"  Error memory pruned: {pruned_memory}")
    print(f"  Summary:      {summary_file}")

    # Run post-compaction verification
    verify_script = Path(__file__).parent / "post-compaction-verify.sh"
    if verify_script.exists():
        subprocess.run(["bash", str(verify_script), feature_dir],
                       capture_output=True, text=True)

    return 0


# ── Subcommand: rotate ───────────────────────────────────────────

def cmd_rotate(args):
    feature_dir = str(Path(args.feature_dir).resolve())
    force = getattr(args, 'force', False)
    state = load_state(feature_dir)

    tasks = state.get("tasks", {})
    done_count = sum(1 for t in tasks.values() if isinstance(t, dict) and t.get("status") == "DONE")

    rotation_threshold = int(state.get("context", {}).get("rotation_threshold", 10))
    gen_count = int(state.get("context", {}).get("generation_count", 0))

    if not force and done_count < rotation_threshold:
        print(f"CONTEXT_ROTATE: skipped (done={done_count} < threshold={rotation_threshold})")
        return 0

    cycle = done_count // rotation_threshold
    if not force and gen_count >= cycle:
        print(f"CONTEXT_ROTATE: skipped (already rotated for cycle {cycle})")
        return 0

    artifacts_dir = Path(feature_dir) / ".artifacts"
    artifacts_dir.mkdir(parents=True, exist_ok=True)

    # Build snapshot
    by_type = {}
    for tid, tdata in tasks.items():
        if isinstance(tdata, dict):
            ttype = tdata.get("type", "unknown")
            if ttype not in by_type:
                by_type[ttype] = {"count": 0, "recent": None}
            by_type[ttype]["count"] += 1
            if by_type[ttype]["recent"] is None:
                by_type[ttype]["recent"] = {"key": tid, "title": tdata.get("title", "")}

    snapshot = {
        "generation": gen_count + 1,
        "rotated_at": now_utc(),
        "done_count": done_count,
        "by_type": list(by_type.values()),
        "history_summary": {
            "total_entries": len(state.get("history", [])),
            "last_phase": (state.get("history") or [{}])[-1].get("phase", "none"),
            "last_iteration": (state.get("history") or [{}])[-1].get("iteration", 0)
        }
    }
    snapshot_file = artifacts_dir / "context-snapshot.json"
    with open(snapshot_file, "w") as f:
        json.dump(snapshot, f, indent=2)

    # Update state
    new_gen = gen_count + 1
    state["context"]["generation_count"] = new_gen
    state["context"]["last_snapshot"] = str(snapshot_file)
    state["history"] = (state.get("history", [])[-10:] if state.get("history") else [])
    state["metadata"]["updated_at"] = now_utc()
    save_state(feature_dir, state)

    # Prune bundles (keep last 5)
    bundle_dir = artifacts_dir / "bundles"
    if bundle_dir.is_dir():
        bundles = sorted(bundle_dir.glob("implement-*.md"), reverse=True)
        for b in bundles[5:]:
            b.unlink(missing_ok=True)
        # Prune plan context bundles (keep last 3)
        plan_bundles = sorted(bundle_dir.glob("context-plan-*.md"), reverse=True)
        for b in plan_bundles[3:]:
            b.unlink(missing_ok=True)

    print(f"CONTEXT_ROTATE: complete (generation={new_gen})")

    if force:
        print("CONTEXT_ROTATE: forced rotation...")
        # Forced snapshot
        forced_snap = artifacts_dir / f"context-snapshot-forced-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
        state_file = Path(feature_dir) / "state.json"
        if state_file.exists():
            shutil.copy2(str(state_file), str(forced_snap) + ".state.json")
        for fname in ["tasks.md", "plan.md", "spec.md"]:
            fpath = Path(feature_dir) / fname
            if fpath.exists():
                shutil.copy2(str(fpath), str(forced_snap) + "." + fname)
        print(f"CONTEXT_ROTATE: snapshot saved to {forced_snap}.*")

        # Reset session_age
        state = load_state(feature_dir)
        state["context"]["session_age"] = 0
        state["context"]["last_rotation"] = now_utc()
        state["metadata"]["updated_at"] = now_utc()
        save_state(feature_dir, state)
        print("CONTEXT_ROTATE: session_age reset to 0")

        # Prune correction snapshots (keep last 2)
        correction_snap_dir = artifacts_dir / "correction-snapshots"
        if correction_snap_dir.is_dir():
            snap_dirs = sorted([d for d in correction_snap_dir.iterdir() if d.is_dir()],
                             key=lambda d: d.stat().st_mtime, reverse=True)
            for d in snap_dirs[2:]:
                shutil.rmtree(d, ignore_errors=True)
            if len(snap_dirs) > 2:
                print(f"CONTEXT_ROTATE: cleaned up {len(snap_dirs) - 2} old correction snapshots")

        # Prune prompt contexts (keep last 5)
        prompt_dir = artifacts_dir / "prompts"
        if prompt_dir.is_dir():
            ctx_files = sorted(prompt_dir.rglob("context.md"), reverse=True)
            for f in ctx_files[5:]:
                f.unlink(missing_ok=True)
            if len(ctx_files) > 5:
                print(f"CONTEXT_ROTATE: cleaned up {len(ctx_files) - 5} old prompt contexts")

        print("ROTATION=COMPLETE")
        print(f"SNAPSHOT_PATH={forced_snap}")

    return 0


# ── Subcommand: budget ───────────────────────────────────────────

def cmd_budget(args):
    feature_dir = str(Path(args.feature_dir).resolve())
    config = load_config(feature_dir)
    ctx_config = config.get("context", {})

    limit_tokens = getattr(args, 'limit', None) or ctx_config.get("default_limit_tokens", 128000)
    json_output = getattr(args, 'json', False)

    artifacts_dir = Path(feature_dir) / ".artifacts"

    # Measure token usage
    unified_ctx = artifacts_dir / "unified-context.json"
    plan_file = Path(feature_dir) / "plan.md"
    tasks_file = Path(feature_dir) / "tasks.md"
    claude_md = Path(feature_dir) / "CLAUDE.md"

    unified_tokens = estimate_tokens(unified_ctx) if unified_ctx.exists() else 0
    plan_tokens = estimate_tokens(plan_file) if plan_file.exists() else 0
    tasks_tokens = estimate_tokens(tasks_file) if tasks_file.exists() else 0
    claude_tokens = estimate_tokens(claude_md) if claude_md.exists() else 0
    checkpoint_tokens = estimate_tokens(artifacts_dir / "checkpoints")
    error_memory_tokens = estimate_tokens(artifacts_dir / "error-memory")

    current_total = unified_tokens + plan_tokens + tasks_tokens + claude_tokens + checkpoint_tokens + error_memory_tokens

    # Read cumulative
    budget_file = artifacts_dir / "context-budget.json"
    prev_total = 0
    session_count = 1
    if budget_file.exists():
        try:
            prev_data = json.loads(budget_file.read_text())
            prev_total = int(prev_data.get("cumulative", {}).get("total_tokens", 0))
            session_count = int(prev_data.get("session_count", 0)) + 1
        except (json.JSONDecodeError, ValueError):
            pass

    cumulative = prev_total + current_total

    if limit_tokens > 0:
        current_pct = current_total * 100 // limit_tokens
        cumulative_pct = cumulative * 100 // limit_tokens
    else:
        current_pct = 0
        cumulative_pct = 0

    risk = "OK"
    if current_pct >= 90:
        risk = "CRITICAL"
    elif current_pct >= 75:
        risk = "WARNING"
    elif current_pct >= 50:
        risk = "MODERATE"

    budget = {
        "session_count": session_count,
        "updated_at": now_utc(),
        "current_context": {
            "total_tokens": current_total,
            "budget_limit": limit_tokens,
            "budget_pct": current_pct,
            "risk": risk,
            "files": {
                "unified-context.json": unified_tokens,
                "plan.md": plan_tokens,
                "tasks.md": tasks_tokens,
                "CLAUDE.md": claude_tokens,
                "checkpoints": checkpoint_tokens,
                "error-memory": error_memory_tokens
            }
        },
        "cumulative": {
            "total_tokens": cumulative,
            "sessions": session_count
        }
    }

    with open(budget_file, "w") as f:
        json.dump(budget, f, indent=2)

    if json_output:
        with open(budget_file) as f:
            print(f.read())
    else:
        print(f"=== CONTEXT BUDGET ===")
        print(f"Current context: {current_total} tokens / {limit_tokens} ({current_pct}%) [{risk}]")
        print(f"Cumulative session: {cumulative} tokens across {session_count} task(s)")
        print()
        print("Breakdown:")
        if unified_tokens:
            print(f"  unified-context.json: {unified_tokens} tokens")
        if plan_tokens:
            print(f"  plan.md: {plan_tokens} tokens")
        if tasks_tokens:
            print(f"  tasks.md: {tasks_tokens} tokens")
        if claude_tokens:
            print(f"  CLAUDE.md: {claude_tokens} tokens")
        if checkpoint_tokens:
            print(f"  checkpoints: {checkpoint_tokens} tokens")
        if error_memory_tokens:
            print(f"  error-memory: {error_memory_tokens} tokens")
        if risk in ("CRITICAL", "WARNING"):
            print()
            print(f"WARNING: Context budget {risk.lower()}. Consider:")
            print("  - Using context-limited.sh to cap context output")
            print("  - Removing stale checkpoints")
            print("  - Narrowing scope to reduce plan.md size")

    return 0


# ── Subcommand: log ──────────────────────────────────────────────

def cmd_log(args):
    feature_dir = str(Path(args.feature_dir).resolve())
    config = load_config(feature_dir)
    token_config = config.get("token_budget", {})

    input_tokens = getattr(args, 'input', 0) or 0
    output_tokens = getattr(args, 'output', 0) or 0
    cache_creation = getattr(args, 'cache_creation', 0) or 0
    cache_read = getattr(args, 'cache_read', 0) or 0

    conn = ensure_context_db(feature_dir)

    # Migrate existing JSONL
    migrated = _migrate_jsonl_to_db(feature_dir)
    if migrated > 0:
        print(f"TOKEN LOG: Migrated {migrated} entries from token-log.jsonl to context.db", file=sys.stderr)

    # Append new entry
    if input_tokens > 0 or output_tokens > 0:
        conn.execute(
            "INSERT INTO token_log (feature_dir, timestamp, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens) VALUES (?, ?, ?, ?, ?, ?)",
            (feature_dir, now_utc(), int(input_tokens), int(output_tokens),
             int(cache_creation), int(cache_read))
        )
        conn.commit()

    # Query all token data
    cursor = conn.execute(
        "SELECT SUM(input_tokens), SUM(output_tokens), SUM(cache_creation_tokens), SUM(cache_read_tokens), COUNT(*) FROM token_log WHERE feature_dir = ?",
        (feature_dir,)
    )
    row = cursor.fetchone()
    total_input = int(row[0] or 0)
    total_output = int(row[1] or 0)
    total_cc = int(row[2] or 0)
    total_cr = int(row[3] or 0)
    session_count = int(row[4] or 0)
    total_all = total_input + total_output + total_cc + total_cr

    # Read remaining tasks from state
    state = load_state(feature_dir)
    tasks = state.get("tasks", {})
    total_tasks = len(tasks)
    remaining_tasks = sum(1 for t in tasks.values()
                         if isinstance(t, dict) and t.get("status") in ("TODO", "IN_PROGRESS"))
    completed_tasks = total_tasks - remaining_tasks

    if completed_tasks > 0:
        avg_per_task = total_all // completed_tasks
    elif session_count > 0:
        avg_per_task = total_all // session_count
    else:
        avg_per_task = 0

    projected_remaining = avg_per_task * remaining_tasks if avg_per_task > 0 and remaining_tasks > 0 else 0
    projected_total = total_all + projected_remaining

    # Cost estimation
    cost_per_m_input = token_config.get("cost_per_m_input", 5)
    cost_per_m_output = token_config.get("cost_per_m_output", 30)

    input_cost = total_input * cost_per_m_input / 1_000_000
    output_cost = total_output * cost_per_m_output / 1_000_000
    total_cost = input_cost + output_cost
    projected_cost = total_cost + (projected_remaining * cost_per_m_output / 1_000_000)

    # Risk level
    critical_dollar = token_config.get("critical_dollar", 80)
    warning_dollar = token_config.get("warning_dollar", 50)
    dollar_usage = (total_input + total_output * 5) * 30 / 1_000_000

    risk = "OK"
    if dollar_usage >= critical_dollar:
        risk = "CRITICAL"
    elif dollar_usage >= warning_dollar:
        risk = "WARNING"

    # Update state.json
    state["token_budget"] = {
        "actual_input_tokens": total_input,
        "actual_output_tokens": total_output,
        "cache_creation_tokens": total_cc,
        "cache_read_tokens": total_cr,
        "sessions_count": session_count,
        "projected_total": projected_total,
        "avg_tokens_per_task": avg_per_task,
        "risk": risk,
        "estimated_cost": f"{total_cost:.2f}",
        "projected_cost": f"{projected_cost:.2f}"
    }
    state["metadata"]["updated_at"] = now_utc()
    save_state(feature_dir, state)
    conn.close()

    print(f"=== TOKEN BUDGET (Actual) ===")
    print(f"  Sessions:         {session_count}")
    print(f"  Input tokens:     {total_input}")
    print(f"  Output tokens:    {total_output}")
    print(f"  Cache creation:   {total_cc}")
    print(f"  Cache read:       {total_cr}")
    print(f"  Total used:       {total_all}")
    print(f"  Avg per task:     {avg_per_task}")
    print(f"  Remaining tasks:  {remaining_tasks}")
    print(f"  Projected total:  {projected_total}")
    print(f"  Estimated cost:   {total_cost:.2f}")
    print(f"  Projected cost:   {projected_cost:.2f}")
    print(f"  Risk:             {risk}")

    if risk in ("CRITICAL", "WARNING"):
        print()
        print(f"WARNING: Token budget {risk.lower()}. Consider:")
        print("  - Using /speckit.context to compact context")
        print("  - Splitting remaining tasks into smaller pieces")
        print("  - Resetting session context")

    return 0


# ── Subcommand: prompt ───────────────────────────────────────────

def cmd_prompt(args):
    feature_dir = str(Path(args.feature_dir).resolve())
    max_lines = getattr(args, 'max_lines', 500) or 500

    tasks_file = Path(feature_dir) / "tasks.md"
    if not tasks_file.exists():
        print("ERROR: tasks.md not found", file=sys.stderr)
        return 1

    content = tasks_file.read_text()

    # Find first task heading
    match = re.search(r'##\s+TASK-\[?\d*\]?\s*\n', content)
    if not match:
        print("ERROR: No TASK- found in tasks.md", file=sys.stderr)
        return 1

    task_heading = match.group(0).strip()
    task_id_match = re.search(r'TASK-(\d+)', task_heading)
    task_id = f"TASK-{task_id_match.group(1)}" if task_id_match else task_heading

    # Extract task type
    task_block = content[match.start():]
    type_match = re.search(r'Type:\s*(\S+)', task_block)
    task_type = type_match.group(1) if type_match else "unknown"

    # Read spec version from state
    spec_version = 1
    state_file = Path(feature_dir) / "state.json"
    if state_file.exists():
        try:
            state = json.loads(state_file.read_text())
            spec_version = int(state.get("spec", {}).get("version", 1))
        except (json.JSONDecodeError, ValueError):
            pass

    print(f"SPEC_VERSION: {spec_version}")

    # Generate context via bundle-assembler
    scripts_dir = Path(__file__).resolve().parent
    bundle_assembler = scripts_dir / "bundle-assembler.sh"
    artifacts_dir = Path(feature_dir) / ".artifacts" / "bundles"
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    output_file = artifacts_dir / f"implement-{task_id}.md"

    if bundle_assembler.exists():
        result = subprocess.run(
            ["bash", str(bundle_assembler), "implement", task_id, feature_dir,
             "--output", str(output_file)],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0 and not output_file.exists():
            print(f"WARNING: bundle-assembler failed: {result.stderr[:200]}", file=sys.stderr)

    # Read and truncate output
    if output_file.exists():
        output = output_file.read_text()
        lines = output.split('\n')
        if len(lines) > max_lines:
            print('\n'.join(lines[:max_lines]))
            print(f"\nCONTEXT TRUNCATED: {len(lines)} lines reduced to {max_lines}. {len(lines) - max_lines} lines omitted.", file=sys.stderr)
            print("Consider increasing --max-lines or narrowing scope.", file=sys.stderr)
        else:
            print(output)
    else:
        print(f"WARNING: No context bundle generated for {task_id}", file=sys.stderr)

    return 0


# ── Main ──────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='Context lifecycle management')
    subparsers = parser.add_subparsers(dest='subcommand')

    # health
    p_health = subparsers.add_parser('health', help='Check context health')
    p_health.add_argument('feature_dir')

    # compact
    p_compact = subparsers.add_parser('compact', help='Compact context artifacts')
    p_compact.add_argument('feature_dir')
    p_compact.add_argument('--keep-checkpoints', type=int, default=None)
    p_compact.add_argument('--keep-error-memory', type=int, default=None)

    # rotate
    p_rotate = subparsers.add_parser('rotate', help='Rotate context at threshold')
    p_rotate.add_argument('feature_dir')
    p_rotate.add_argument('--force', action='store_true')

    # budget
    p_budget = subparsers.add_parser('budget', help='Estimate context token budget')
    p_budget.add_argument('feature_dir')
    p_budget.add_argument('--json', action='store_true')
    p_budget.add_argument('--limit', type=int, default=None)

    # log
    p_log = subparsers.add_parser('log', help='Log token usage')
    p_log.add_argument('feature_dir')
    p_log.add_argument('--input', type=int, default=0)
    p_log.add_argument('--output', type=int, default=0)
    p_log.add_argument('--cache-creation', type=int, default=0)
    p_log.add_argument('--cache-read', type=int, default=0)

    # prompt
    p_prompt = subparsers.add_parser('prompt', help='Generate prompt context')
    p_prompt.add_argument('feature_dir')
    p_prompt.add_argument('--max-lines', type=int, default=500)

    args = parser.parse_args()

    if not args.subcommand:
        parser.print_help(sys.stderr)
        sys.exit(1)

    dispatch = {
        'health': cmd_health,
        'compact': cmd_compact,
        'rotate': cmd_rotate,
        'budget': cmd_budget,
        'log': cmd_log,
        'prompt': cmd_prompt,
    }

    handler = dispatch.get(args.subcommand)
    if not handler:
        print(f"ERROR: Unknown subcommand: {args.subcommand}", file=sys.stderr)
        sys.exit(1)

    sys.exit(handler(args))


if __name__ == '__main__':
    main()
