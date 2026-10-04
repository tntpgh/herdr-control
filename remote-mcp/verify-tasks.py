#!/usr/bin/env python3
"""Behaviour checks for tasks.py. spawn-task.sh/close-done-workers.sh/
registry-bridge.sh are replaced by tiny fake scripts that record their argv
and return canned output, so this never touches a real worktree, herdr pane,
or the live run registry. One exception: SpawnArgvAgainstRealParser runs the
REAL spawn-task.sh in --dry-run, so tasks.py's argv is checked against the
real parser (nothing is spawned). Run with HERDR_RUN_STATE_DIR
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
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
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
# F9/ZR4 (REVIEW-213): tasks.py's _event_count/_event_pids read this table
# directly (read-only), the same way the real lib/run-registry.sh events
# table backs them in production -- minimal columns, no explicit sequence
# (tasks.py orders by rowid, which this table has implicitly like any
# other). FAKE_BRIDGE's append-event case below is this fixture's only
# writer, mirroring what registry-bridge.sh's real append_event does.
con.execute("CREATE TABLE events (run_id TEXT, task_id TEXT, type TEXT, payload TEXT)")
con.commit()
con.close()


def _fake(name: str, body: str) -> Path:
    p = TMP / name
    p.write_text(f"#!/usr/bin/env bash\n{body}\n")
    p.chmod(0o755)
    return p


CAPTURE = TMP / "captured-brief.md"
FAKE_SPAWN_OUT = TMP / "fake-spawn-outcome"  # "0 ok" or "1" to force a failure
FAKE_SPAWN_ENV_CAPTURE = TMP / "fake-spawn-env-capture"  # F7: records HERDR_MCP_REMOTE_SPAWN per call
FAKE_SPAWN = _fake("fake-spawn-task.sh", f"""
root="$1"; branch="$2"
brief=""
for a in "$@"; do
  if [ "$prev" = --brief ]; then brief="$a"; fi
  prev="$a"
done
[ -n "$brief" ] && cp "$brief" {CAPTURE}
printf '%s\\n' "${{HERDR_MCP_REMOTE_SPAWN:-}}" > {FAKE_SPAWN_ENV_CAPTURE}
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
FAKE_BRIDGE_FIND_SPAWNED = TMP / "fake-bridge-find-spawned.json"  # empty = no matching orphan row
FAKE_BRIDGE_FIND_SPAWNED.write_text("")
FAKE_BRIDGE = _fake("fake-registry-bridge.sh", f"""
printf '%s\\n' "$*" >> {FAKE_BRIDGE_LOG}
rc=$(cat {FAKE_BRIDGE_RC} 2>/dev/null || echo 0)
case "$1" in
  set-remote-id|read|read-by-remote) [ "$rc" = 0 ] && cat {FAKE_BRIDGE_ROW} ;;
  find-spawned)
    if [ -s {FAKE_BRIDGE_FIND_SPAWNED} ]; then cat {FAKE_BRIDGE_FIND_SPAWNED}; exit 0; else exit 1; fi
    ;;
  append-event)
    python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('INSERT INTO events (run_id, task_id, type, payload) VALUES (?,?,?,?)',
             (sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else '{{}}'))
con.commit()
" {REGISTRY} "$2" "$3" "$4" "${{5:-{{\\}}}}"
    ;;
esac
exit "$rc"
""")

FAKE_CLOSE_OUT = TMP / "fake-close-stdout"
# F10 (security review round 2, 2026-10-04): _orchestrator_close_research
# now requires the real close-done-workers.sh "closed N" summary line
# (N >= 1), not just rc=0 with no HOLD/REFUSED substring -- match what the
# real script actually prints on a successful --apply.
FAKE_CLOSE_OUT.write_text("  close    pane_1   label    (idle)\nclosed 1, held back 0, refused 0\n")
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

# Fix 5's hard-stop timer spawns a REAL detached `sleep` process -- this
# whole file is otherwise fully faked (module docstring) and must stay
# that way. Record calls instead of actually spawning; HardStop's own test
# class restores the real one only when it explicitly wants it.
HARD_STOP_CALLS: list[list[str]] = []


def _record_hard_stop(argv: list[str]):
    HARD_STOP_CALLS.append(argv)

    class _FakeProc:
        pid = -1

    return _FakeProc()

_REAL_POPEN_DETACHED = tsk._popen_detached
tsk._popen_detached = _record_hard_stop


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


class SpawnArgvAgainstRealParser(unittest.TestCase):
    """Every other test here fakes spawn-task.sh, so a flag tasks.py passes
    that the real parser doesn't know is invisible to them: `--no-focus` fell
    through to positional and reached omp's argv ("unknown flag"), and no
    remote start ever launched an agent (2026-10-02, Zero's first live task).
    Capture _spawn's exact argv and replay it through the REAL spawn-task.sh
    in --dry-run: no tasks.py flag may survive onto the omp launch line."""

    def test_tasks_argv_parses_in_real_spawn_task(self):
        repo = TMP / "argv-repo"
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-q", "--allow-empty", "-m", "init"], check=True,
                       env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})
        brief = TMP / "argv-brief.md"
        brief.write_text("objective\n")
        captured: list[list[str]] = []
        real_run = tsk.subprocess.run
        tsk.subprocess.run = lambda argv, **kw: captured.append(list(argv)) or subprocess.CompletedProcess(argv, 0, "", "")
        try:
            for secrets in ("grant", "withhold"):
                tsk._spawn(repo, "remote/argv-check", {"job_class": "research", "secrets": secrets}, brief)
        finally:
            tsk.subprocess.run = real_run
        self.assertEqual(len(captured), 2)
        real_spawn = str(HERE.parent / "spawn-task.sh")
        # research now spawns with --approval hook (remote-research-answer-
        # answer-approval, 2026-10-02): spawn-task.sh's own safety check
        # refuses --auto-approve unless the omp extension it would load IS
        # this checkout's enforcing hook (never true for ~/.omp/agent/
        # extensions/herdr-control.ts, which is normally symlinked to the
        # deployed MAIN checkout, not this test's worktree) --
        # HERDR_OMP_EXTENSION overrides that lookup for exactly this reason
        # (same seam verify-pretool-enforce.sh's own hook dry-run tests use).
        hook_env = {**os.environ, "HERDR_RUN_STATE_DIR": str(TMP / "argv-runs"),
                    "HERDR_OMP_EXTENSION": str(HERE.parent / "agent-hooks" / "omp-herdr-control.ts")}
        for argv in captured:
            brief.write_text("objective\n")  # _spawn unlinks its brief once spawn-task.sh returns
            out = subprocess.run(["bash", real_spawn, *argv[1:], "--dry-run"], capture_output=True, text=True,
                                 timeout=60, env=hook_env)
            self.assertEqual(out.returncode, 0, out.stderr[-500:])
            launch = next((l for l in out.stdout.splitlines() if l.strip().startswith("launch")), "")
            self.assertTrue(launch, out.stdout[-500:])
            tokens = launch.split()
            for flag in (a for a in argv[1:] if a.startswith("--")):
                self.assertNotIn(flag, tokens, f"{flag} leaked onto the omp command line: {launch}")


class CapabilityProbe(unittest.TestCase):
    """_capability_probe()'s kb_http_reachable: a 2xx-only HTTP reachability
    check, named honestly -- never kb_reachable (which read as "the agent
    can actually use it"), and no kb_auth_ok: this process runs on the Mac
    BEFORE a worker is spawned and never holds the KB credential itself."""

    @classmethod
    def setUpClass(cls):
        cls.status = 200

        class Health(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                self.send_response(CapabilityProbe.status)
                self.end_headers()

            def log_message(self, *a):
                pass

        cls.server = HTTPServer(("127.0.0.1", 0), Health)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.real_url = tsk.KB_HEALTH_URL
        tsk.KB_HEALTH_URL = f"http://127.0.0.1:{cls.server.server_port}/health"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        tsk.KB_HEALTH_URL = cls.real_url

    def test_a_2xx_response_is_reachable(self):
        CapabilityProbe.status = 200
        probe = tsk._capability_probe("knowledge-base", False)
        self.assertIs(probe["kb_http_reachable"], True)
        self.assertNotIn("kb_reachable", probe)

    def test_a_401_response_is_not_reachable_and_the_field_is_renamed(self):
        # The 401-counts-as-reachable claim this fix's SPEC started from was
        # itself wrong: urllib raises HTTPError (a URLError subclass) on a
        # non-2xx status, so the OLD probe already returned False here too.
        # Pinned anyway: the field must still be kb_http_reachable, never
        # kb_reachable, and kb_auth_ok must not exist (no probe makes an
        # authenticated call at this privilege level).
        CapabilityProbe.status = 401
        probe = tsk._capability_probe("knowledge-base", False)
        self.assertIs(probe["kb_http_reachable"], False)
        self.assertNotIn("kb_reachable", probe)
        self.assertNotIn("kb_auth_ok", probe)

    def test_a_non_kb_repo_gets_no_probe_at_all(self):
        probe = tsk._capability_probe("some-other-repo", True)
        self.assertEqual(probe, {"secrets_granted": True})


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

    def test_bad_remote_task_id_shape_refused(self):
        # I4: the Mac trusts the Worker's remote_task_id into a filesystem
        # path and a branch name -- a format check turns a minting bug into
        # a refusal instead of a path surprise.
        cmd = _start_cmd()
        cmd["remote_task_id"] = "not-the-right-shape"
        out = tsk.process_command(cmd)
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("unexpected shape", out["detail"])


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
        FAKE_BRIDGE_FIND_SPAWNED.write_text("")
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

    def test_set_remote_id_failure_cancels_the_orphaned_pane(self):
        # N1: a post-spawn failure after spawn-task.sh has already registered
        # a pane must not leave that agent alive with nothing stopping it.
        fake = TMP / "fake-bridge-fail-remote-id.sh"
        fake.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {FAKE_BRIDGE_LOG}
case "$1" in
  set-remote-id) exit 1 ;;
esac
exit 0
""")
        fake.chmod(0o755)
        old = tsk.REGISTRY_BRIDGE
        tsk.REGISTRY_BRIDGE = str(fake)
        try:
            out = tsk.process_command(_start_cmd())
        finally:
            tsk.REGISTRY_BRIDGE = old
        self.assertEqual(out["outcome"], "failed")
        self.assertIn("cancel run_fake1 task_fake1", FAKE_BRIDGE_LOG.read_text())

    def test_set_deadline_failure_cancels_the_orphaned_pane(self):
        fake = TMP / "fake-bridge-fail-deadline.sh"
        fake.write_text(f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {FAKE_BRIDGE_LOG}
case "$1" in
  set-remote-id) cat {FAKE_BRIDGE_ROW} ;;
  set-deadline) exit 1 ;;
esac
exit 0
""")
        fake.chmod(0o755)
        old = tsk.REGISTRY_BRIDGE
        tsk.REGISTRY_BRIDGE = str(fake)
        try:
            out = tsk.process_command(_start_cmd())
        finally:
            tsk.REGISTRY_BRIDGE = old
        self.assertEqual(out["outcome"], "failed")
        self.assertIn("cancel run_fake1 task_fake1", FAKE_BRIDGE_LOG.read_text())


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


class ResumeCommand(unittest.TestCase):
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
        FAKE_BRIDGE_FIND_SPAWNED.write_text("")
        shutil.rmtree(WT_ROOT, ignore_errors=True)
        self.wt = WT_ROOT / "knowledge-base" / "remote/abc12345"
        self.wt.mkdir(parents=True)

    def _cmd(self, branch="remote/abc12345", repo="knowledge-base", text=""):
        return {"command_id": "cmd_r1", "op": "resume", "remote_task_id": "rtask_20261002T000000Z_deadbeef",
                "payload": {"local_run_id": "run_old1", "local_task_id": "task_old1",
                            "branch": branch, "repo": repo, "text": text}}

    def test_refuses_when_parent_row_is_gone(self):
        # H1: the fallback bug -- a missing/unreadable parent row must never
        # silently default to implement (git push + credentials granted).
        FAKE_BRIDGE_RC.write_text("1")
        out = tsk.process_command(self._cmd())
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("registry row is gone", out["detail"])

    def test_refuses_repo_not_allowlisted(self):
        # M3: _resume must recheck the allowlist, same as _start -- removing
        # a repo from task-allowlist.json must stop resumes into it too.
        out = tsk.process_command(self._cmd(repo="not-a-repo"))
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("not allow-listed", out["detail"])

    def test_refuses_malformed_branch(self):
        # M3/I4: the branch must be the Worker-minted shape, not
        # attacker-controlled free text reaching a worktree path.
        out = tsk.process_command(self._cmd(branch="main"))
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("not a remote task branch", out["detail"])

    def test_refuses_remote_task_id_bad_shape(self):
        cmd = self._cmd()
        cmd["remote_task_id"] = "not-the-right-shape"
        out = tsk.process_command(cmd)
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("unexpected shape", out["detail"])

    def test_refuses_over_daily_cap(self):
        # M1: resume must not be a free pass around max_per_day (fixture caps it at 3).
        _reset_registry([(f"t{i}", "r", f"rt{i}", "", 0, "", "", tsk._now_iso()) for i in range(3)])
        con = sqlite3.connect(REGISTRY)
        # Finished, not running: this must trip the DAILY cap, not the
        # separate concurrent cap (setUp's `state` column defaults to
        # 'running', which would otherwise also saturate max_concurrent).
        con.execute("UPDATE tasks SET state='finished'")
        con.commit(); con.close()
        out = tsk.process_command(self._cmd())
        self.assertEqual(out["outcome"], "refused")
        self.assertIn("too_many_today", out["detail"])

    def test_happy_path_resumes(self):
        out = tsk.process_command(self._cmd(text="one more thing"))
        self.assertEqual(out["outcome"], "accepted")
        self.assertEqual(out["local_task_id"], "task_fake1")
        self.assertIn("set-deadline", FAKE_BRIDGE_LOG.read_text())

    def test_resume_renames_a_stale_answer_aside_before_respawning(self):
        # F3 (security review round 2, 2026-10-04): _resume respawns into
        # the SAME worktree, and spawn-task.sh deliberately keeps
        # .handoffs/ -- a previous run's ANSWER.md left sitting there used
        # to pass _verify_research on the very first sweep after a resume,
        # closing the resumed task on the OLD answer before the new worker
        # (or the follow-up note) ever got a turn.
        (self.wt / ".handoffs").mkdir(parents=True, exist_ok=True)
        (self.wt / ".handoffs/ANSWER.md").write_text("STALE: from the previous run, must never be read as current.")
        out = tsk.process_command(self._cmd(text="one more thing"))
        self.assertEqual(out["outcome"], "accepted")
        self.assertFalse((self.wt / ".handoffs/ANSWER.md").exists(),
                          "a stale ANSWER.md must not still be at the path _verify_research reads")
        self.assertEqual((self.wt / ".handoffs/ANSWER.prev.md").read_text(),
                          "STALE: from the previous run, must never be read as current.")
        ok, detail = tsk._verify_research(self.wt)
        self.assertFalse(ok, f"_verify_research must not pass on the stale answer: {detail}")

    def test_resume_spawns_with_the_remote_spawn_marker_set(self):
        # F7 (security review round 2, 2026-10-04): orchestrator_closes
        # (spawn-task.sh) must only ever fire for a spawn THIS module will
        # actually sweep() -- tasks.py's own _spawn() is the one call site
        # that both creates a remote_task_id row and runs sweep() over it,
        # so it must mark itself, never rely on job_class alone (a LOCAL
        # research/explore spawn shares that job_class and is never swept).
        tsk.process_command(self._cmd(text="one more thing"))
        self.assertEqual(FAKE_SPAWN_ENV_CAPTURE.read_text().strip(), "1")

    def test_resume_crash_before_identity_is_written_looks_up_find_spawned_and_cancels_the_returned_row(self):
        # R3-3/R4-1: a spawn timeout/crash before identity.json is ever
        # written for THIS attempt must not go looking at identity.json at
        # all (worker-writable, and on a REUSED worktree it may hold a
        # different task's stale ids) -- it must ask the registry itself,
        # by worktree + branch + a since-floor, for the row THIS attempt
        # just registered. This only proves the WIRING (right subcommand,
        # right args, cancels whatever the registry says); the real
        # worktree/branch/created_at matching semantics are proved against
        # the REAL registry-bridge.sh in verify-tasks-e2e.py, not this fake.
        FAKE_BRIDGE_FIND_SPAWNED.write_text(json.dumps({"run_id": "run_fake1", "task_id": "task_fake1"}))
        old_spawn = tsk.SPAWN_TASK
        tsk.SPAWN_TASK = str(TMP / "does-not-exist-r33.sh")
        try:
            out = tsk.process_command(self._cmd())
        finally:
            tsk.SPAWN_TASK = old_spawn
        self.assertEqual(out["outcome"], "failed")
        log = FAKE_BRIDGE_LOG.read_text()
        self.assertIn("find-spawned", log)
        self.assertIn("remote/abc12345", log)  # the branch we tried to resume
        self.assertIn(str(self.wt), log)       # the (possibly reused) worktree
        self.assertIn("rtask_20261002T000000Z_deadbeef", log)  # expected_remote_task_id
        self.assertIn("cancel run_fake1 task_fake1", log)

    def test_resume_crash_with_no_matching_registry_row_is_a_safe_no_op(self):
        # find-spawned returning nothing (e.g. spawn-task.sh crashed before
        # ever calling register_task) must never fall back to trusting
        # identity.json -- there is genuinely nothing registered yet, so no
        # cancel is issued.
        FAKE_BRIDGE_FIND_SPAWNED.write_text("")
        old_spawn = tsk.SPAWN_TASK
        tsk.SPAWN_TASK = str(TMP / "does-not-exist-r33b.sh")
        try:
            out = tsk.process_command(self._cmd())
        finally:
            tsk.SPAWN_TASK = old_spawn
        self.assertEqual(out["outcome"], "failed")
        self.assertNotIn("cancel ", FAKE_BRIDGE_LOG.read_text())


class Robustness(unittest.TestCase):
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
        shutil.rmtree(WT_ROOT, ignore_errors=True)
        self.old_spawn = tsk.SPAWN_TASK

    def tearDown(self):
        tsk.SPAWN_TASK = self.old_spawn

    def test_spawn_crash_is_a_failed_ack_not_an_uncaught_exception(self):
        # M7: a slow/crashed composer boot must never crash the whole
        # publisher tick -- it must come back as a failed ack instead.
        tsk.SPAWN_TASK = str(TMP / "does-not-exist.sh")
        out = tsk.process_command(_start_cmd())
        self.assertEqual(out["outcome"], "failed")
        self.assertIn("crashed", out["detail"])


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

    def test_research_file_line_source_link_alone_is_no_longer_sufficient(self):
        # research-task-closure defect 4 (2026-10-04): the incident's
        # ANSWER.md had only a bare path:line reference -- the old regex
        # accepted that as a "source link" and let answer_ready fire on an
        # answer nobody could click through to verify. Only a real https://
        # URL counts now.
        (self.wt / ".handoffs/ANSWER.md").write_text("See server/main.py:42 for the handler.")
        ok, detail = tsk._verify_research(self.wt)
        self.assertFalse(ok)
        self.assertIn("no https:// source link", detail)

    def test_research_answer_symlink_is_refused_not_followed(self):
        # F4(b) (security review round 2, 2026-10-04): is_file()/read_text()
        # follow a symlink -- a worker's worktree is untrusted, same as any
        # other file it wrote, and the old code would happily verify
        # (and later hash) whatever ANSWER.md pointed at outside the
        # worktree. read_single_link_regular's O_NOFOLLOW must refuse it.
        target = self.wt / "outside-answer.md"
        target.write_text("Found it: https://kb.teamthurber.com/entity/123")
        (self.wt / ".handoffs/ANSWER.md").symlink_to(target)
        ok, detail = tsk._verify_research(self.wt)
        self.assertFalse(ok, f"a symlinked ANSWER.md must never verify: {detail}")

    def test_research_answer_hard_link_is_refused(self):
        # F4(b): st_nlink == 1 check -- a hard link means the same bytes are
        # reachable from a path outside anything this check controls.
        target = self.wt / "hardlinked-answer.md"
        target.write_text("Found it: https://kb.teamthurber.com/entity/123")
        answer = self.wt / ".handoffs/ANSWER.md"
        os.link(target, answer)
        ok, detail = tsk._verify_research(self.wt)
        self.assertFalse(ok, f"a hard-linked ANSWER.md must never verify: {detail}")

    def test_research_template_placeholder_link_is_not_a_real_source(self):
        # F9 (security review round 2, 2026-10-04): the brief's own unfilled
        # template text (spawn-task.sh's identity_how_to_complete) copied
        # back verbatim must never satisfy the check -- the placeholder
        # angle brackets immediately follow the otherwise-real github.com
        # host with no whitespace between them, so the WHOLE run must be
        # rejected, not truncated down to a plausible-looking prefix.
        (self.wt / ".handoffs/ANSWER.md").write_text(
            "See https://github.com/<owner>/<repo>/blob/<ref>/<path> for the source.")
        ok, detail = tsk._verify_research(self.wt)
        self.assertFalse(ok, f"an unfilled template link must not verify: {detail}")

    def test_research_bare_host_with_no_dot_is_not_a_real_source(self):
        # F9: https://x (or https://localhost) names no real internet host.
        (self.wt / ".handoffs/ANSWER.md").write_text("done: https://x/y")
        ok, _ = tsk._verify_research(self.wt)
        self.assertFalse(ok)

    def test_research_link_inside_a_fenced_code_block_does_not_count(self):
        # F9: a link quoted ONLY as an example inside a code fence must not
        # satisfy the check.
        (self.wt / ".handoffs/ANSWER.md").write_text(
            "No real source here.\n```\nhttps://kb.teamthurber.com/entity/123\n```\n")
        ok, detail = tsk._verify_research(self.wt)
        self.assertFalse(ok, f"a fenced-code-block-only link must not verify: {detail}")

    def test_implement_malformed_proof(self):
        ok, detail = tsk._verify_implement(self.wt, "not-two-tokens", "remote/abc123")
        self.assertFalse(ok)
        self.assertIn("not '<branch> <sha>'", detail)

    def test_implement_branch_mismatch_refused(self):
        # L1: the proof names a DIFFERENT branch than this task's own --
        # must never be accepted as evidence for this task.
        ok, detail = tsk._verify_implement(self.wt, "remote/not-mine deadbeef", "remote/abc123")
        self.assertFalse(ok)
        self.assertIn("not this task's own", detail)

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
        ok, detail = tsk._verify_implement(self.wt, f"remote/abc123 {sha}", "remote/abc123")
        self.assertTrue(ok, detail)
        ok, _ = tsk._verify_implement(self.wt, f"remote/abc123 {'f' * 40}", "remote/abc123")
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

    def _row(self, task_id, remote_id, state="running", deadline="", verify_detail="", manifest=None):
        con = sqlite3.connect(REGISTRY)
        con.execute("INSERT OR REPLACE INTO tasks (task_id, run_id, remote_task_id, deadline_at, verified, "
                     "verify_detail, manifest, created_at, state) VALUES (?,?,?,?,0,?,?,?,?)",
                     (task_id, "run_x", remote_id, deadline, verify_detail,
                      manifest if manifest is not None else json.dumps({"git": "none"}), "", state))
        con.commit(); con.close()

    def _event(self, task_id, type_, payload="{}"):
        con = sqlite3.connect(REGISTRY)
        con.execute("INSERT INTO events (run_id, task_id, type, payload) VALUES (?,?,?,?)",
                     ("run_x", task_id, type_, payload))
        con.commit(); con.close()

    def test_auto_close_on_pending_completion(self):
        # research-task-closure defect 1: a self-reported completion_event
        # only ever reaches sweep() via _pending_completion for a task whose
        # manifest does NOT restrict its write tool (implement mode) -- a
        # git:none/research row is now routed to _orchestrator_close_research
        # instead (its own tests below), since a research worker can never
        # write events.jsonl in the first place.
        self._row("task_a", "rtask_a", manifest=json.dumps({"git": "push-own-branch"}))
        # F9/ZR4: a task reaching sweep() via the normal _start() path
        # already has its hard-stop timer scheduled and recorded -- seed
        # that baseline so this auto_close-only test is not also exercising
        # the separate hard_stop_retry path (covered by its own tests below).
        self._event("task_a", "hard_stop_scheduled", json.dumps({"pid": 1}))
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

    def test_pending_completion_wins_over_an_overrun_deadline(self):
        # F10 (security review PR #220): the deadline check used to run
        # BEFORE the pending-completion check, so a task whose worker had
        # already delivered its completion event -- just waiting on a
        # HOLD-retried auto_close (pane busy) -- could still be
        # force-cancelled timed_out past its deadline, discarding an
        # answer that was already on disk. A delivered completion event
        # must always win over the timer.
        self._row("task_c", "rtask_c", deadline="2020-01-01T00:00:00Z", manifest=json.dumps({"git": "push-own-branch"}))
        self._event("task_c", "hard_stop_scheduled", json.dumps({"pid": 1}))
        (self.wt / ".handoffs/identity.json").write_text(json.dumps({"completion_event": "y_done"}))
        (self.wt / ".handoffs/events.jsonl").write_text(
            json.dumps({"event": "y_done", "status": "completed", "reason": "no-follow-on"}) + "\n")
        t = {"task_id": "task_c", "run_id": "run_x", "state": "running", "worktree": str(self.wt)}
        actions = tsk.sweep({"task_c": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["action"], "auto_close")
        self.assertTrue(actions[0]["ok"])
        self.assertNotIn("timed_out", FAKE_BRIDGE_LOG.read_text())

    def test_orchestrator_closes_a_verified_research_task_itself(self):
        # research-task-closure defect 1 (2026-10-04): a research/explore
        # task's manifest restricts its write tool to .handoffs/ANSWER.md
        # (handoffs_write), so it can never append its own completion_event
        # to events.jsonl the way an implement task does -- _pending_completion
        # finds nothing and the task sat open forever. A git:none row with a
        # valid ANSWER.md must now self-close via the orchestrator path,
        # with no events.jsonl / completion_event involved at all.
        self._row("task_r", "rtask_r")  # default manifest: git:none == research
        (self.wt / ".handoffs/ANSWER.md").write_text("Answer: see https://example.com/evidence for the source.")
        t = {"task_id": "task_r", "run_id": "run_x", "state": "running", "worktree": str(self.wt),
             "agent_live": True, "pane_status": "idle", "has_pending_request": False}
        actions = tsk.sweep({"task_r": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["action"], "orchestrator_close")
        self.assertTrue(actions[0]["ok"])
        con = sqlite3.connect(REGISTRY)
        rows = con.execute("SELECT type, payload FROM events WHERE task_id='task_r'").fetchall()
        con.close()
        kinds = [r[0] for r in rows]
        self.assertIn("orchestrator_closed", kinds)
        payload = json.loads(next(p for k, p in rows if k == "orchestrator_closed"))
        self.assertEqual(payload["actor"], "orchestrator")
        self.assertEqual(payload["reason"], "no-follow-on")
        self.assertTrue(payload["proof"])  # the ANSWER.md sha256, never blank

    def test_orchestrator_never_closes_when_agent_live_is_false(self):
        # F2 (security review round 2, 2026-10-04): a valid ANSWER.md alone
        # is never enough -- the live snapshot must agree the worker's own
        # pane is actually occupied by THIS task's birth-verified process
        # (publisher.py's agent_live). Without it, this is retried, never
        # closed, same as finding no answer at all.
        self._row("task_live", "rtask_live")
        self._event("task_live", "hard_stop_scheduled", json.dumps({"pid": 1}))
        (self.wt / ".handoffs/ANSWER.md").write_text("Answer: see https://example.com/evidence for the source.")
        t = {"task_id": "task_live", "run_id": "run_x", "state": "running", "worktree": str(self.wt),
             "agent_live": False, "pane_status": "idle", "has_pending_request": False}
        actions = tsk.sweep({"task_live": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertEqual(actions, [])
        con = sqlite3.connect(REGISTRY)
        n = con.execute("SELECT COUNT(*) FROM events WHERE task_id='task_live' AND type='orchestrator_closed'").fetchone()[0]
        con.close()
        self.assertEqual(n, 0)

    def test_orchestrator_never_closes_when_pane_status_is_not_idle_or_done(self):
        # F2: a hook-mode research worker with a pending action_request
        # never shows up as `blocked`/live_blocked -- pane_status is the
        # only signal, and an unrecognized/working/blocked status must
        # never be treated as safe to close on.
        self._row("task_blk", "rtask_blk")
        self._event("task_blk", "hard_stop_scheduled", json.dumps({"pid": 1}))
        (self.wt / ".handoffs/ANSWER.md").write_text("Answer: see https://example.com/evidence for the source.")
        t = {"task_id": "task_blk", "run_id": "run_x", "state": "running", "worktree": str(self.wt),
             "agent_live": True, "pane_status": "blocked", "has_pending_request": False}
        actions = tsk.sweep({"task_blk": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertEqual(actions, [])

    def test_orchestrator_never_closes_with_a_pending_action_request(self):
        # F2: an outstanding action_request this pane is waiting on means
        # the worker's turn is NOT actually over, regardless of pane_status.
        self._row("task_pend", "rtask_pend")
        self._event("task_pend", "hard_stop_scheduled", json.dumps({"pid": 1}))
        (self.wt / ".handoffs/ANSWER.md").write_text("Answer: see https://example.com/evidence for the source.")
        t = {"task_id": "task_pend", "run_id": "run_x", "state": "running", "worktree": str(self.wt),
             "agent_live": True, "pane_status": "idle", "has_pending_request": True}
        actions = tsk.sweep({"task_pend": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertEqual(actions, [])

    def test_orchestrator_close_requires_the_summary_to_say_it_actually_closed_something(self):
        # F10 (security review round 2, 2026-10-04): rc=0 with no
        # HOLD/REFUSED substring is also what "closed 0" looks like -- an
        # empty pane_id hitting close-done's own `continue`, or a row that
        # left the running states between this sweep's snapshot and the
        # call. Must not be recorded as a confirmed close.
        self._row("task_n0", "rtask_n0")
        (self.wt / ".handoffs/ANSWER.md").write_text("Answer: see https://example.com/evidence for the source.")
        t = {"task_id": "task_n0", "run_id": "run_x", "state": "running", "worktree": str(self.wt),
             "agent_live": True, "pane_status": "idle", "has_pending_request": False}
        FAKE_CLOSE_OUT.write_text("closed 0, held back 0, refused 0\n")
        try:
            actions = tsk.sweep({"task_n0": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        finally:
            FAKE_CLOSE_OUT.write_text("  close    pane_1   label    (idle)\nclosed 1, held back 0, refused 0\n")
        close_actions = [a for a in actions if a["action"] == "orchestrator_close"]
        self.assertEqual(len(close_actions), 1)
        self.assertFalse(close_actions[0]["ok"], "closed 0 must never be recorded as a confirmed close")
        con = sqlite3.connect(REGISTRY)
        n = con.execute("SELECT COUNT(*) FROM events WHERE task_id='task_n0' AND type='orchestrator_closed'").fetchone()[0]
        con.close()
        self.assertEqual(n, 0)

    def test_orchestrator_hold_falls_through_to_the_hard_stop_backstop_same_tick(self):
        # F8 (security review round 2, 2026-10-04): close-done-workers.sh
        # HOLDing (pane still mid-turn, worktree dirty, etc.) means the task
        # is NOT actually done -- the old `if action: ... continue` treated
        # a HOLD exactly like a confirmed close and skipped the
        # deadline/hard-stop check below for the rest of this tick, which
        # could silently let a hard-stop timer never get (re)armed.
        self._row("task_hold", "rtask_hold")
        (self.wt / ".handoffs/ANSWER.md").write_text("Answer: see https://example.com/evidence for the source.")
        t = {"task_id": "task_hold", "run_id": "run_x", "state": "running", "worktree": str(self.wt),
             "agent_live": True, "pane_status": "idle", "has_pending_request": False}
        FAKE_CLOSE_OUT.write_text("  HOLD   pane_1   label    1 uncommitted file(s)\n")
        try:
            actions = tsk.sweep({"task_hold": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        finally:
            FAKE_CLOSE_OUT.write_text("  close    pane_1   label    (idle)\nclosed 1, held back 0, refused 0\n")
        kinds = [a["action"] for a in actions]
        self.assertIn("orchestrator_close", kinds)
        close_action = next(a for a in actions if a["action"] == "orchestrator_close")
        self.assertFalse(close_action["ok"])
        self.assertIn("hard_stop_retry", kinds,
                       "a HOLD must still fall through to the hard-stop backstop check on the same tick")

    def test_orchestrator_never_closes_a_research_task_whose_answer_has_no_url(self):
        # defect 4 paired with defect 1: a bare path:line ANSWER.md must
        # never be treated as done just because sweep() now knows how to
        # self-close research tasks -- it must keep retrying (same as
        # _pending_completion finding nothing) until a real source lands.
        self._row("task_s", "rtask_s")
        self._event("task_s", "hard_stop_scheduled", json.dumps({"pid": 1}))  # isolate from that retry path
        (self.wt / ".handoffs/ANSWER.md").write_text("See server/main.py:42 for the handler.")
        t = {"task_id": "task_s", "run_id": "run_x", "state": "running", "worktree": str(self.wt)}
        actions = tsk.sweep({"task_s": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertEqual(actions, [])
        con = sqlite3.connect(REGISTRY)
        n = con.execute("SELECT COUNT(*) FROM events WHERE task_id='task_s' AND type='orchestrator_closed'").fetchone()[0]
        con.close()
        self.assertEqual(n, 0)

    def test_deadline_fallback_when_set_deadline_never_landed(self):
        # N1: an empty deadline_at (a post-spawn set-deadline call that never
        # landed) must not mean "never times out" -- sweep falls back to
        # created_at + the allowlist's current max_minutes.
        self._row("task_d", "rtask_d", deadline="")
        t = {"task_id": "task_d", "run_id": "run_x", "state": "running", "worktree": str(self.wt),
             "created_at": "2020-01-01T00:00:00Z"}
        actions = tsk.sweep({"task_d": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertEqual(actions[0]["action"], "force_cancel")
        self.assertTrue(actions[0]["ok"])

    def test_verify_runs_once_then_is_gated_by_verify_detail(self):
        self._row("task_c", "rtask_c", state="completed")
        (self.wt / ".handoffs/ANSWER.md").write_text("done: https://kb.teamthurber.com/entity/123")
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

    def test_sweep_retries_a_missing_hard_stop_timer_for_a_running_task(self):
        # ZR4: a task with NO hard_stop_scheduled event (the Popen call in
        # _start/_resume failed, or in this fixture simply never ran)
        # must not be left with no backstop forever -- sweep's own pass
        # schedules it, exactly like _start's own call would have.
        self._row("task_e", "rtask_e")
        t = {"task_id": "task_e", "run_id": "run_x", "state": "running", "worktree": str(self.wt)}
        before = len(HARD_STOP_CALLS)
        actions = tsk.sweep({"task_e": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        retry = next(a for a in actions if a["action"] == "hard_stop_retry")
        self.assertTrue(retry["ok"])
        self.assertEqual(len(HARD_STOP_CALLS), before + 1)
        self.assertIn("hard_stop_scheduled", FAKE_BRIDGE_LOG.read_text())
        # A second sweep tick must NOT retry again -- the event just
        # recorded satisfies the dedup check.
        actions2 = tsk.sweep({"task_e": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
        self.assertFalse(any(a["action"] == "hard_stop_retry" for a in actions2))
        self.assertEqual(len(HARD_STOP_CALLS), before + 1)

    def test_sweep_retried_hard_stop_uses_the_remaining_deadline_not_a_fresh_window(self):
        # R2-4 (round-2 review of ZR4): a task already most of the way
        # through its max_minutes allotment when its ORIGINAL timer is
        # lost to a Popen failure must get a retry timer for the time it
        # actually has LEFT, not a brand-new full-length window measured
        # from the retry's own now -- the latter would silently double a
        # task's real deadline.
        import datetime as _dt
        now = _dt.datetime.now(_dt.timezone.utc)
        deadline = now + _dt.timedelta(minutes=5)  # 5 min left, not a fresh 60
        self._row("task_g", "rtask_g", deadline=deadline.strftime("%Y-%m-%dT%H:%M:%SZ"))
        t = {"task_id": "task_g", "run_id": "run_x", "state": "running", "worktree": str(self.wt)}
        actions = tsk.sweep({"task_g": t}, now)
        retry = next(a for a in actions if a["action"] == "hard_stop_retry")
        self.assertTrue(retry["ok"])
        script = HARD_STOP_CALLS[-1][2]
        delay = int(script.split("sleep ", 1)[1].split(";", 1)[0])
        # ~5 min (300s) + grace, with slack for test wall-clock drift --
        # must be nowhere near a fresh max_minutes*60+grace window (the
        # allowlist cap used elsewhere in this file is 60 minutes).
        self.assertLess(delay, 600 + tsk.HARD_STOP_GRACE_S)
        self.assertGreater(delay, tsk.HARD_STOP_GRACE_S)

    def test_sweep_gives_up_loudly_after_hard_stop_retry_cap(self):
        # ZR4: a scheduling call that keeps failing (e.g. the Mac is out of
        # process slots) must not retry silently forever -- after
        # HARD_STOP_RETRY_CAP failures, exactly ONE hard_stop_stuck event
        # fires and further ticks go quiet instead of flooding.
        self._row("task_f", "rtask_f")
        t = {"task_id": "task_f", "run_id": "run_x", "state": "running", "worktree": str(self.wt)}

        def _boom(argv):
            raise OSError("no process slots")
        old = tsk._popen_detached
        tsk._popen_detached = _boom
        try:
            for _ in range(tsk.HARD_STOP_RETRY_CAP):
                actions = tsk.sweep({"task_f": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
                retry = next(a for a in actions if a["action"] == "hard_stop_retry")
                self.assertFalse(retry["ok"])
            # One more tick past the cap: a single loud hard_stop_stuck,
            # not another retry attempt.
            stuck_actions = tsk.sweep({"task_f": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
            stuck = next(a for a in stuck_actions if a["action"] == "hard_stop_retry")
            self.assertFalse(stuck["ok"])
            self.assertIn("stuck", stuck["detail"])
            log = FAKE_BRIDGE_LOG.read_text()
            self.assertEqual(log.count("hard_stop_stuck"), 1)
            # Further ticks stay silent -- the cap's own dedup (one
            # hard_stop_stuck already recorded) stops re-firing.
            quiet = tsk.sweep({"task_f": t}, __import__("datetime").datetime.now(__import__("datetime").timezone.utc))
            self.assertFalse(any(a["action"] == "hard_stop_retry" for a in quiet))
        finally:
            tsk._popen_detached = old

    def test_sweep_retries_auto_close_when_derived_state_moved_to_ready_review_but_stored_state_is_still_live(self):
        # remote-research-answer-approval (2026-10-03, conductor live-test
        # finding): publisher.py's `state` field is the HUB-DERIVED state
        # (ready_review once a worker's completion event lands), while the
        # registry's own stored_state stays "running" until
        # close-done-workers.sh actually closes it. sweep() used to gate on
        # DERIVED state, so a finished task fell out of the
        # running/starting/blocked set the instant its completion event
        # landed and was never auto_closed again -- including never
        # retried past a transient HOLD (pane still WORKING).
        self._row("task_e", "rtask_e", manifest=json.dumps({"git": "push-own-branch"}))
        self._event("task_e", "hard_stop_scheduled", json.dumps({"pid": 1}))
        (self.wt / ".handoffs/identity.json").write_text(json.dumps({"completion_event": "x_done"}))
        (self.wt / ".handoffs/events.jsonl").write_text(
            json.dumps({"event": "x_done", "status": "completed", "reason": "no-follow-on"}) + "\n")
        t = {"task_id": "task_e", "run_id": "run_x", "state": "ready_review", "stored_state": "running",
             "worktree": str(self.wt)}
        now = __import__("datetime").datetime.now(__import__("datetime").timezone.utc)
        FAKE_CLOSE_OUT.write_text("  HOLD: pane is WORKING\n")
        try:
            actions = tsk.sweep({"task_e": t}, now)
            self.assertEqual(len(actions), 1)
            self.assertEqual(actions[0]["action"], "auto_close")
            self.assertFalse(actions[0]["ok"], "a HOLD must be reported, not silently dropped")
            # Retried on the next tick (same ready_review/running pairing):
            # the first HOLD must not have been the sweep's last look at it.
            FAKE_CLOSE_OUT.write_text("  close    pane_1   label    (idle)\n")
            actions2 = tsk.sweep({"task_e": t}, now)
            self.assertEqual(len(actions2), 1)
            self.assertEqual(actions2[0]["action"], "auto_close")
            self.assertTrue(actions2[0]["ok"])
        finally:
            FAKE_CLOSE_OUT.write_text("  close    pane_1   label    (idle)\n")


class HardStop(unittest.TestCase):
    """SPEC fix item 5: every accepted start/resume schedules a detached
    timer independent of the publisher process staying alive -- sweep()'s
    own deadline check depends on the publisher still ticking; this does
    not. _popen_detached is this fully-faked suite's seam (module-level
    patch above): no real `sleep` ever runs here for the SCHEDULING tests
    below. The last test in this class is the one exception: it restores
    the real _popen_detached and proves actual independent firing, with
    the grace window shrunk so it does not need to wait a real hour --
    verify-tasks-e2e.py separately proves a REAL pid survives at full
    production delay (and reaps it immediately after)."""

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
        FAKE_BRIDGE_FIND_SPAWNED.write_text("")
        shutil.rmtree(WT_ROOT, ignore_errors=True)
        HARD_STOP_CALLS.clear()

    def test_an_accepted_start_schedules_exactly_one_hard_stop_at_max_minutes_plus_grace(self):
        out = tsk.process_command(_start_cmd())
        self.assertEqual(out["outcome"], "accepted")
        self.assertEqual(len(HARD_STOP_CALLS), 1)
        script = HARD_STOP_CALLS[0][2]  # ["/bin/bash", "-c", script]
        self.assertIn(f"sleep {60 * 60 + tsk.HARD_STOP_GRACE_S};", script)
        self.assertIn("cancel run_fake1 task_fake1 timed_out rtask_20261002T000000Z_deadbeef", script)
        self.assertIn("hard_stop_scheduled", FAKE_BRIDGE_LOG.read_text())

    def test_scheduling_failure_does_not_fail_the_start_itself(self):
        def _boom(argv):
            raise OSError("no process slots")
        old = tsk._popen_detached
        tsk._popen_detached = _boom
        try:
            out = tsk.process_command(_start_cmd())
        finally:
            tsk._popen_detached = old
        self.assertEqual(out["outcome"], "accepted")
        self.assertNotIn("hard_stop_scheduled", FAKE_BRIDGE_LOG.read_text())

    def test_the_scheduled_timer_actually_fires_its_own_cancel_with_nothing_else_watching(self):
        # The two tests above only prove _schedule_hard_stop was CALLED
        # correctly (module-level fake records the argv). This proves the
        # thing it schedules is a REAL, independently-firing process: no
        # sweep(), no publisher tick, nothing but the detached sleep+exec
        # itself drives this cancel call into the bridge log.
        old_popen, old_grace = tsk._popen_detached, tsk.HARD_STOP_GRACE_S
        tsk._popen_detached = _REAL_POPEN_DETACHED
        tsk.HARD_STOP_GRACE_S = 1  # keep the test fast; delay = 0*60 + 1 = 1s
        try:
            pid = tsk._schedule_hard_stop("run_real", "task_real", "rtask_real", 0)
        finally:
            tsk._popen_detached = old_popen
            tsk.HARD_STOP_GRACE_S = old_grace
        self.assertIsNotNone(pid, "a real detached process must have been started")
        deadline = time.time() + 5
        seen = ""
        while time.time() < deadline:
            seen = FAKE_BRIDGE_LOG.read_text()
            if "cancel run_real task_real timed_out rtask_real" in seen:
                break
            time.sleep(0.1)
        self.assertIn("cancel run_real task_real timed_out rtask_real", seen,
                       "the detached timer never fired its own cancel within 5s -- "
                       "nothing but the scheduled process itself was supposed to drive this")


if __name__ == "__main__":
    unittest.main(verbosity=1)
