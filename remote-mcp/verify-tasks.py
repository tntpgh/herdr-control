#!/usr/bin/env python3
"""Behaviour checks for tasks.py. No real spawn-task.sh/close-done-workers.sh/
registry-bridge.sh ever runs: each is replaced by a tiny fake script that
records its argv and returns canned output, so this never touches a real
worktree, herdr pane, or the live run registry. Run with HERDR_RUN_STATE_DIR
pointed at a scratch dir, same as verify-run-registry.sh, even though this
script's own sqlite fixture never shares a path with the real one.

    python3 verify-tasks.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp(prefix="herdr-mcp-verify-tasks-"))

# ── fixture: allowlist, registry, fake scripts ──────────────────────────────────
ALLOWLIST = TMP / "task-allowlist.json"
ALLOWLIST.write_text(json.dumps({
    "repos": ["knowledge-base"],
    "modes": {
        "research": {"job_class": "research", "secrets": "grant", "git": "none", "writes": [], "net_read": []},
        "implement": {"job_class": "implement", "secrets": "default", "git": "push-own-branch", "writes": [], "net_read": []},
    },
    "caps": {"max_concurrent": 2, "max_per_day": 3, "max_minutes": 60},
}))

CODE_ROOT = TMP / "Code"
(CODE_ROOT / "knowledge-base/.git").mkdir(parents=True)
WT_ROOT = TMP / "worktrees"

REGISTRY = TMP / "registry.sqlite3"
con = sqlite3.connect(REGISTRY)
con.execute("""CREATE TABLE tasks (task_id TEXT PRIMARY KEY, run_id TEXT, remote_task_id TEXT NOT NULL DEFAULT '',
             deadline_at TEXT NOT NULL DEFAULT '', verified INTEGER NOT NULL DEFAULT 0,
             verify_detail TEXT NOT NULL DEFAULT '', manifest TEXT NOT NULL DEFAULT '', created_at TEXT)""")
con.commit()
con.close()


def _fake(name: str, body: str) -> Path:
    p = TMP / name
    p.write_text(f"#!/usr/bin/env bash\n{body}\n")
    p.chmod(0o755)
    return p


CAPTURE = TMP / "captured-brief.md"
FAKE_SPAWN_OUT = TMP / "fake-spawn-outcome"  # "0 ok" or "1" to force a failure
FAKE_SPAWN = _fake("fake-spawn-task.sh", f"""
root="$1"; branch="$2"
brief=""
for a in "$@"; do
  if [ "$prev" = --brief ]; then brief="$a"; fi
  prev="$a"
done
[ -n "$brief" ] && cp "$brief" {CAPTURE}
rc=$(cat {FAKE_SPAWN_OUT} 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
wt="{WT_ROOT}/$(basename "$root")/$branch"
mkdir -p "$wt/.handoffs"
run_id="run_fake1"; task_id="task_fake1"
printf '{{"run_id":"%s","task_id":"%s","pane_id":"pane_1","branch":"%s"}}' "$run_id" "$task_id" "$branch" > "$wt/.handoffs/identity.json"
exit 0
""")

FAKE_BRIDGE_LOG = TMP / "bridge-calls.jsonl"
FAKE_BRIDGE_ROW = TMP / "fake-bridge-row.json"
FAKE_BRIDGE_ROW.write_text(json.dumps({"run_id": "run_fake1", "task_id": "task_fake1", "pane_id": "pane_1", "pane_birth": "birth_1"}))
FAKE_BRIDGE_RC = TMP / "fake-bridge-rc"
FAKE_BRIDGE = _fake("fake-registry-bridge.sh", f"""
printf '%s\\n' "$*" >> {FAKE_BRIDGE_LOG}
rc=$(cat {FAKE_BRIDGE_RC} 2>/dev/null || echo 0)
case "$1" in
  set-remote-id|read|read-by-remote) [ "$rc" = 0 ] && cat {FAKE_BRIDGE_ROW} ;;
esac
exit "$rc"
""")

FAKE_CLOSE_OUT = TMP / "fake-close-stdout"
FAKE_CLOSE_OUT.write_text("  close    pane_1   label    (idle)\n")
FAKE_CLOSE_RC = TMP / "fake-close-rc"
FAKE_CLOSE = _fake("fake-close-done-workers.sh", f"""
cat {FAKE_CLOSE_OUT}
exit "$(cat {FAKE_CLOSE_RC} 2>/dev/null || echo 0)"
""")

os.environ.update(HERDR_RUN_STATE_DIR=str(TMP), HERDR_STATE_DIR=str(TMP / "state"),
                   HERDR_WT_DIR=str(WT_ROOT), HERDR_CODE_DIR=str(CODE_ROOT), HERDR_MCP_TASKS="1")
spec = importlib.util.spec_from_file_location("tasks_under_test", HERE / "tasks.py")
tsk = importlib.util.module_from_spec(spec)
sys.modules["tasks_under_test"] = tsk
spec.loader.exec_module(tsk)
tsk.ALLOWLIST_PATH = ALLOWLIST
tsk.SPAWN_TASK = str(FAKE_SPAWN)
tsk.REGISTRY_BRIDGE = str(FAKE_BRIDGE)
tsk.CLOSE_DONE = str(FAKE_CLOSE)
tsk.REGISTRY = REGISTRY
tsk.WT_ROOT = WT_ROOT
tsk.CODE_ROOT = CODE_ROOT
tsk.TASKS_ON_MAC = True


def _reset_registry(rows: list[tuple] = ()):
    con = sqlite3.connect(REGISTRY)
    con.execute("DELETE FROM tasks")
    con.executemany(
        "INSERT INTO tasks (task_id, run_id, remote_task_id, deadline_at, verified, verify_detail, manifest, created_at) "
        "VALUES (?,?,?,?,?,?,?,?)", rows)
    con.commit()
    con.close()


def _start_cmd(repo="knowledge-base", mode="research", objective="find X") -> dict:
    return {"command_id": "cmd_1", "op": "start", "remote_task_id": "rtask_20261002T000000Z_deadbeef",
            "payload": {"repo": repo, "mode": mode, "objective": objective}}


class Capabilities(unittest.TestCase):
    def test_shape_and_mac_enabled(self):
        tsk.TASKS_ON_MAC = True
        snap = tsk.capabilities_snapshot()
        self.assertEqual(snap["repos"], ["knowledge-base"])
        self.assertEqual(set(snap["modes"]["research"]), set(tsk.MODE_FIELDS))
        self.assertTrue(snap["mac_enabled"])
        tsk.TASKS_ON_MAC = False
        self.assertFalse(tsk.capabilities_snapshot()["mac_enabled"])
        tsk.TASKS_ON_MAC = True


class StartRefusals(unittest.TestCase):
    def setUp(self):
        _reset_registry()
        FAKE_SPAWN_OUT.write_text("0")
        FAKE_BRIDGE_RC.write_text("0")

    def test_tasks_off_on_mac(self):
        tsk.TASKS_ON_MAC = False
        try:
            out = tsk.process_command(_start_cmd())
        finally:
            tsk.TASKS_ON_MAC = True
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("HERDR_MCP_TASKS", out["detail"])

    def test_repo_not_allowlisted(self):
        out = tsk.process_command(_start_cmd(repo="not-a-repo"))
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("not allow-listed", out["detail"])

    def test_unknown_mode(self):
        out = tsk.process_command(_start_cmd(mode="bogus"))
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("unknown mode", out["detail"])

    def test_repo_has_no_local_checkout(self):
        shutil.rmtree(CODE_ROOT / "knowledge-base/.git")
        out = tsk.process_command(_start_cmd())
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("no local checkout", out["detail"])
        (CODE_ROOT / "knowledge-base/.git").mkdir()

    def test_fifth_concurrent_refused_by_mac_cap(self):
        # caps.max_concurrent = 2 in the fixture allowlist. _count_remote's
        # WHERE clause names a `state` column this base fixture table does
        # not carry (added on demand, matching production's shape) --
        # ADD COLUMN ... DEFAULT backfills the two rows just inserted.
        _reset_registry([(f"t{i}", "r", f"rt{i}", "", 0, "", "", "") for i in range(2)])
        con = sqlite3.connect(REGISTRY)
        try:
            con.execute("ALTER TABLE tasks ADD COLUMN state TEXT NOT NULL DEFAULT 'running'")
        except sqlite3.OperationalError:
            pass
        con.commit(); con.close()
        out = tsk.process_command(_start_cmd())
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("too_many_concurrent", out["detail"])


class StartAccepted(unittest.TestCase):
    def setUp(self):
        _reset_registry()
        con = sqlite3.connect(REGISTRY)
        try:
            con.execute("ALTER TABLE tasks ADD COLUMN state TEXT NOT NULL DEFAULT 'running'")
        except sqlite3.OperationalError:
            pass
        con.commit(); con.close()
        FAKE_SPAWN_OUT.write_text("0")
        FAKE_BRIDGE_RC.write_text("0")
        FAKE_BRIDGE_LOG.write_text("")
        shutil.rmtree(WT_ROOT, ignore_errors=True)

    def test_happy_path_accepted(self):
        out = tsk.process_command(_start_cmd(objective="find [X] and tell @owner about it"))
        self.assertEqual(out["outcome"], "accepted")
        self.assertEqual(out["local_task_id"], "task_fake1")
        self.assertEqual(out["local_run_id"], "run_fake1")
        self.assertTrue(out["branch"].startswith("remote/"))
        self.assertEqual(out["pane_id"], "pane_1")
        self.assertEqual(out["agent_id"], "birth_1")
        self.assertIn("secrets_granted", out["capability_probe"])
        self.assertTrue(out["capability_probe"]["secrets_granted"])  # research mode grants
        self.assertIn("set-deadline", FAKE_BRIDGE_LOG.read_text())

    def test_objective_sanitized_before_reaching_the_brief(self):
        tsk.process_command(_start_cmd(objective="do [X] and notify @owner now"))
        text = CAPTURE.read_text()
        fence = text.split("```text untrusted-objective\n", 1)[1].split("\n```", 1)[0]
        self.assertNotIn("[", fence)
        self.assertNotIn("]", fence)
        self.assertNotIn("@owner", fence)  # becomes fullwidth ＠owner
        self.assertIn("\uff20owner", fence)

    def test_spawn_failure_is_a_failed_ack_not_an_exception(self):
        FAKE_SPAWN_OUT.write_text("1")
        out = tsk.process_command(_start_cmd())
        self.assertEqual(out["outcome"], "failed")
        self.assertIn("exit 1", out["detail"])


class CancelCommand(unittest.TestCase):
    def setUp(self):
        FAKE_BRIDGE_RC.write_text("0")
        FAKE_BRIDGE_LOG.write_text("")

    def _cmd(self, local_task_id="task_fake1", reason=None):
        p = {"local_task_id": local_task_id}
        if reason:
            p["reason"] = reason
        return {"command_id": "cmd_c1", "op": "cancel", "remote_task_id": "rtask_1", "payload": p}

    def test_never_spawned_is_accepted_as_a_no_op(self):
        out = tsk.process_command(self._cmd(local_task_id=""))
        self.assertEqual(out["outcome"], "accepted")
        self.assertIn("never spawned", out["detail"])

    def test_happy_path_cancels(self):
        out = tsk.process_command(self._cmd())
        self.assertEqual(out["outcome"], "accepted")
        log = FAKE_BRIDGE_LOG.read_text()
        self.assertIn("read-by-remote rtask_1", log)
        self.assertIn("cancel run_fake1 task_fake1", log)

    def test_bridge_refusal_surfaces_as_failed(self):
        FAKE_BRIDGE_RC.write_text("1")
        out = tsk.process_command(self._cmd())
        self.assertEqual(out["outcome"], "failed")


class VerifyRules(unittest.TestCase):
    def setUp(self):
        self.wt = TMP / "verify-wt"
        shutil.rmtree(self.wt, ignore_errors=True)
        (self.wt / ".handoffs").mkdir(parents=True)

    def test_research_missing_answer(self):
        ok, detail = tsk._verify_research(self.wt)
        self.assertFalse(ok)
        self.assertIn("missing", detail)

    def test_research_no_source_link(self):
        (self.wt / ".handoffs/ANSWER.md").write_text("It is done, trust me.")
        ok, _ = tsk._verify_research(self.wt)
        self.assertFalse(ok)

    def test_research_url_source_link(self):
        (self.wt / ".handoffs/ANSWER.md").write_text("Found it: https://kb.teamthurber.com/entity/123")
        ok, _ = tsk._verify_research(self.wt)
        self.assertTrue(ok)

    def test_research_file_line_source_link(self):
        (self.wt / ".handoffs/ANSWER.md").write_text("See server/main.py:42 for the handler.")
        ok, _ = tsk._verify_research(self.wt)
        self.assertTrue(ok)

    def test_implement_malformed_proof(self):
        ok, detail = tsk._verify_implement(self.wt, "not-two-tokens")
        self.assertFalse(ok)
        self.assertIn("not '<branch> <sha>'", detail)

    def test_implement_real_branch_matches(self):
        origin = TMP / "origin.git"
        subprocess.run(["git", "init", "--bare", "-q", str(origin)], check=True)
        subprocess.run(["git", "init", "-q", str(self.wt)], check=True)
        subprocess.run(["git", "-C", str(self.wt), "config", "user.email", "t@example.com"], check=True)
        subprocess.run(["git", "-C", str(self.wt), "config", "user.name", "t"], check=True)
        (self.wt / "f.txt").write_text("x")
        subprocess.run(["git", "-C", str(self.wt), "add", "f.txt"], check=True)
        subprocess.run(["git", "-C", str(self.wt), "commit", "-q", "-m", "x"], check=True)
        subprocess.run(["git", "-C", str(self.wt), "branch", "-m", "remote/abc123"], check=True)
        subprocess.run(["git", "-C", str(self.wt), "remote", "add", "origin", str(origin)], check=True)
        subprocess.run(["git", "-C", str(self.wt), "push", "-q", "origin", "remote/abc123"], check=True)
        sha = subprocess.run(["git", "-C", str(self.wt), "rev-parse", "remote/abc123"],
                              capture_output=True, text=True, check=True).stdout.strip()
        ok, detail = tsk._verify_implement(self.wt, f"remote/abc123 {sha}")
        self.assertTrue(ok, detail)
        ok, _ = tsk._verify_implement(self.wt, f"remote/abc123 {'f' * 40}")
        self.assertFalse(ok)


class Sweep(unittest.TestCase):
    def setUp(self):
        _reset_registry()
        con = sqlite3.connect(REGISTRY)
        try:
            con.execute("ALTER TABLE tasks ADD COLUMN state TEXT NOT NULL DEFAULT 'running'")
        except sqlite3.OperationalError:
            pass
        con.commit(); con.close()
        self.wt = TMP / "sweep-wt"
        shutil.rmtree(self.wt, ignore_errors=True)
        (self.wt / ".handoffs").mkdir(parents=True)
        FAKE_BRIDGE_RC.write_text("0")
        FAKE_BRIDGE_LOG.write_text("")
        FAKE_CLOSE_RC.write_text("0")

    def _row(self, task_id, remote_id, state="running", deadline="", verify_detail=""):
        con = sqlite3.connect(REGISTRY)
        con.execute("INSERT OR REPLACE INTO tasks (task_id, run_id, remote_task_id, deadline_at, verified, "
                     "verify_detail, manifest, created_at, state) VALUES (?,?,?,?,0,?,?,?,?)",
                     (task_id, "run_x", remote_id, deadline, verify_detail, json.dumps({"git": "none"}), "", state))
        con.commit(); con.close()

    def test_auto_close_on_pending_completion(self):
        self._row("task_a", "rtask_a")
        (self.wt / ".handoffs/identity.json").write_text(json.dumps({"completion_event": "x_done"}))
        (self.wt / ".handoffs/events.jsonl").write_text(
            json.dumps({"event": "x_done", "status": "completed", "reason": "no-follow-on"}) + "\n")
        t = {"task_id": "task_a", "run_id": "run_x", "state": "running", "worktree": str(self.wt)}
        actions = tsk.sweep({"task_a": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["action"], "auto_close")
        self.assertTrue(actions[0]["ok"])

    def test_deadline_overrun_force_cancels(self):
        self._row("task_b", "rtask_b", deadline="2020-01-01T00:00:00Z")
        t = {"task_id": "task_b", "run_id": "run_x", "state": "running", "worktree": str(self.wt)}
        actions = tsk.sweep({"task_b": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertEqual(actions[0]["action"], "force_cancel")
        self.assertTrue(actions[0]["ok"])
        self.assertIn("cancel run_x task_b timed_out", FAKE_BRIDGE_LOG.read_text())

    def test_verify_runs_once_then_is_gated_by_verify_detail(self):
        self._row("task_c", "rtask_c", state="completed")
        (self.wt / ".handoffs/ANSWER.md").write_text("done: https://x/y")
        t = {"task_id": "task_c", "run_id": "run_x", "state": "completed", "worktree": str(self.wt)}
        import datetime as dt
        now = dt.datetime.now(dt.timezone.utc)
        actions = tsk.sweep({"task_c": t}, now)
        self.assertEqual(actions[0]["action"], "verify")
        self.assertTrue(actions[0]["ok"])
        # Second pass: verify_detail is still '' in THIS fixture row (the bridge
        # call was faked, not a real write back) -- sweep would run it again,
        # which is why production's gate reads the real column after the Mac's
        # own set-verified call lands; here we assert the gate condition itself.
        self._row("task_c", "rtask_c", state="completed", verify_detail="already checked")
        actions2 = tsk.sweep({"task_c": t}, now)
        self.assertEqual(actions2, [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
