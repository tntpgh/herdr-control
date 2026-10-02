#!/usr/bin/env python3
"""Real-registry e2e for tasks.py's command pipeline.

register_task() (lib/run-registry.sh), registry-bridge.sh's set-remote-id /
set-deadline / set-verified / cancel, and close-done-workers.sh all run for
REAL here, against a scratch HERDR_RUN_STATE_DIR -- proving tasks.py's SQL
assumptions match what lib/run-registry.sh's own v7 schema and migration
actually produce, which verify-tasks.py's hand-rolled fixture schema
(deliberately minimal, for speed) cannot catch. Uses the REAL
remote-mcp/task-allowlist.json, unmodified.

The only thing faked is spawn-task.sh's actual pane/tab/agent launch
(verify-tasks-e2e-fake-spawn.sh calls register_task() for real and writes a
real identity.json, then stops short of starting a real tab) -- a real
wrangler-dev + real publisher tick + real spawn-task.sh against a real repo
is SPEC.md Acceptance item 2, explicitly deferred to the conductor's own
live e2e (see .handoffs/PROOF.md).

    python3 remote-mcp/verify-tasks-e2e.py
"""
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp(prefix="herdr-tasks-e2e-"))

# Must be set before `import tasks`: its module-level constants read these
# once, at import time, exactly like the real publisher process does.
os.environ["HERDR_RUN_STATE_DIR"] = str(TMP / "runs")
os.environ["HERDR_WT_DIR"] = str(TMP / "worktrees")
os.environ["HERDR_CODE_DIR"] = str(TMP / "code")
os.environ["HERDR_MCP_TASKS"] = "1"
(TMP / "code/knowledge-base/.git").mkdir(parents=True)

sys.path.insert(0, str(HERE))
import tasks as tsk  # noqa: E402 (must follow the env vars above)

tsk.SPAWN_TASK = str(HERE / "verify-tasks-e2e-fake-spawn.sh")
# REGISTRY_BRIDGE and CLOSE_DONE are left at their real defaults
# (HERE/registry-bridge.sh, REPO/close-done-workers.sh) -- the whole point
# of this script versus verify-tasks.py's faked stand-ins for those two.

failures: list[str] = []


def check(label: str, cond: bool, detail: object = "") -> None:
    print(f"  {'ok  ' if cond else 'FAIL'}  {label}" + (f" -- {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(label)


def registry_row(task_id: str) -> dict | None:
    con = sqlite3.connect(tsk.REGISTRY)
    con.row_factory = sqlite3.Row
    row = con.execute("SELECT * FROM tasks WHERE task_id=?", (task_id,)).fetchone()
    con.close()
    return dict(row) if row else None


print("== start_task: real register_task() + real registry-bridge.sh set-remote-id/set-deadline ==")
out = tsk.process_command({
    "command_id": "cmd_1", "op": "start", "remote_task_id": "rtask_e2e_1",
    "payload": {"repo": "knowledge-base", "mode": "research",
                "objective": "find the most recent tl;dv meeting in the KB and summarise it"},
})
check("start accepted", out.get("outcome") == "accepted", json.dumps(out))
task_id, run_id = out.get("local_task_id", ""), out.get("local_run_id", "")
row = registry_row(task_id) if task_id else None
check("registry row exists for real (schema v7, register_task())", row is not None)
if row:
    check("remote_task_id round-tripped through real registry-bridge.sh set-remote-id",
          row.get("remote_task_id") == "rtask_e2e_1", row.get("remote_task_id"))
    check("deadline_at set by real registry-bridge.sh set-deadline", bool(row.get("deadline_at")))
    check("state is 'starting' immediately after register_task()", row.get("state") == "starting")

print("== sweep(): real close-done-workers.sh auto-closes a finished research task ==")
wt = Path(row["worktree"]) if row and row.get("worktree") else None
check("registry row carries a real worktree directory", bool(wt) and wt.is_dir(), row)
if wt:
    (wt / ".handoffs/ANSWER.md").write_text(
        "Found it: https://kb.teamthurber.com/entity/e2e-123 -- summary here.\n")
    (wt / ".handoffs/events.jsonl").write_text(
        json.dumps({"event": "e2e_done", "status": "completed", "reason": "no-follow-on"}) + "\n")
    t = {"task_id": task_id, "run_id": run_id, "state": "running", "worktree": str(wt)}
    actions = tsk.sweep({task_id: t}, datetime.now(timezone.utc))
    check("sweep() produced exactly one action", len(actions) == 1, str(actions))
    if actions:
        check("action is auto_close", actions[0]["action"] == "auto_close", str(actions[0]))
        check("real close-done-workers.sh --apply succeeded", actions[0]["ok"], actions[0]["detail"])
    row = registry_row(task_id)
    check("registry state is 'completed' after the real close-done-workers.sh ran",
          bool(row) and row.get("state") == "completed", row)

print("== a second task: real registry-bridge.sh cancel ==")
out2 = tsk.process_command({
    "command_id": "cmd_2", "op": "start", "remote_task_id": "rtask_e2e_2",
    "payload": {"repo": "knowledge-base", "mode": "research", "objective": "y"},
})
check("second start accepted", out2.get("outcome") == "accepted", json.dumps(out2))
task_id2 = out2.get("local_task_id", "")
cout = tsk.process_command({
    "command_id": "cmd_3", "op": "cancel", "remote_task_id": "rtask_e2e_2",
    "payload": {"local_task_id": task_id2, "reason": "canceled"},
})
check("cancel accepted", cout.get("outcome") == "accepted", json.dumps(cout))
row2 = registry_row(task_id2)
check("registry state is 'cancelled' after the real registry-bridge.sh cancel ran",
      bool(row2) and row2.get("state") == "cancelled", row2)

shutil.rmtree(TMP, ignore_errors=True)
print()
if failures:
    print(f"FAILED: {len(failures)} check(s): {failures}")
    sys.exit(1)
print("PASS: all real-registry e2e checks green")
