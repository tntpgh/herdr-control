#!/usr/bin/env python3
"""Behaviour checks for publisher.py. No network beyond a loopback fixture hub,
no real herdr: delivery goes to a fake herdr-deliver that records its argv.

    python3 remote-mcp/verify-publisher.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp(prefix="herdr-mcp-verify-"))
NOW = datetime.now(timezone.utc)
Z = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: E731

# ── fixture world: two worktrees, a registry, a hub ────────────────────────────
WT_ROOT = TMP / ".herdr/worktrees"
for name, proof in (("kb/feat-a", "# Proof\nmerged; token ghp_" + "a" * 36 + " used\n"), ("kb/feat-old", "old")):
    (WT_ROOT / name / ".handoffs").mkdir(parents=True)
    (WT_ROOT / name / ".handoffs/PROOF.md").write_text(proof)
OUTSIDE = TMP / "elsewhere/x"
(OUTSIDE / ".handoffs").mkdir(parents=True)
(OUTSIDE / ".handoffs/PROOF.md").write_text("must never be read")

TASKS = [
    # live worker, birth matches
    dict(task_id="task_A", run_id="r1", label="implement:feat/a", repo="/x/knowledge-base", state="running", pane_id="w1:p2",
         conductor_id="conductor_w1:p1", worktree=str(WT_ROOT / "kb/feat-a"), branch="feat/a", project="knowledge-base",
         created_at=Z(NOW), updated_at=Z(NOW), stored_state="running", state_source="live", evidence_at=None,
         closure_reason=None, closure_proof=None),
    # same pane id, but the pane's terminal was replaced: NOT live
    dict(task_id="task_R", run_id="r2", label="implement:feat/r", repo="/x/kb", state="running", pane_id="w1:p3",
         conductor_id="conductor_w1:p1", worktree=str(OUTSIDE), branch="feat/r", project="kb", created_at=Z(NOW),
         updated_at=Z(NOW), stored_state="running", state_source="live", evidence_at=None, closure_reason=None, closure_proof=None),
    # terminal and old: dropped from the snapshot
    dict(task_id="task_OLD", run_id="r3", label="x", repo="/x/kb", state="completed", pane_id="", conductor_id="",
         worktree=str(WT_ROOT / "kb/feat-old"), branch="b", project="kb", created_at=Z(NOW - timedelta(days=40)),
         updated_at=Z(NOW - timedelta(days=30)), stored_state="completed", state_source="registry", evidence_at=None,
         closure_reason="shipped", closure_proof="https://github.com/x/y/pull/1 abc"),
]
PANES = [
    dict(pane_id="w1:p1", birth="term_cond", agent="omp", agent_status="idle", label=None, workspace="ops", tab_id="w1:t1", since=1.79e9),
    dict(pane_id="w1:p2", birth="term_a", agent="omp", agent_status="blocked", label=None, workspace="kb", tab_id="w1:t2", since=1.79e9),
    dict(pane_id="w1:p3", birth="term_NEW", agent="omp", agent_status="working", label=None, workspace="kb", tab_id="w1:t3", since=1.79e9),
    dict(pane_id="w1:p9", birth="term_shell", agent=None, agent_status="unknown", label=None, workspace="kb", tab_id="w1:t9", since=1.79e9),
]
REG = TMP / "registry.sqlite3"
con = sqlite3.connect(REG)
con.execute("CREATE TABLE tasks (task_id TEXT PRIMARY KEY, pane_birth TEXT)")
con.execute("CREATE TABLE events (sequence INTEGER PRIMARY KEY, task_id TEXT, type TEXT, occurred_at TEXT, payload TEXT)")
con.executemany("INSERT INTO tasks VALUES (?,?)", [("task_A", "term_a"), ("task_R", "term_OLD"), ("task_OLD", "")])
con.execute("INSERT INTO events VALUES (1,'task_A','input_required',?,?)", (Z(NOW), json.dumps({"tool": "bash", "message": "bash: git status"})))
con.execute("INSERT INTO events VALUES (2,'task_A','input_required',?,?)",
            (Z(NOW), json.dumps({"tool": "bash", "message": "bash: curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123' x"})))
con.commit()
con.close()


class Hub(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = {"/herdr?json=1": {"tasks": TASKS, "herdr_reachable": True, "live": {"connected": True}},
                "/api/panes": {"connected": True, "panes": PANES},
                "/api/summary": {"rev": "abc", "live_connected": True, "attention": 1, "open_decisions": 0, "handoff_debt": 0},
                }.get(self.path)
        self.send_response(200 if body else 404)
        self.end_headers()
        self.wfile.write(json.dumps(body or {}).encode())

    def log_message(self, *a):
        pass


hub = HTTPServer(("127.0.0.1", 0), Hub)
threading.Thread(target=hub.serve_forever, daemon=True).start()

FAKE = TMP / "fake-deliver.sh"
FAKE.write_text('#!/bin/bash\nfor a in "$@"; do printf "%s\\0" "$a"; done > "$FAKE_ARGV"\nexit "${FAKE_RC:-0}"\n')
FAKE.chmod(0o755)

os.environ.update(HERDR_HUB_URL=f"http://127.0.0.1:{hub.server_port}", HERDR_RUN_REGISTRY=str(REG),
                  HERDR_STATE_DIR=str(TMP / "state"), HERDR_DELIVER=str(FAKE), FAKE_ARGV=str(TMP / "argv"))
spec = importlib.util.spec_from_file_location("publisher", HERE / "publisher.py")
pub = importlib.util.module_from_spec(spec)
sys.modules["publisher"] = pub
spec.loader.exec_module(pub)
pub.WORKTREE_ROOTS = (WT_ROOT,)


class Snapshot(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.snap, cls.local = pub.build(NOW)
        cls.tasks = {t["task_id"]: t for t in cls.snap["tasks"]}

    def test_old_terminal_tasks_are_dropped(self):
        self.assertEqual(set(self.tasks), {"task_A", "task_R"})

    def test_live_only_when_the_pane_terminal_matches_the_task(self):
        self.assertEqual((self.tasks["task_A"]["agent_live"], self.tasks["task_A"]["agent_id"]), (True, "term_a"))
        self.assertEqual((self.tasks["task_R"]["agent_live"], self.tasks["task_R"]["pane_id"]), (False, None))

    def test_roles_and_shell_panes(self):
        roles = {a["agent_id"]: (a["role"], a["task_id"]) for a in self.snap["agents"]}
        self.assertEqual(roles, {"term_cond": ("conductor", None), "term_a": ("worker", "task_A"), "term_NEW": ("session", None)})

    def test_blocker_uses_newest_ask_and_is_redacted(self):
        (b,) = [b for b in self.snap["blockers"] if b["task_id"] == "task_A"]
        self.assertEqual(b["kind"], "permission")
        self.assertIn("Bearer [REDACTED]", b["summary"])
        self.assertNotIn("abcdefghijklmnop", json.dumps(self.snap))

    def test_no_paths_or_screen_text_leave_the_mac(self):
        blob = json.dumps(self.snap)
        self.assertNotIn(str(TMP), blob)
        self.assertNotIn("cwd", blob)

    def test_results_are_redacted_bounded_and_never_read_outside_worktree_roots(self):
        res = pub.changed_results(self.snap, self.local, {}, NOW.timestamp())
        self.assertEqual([r["task_id"] for r in res], ["task_A"])
        self.assertIn("[REDACTED:github-token]", res[0]["text"])
        again = pub.changed_results(self.snap, self.local, {"task_A": {"sha256": res[0]["sha256"], "sent_at": NOW.timestamp()}},
                                    NOW.timestamp())
        self.assertEqual(again, [])


class Signing(unittest.TestCase):
    def test_known_answer_vector_shared_with_the_worker(self):
        self.assertEqual(pub.sign("k" * 48, "1790000000", "00112233445566778899aabbccddeeff", b'{"a":1}'),
                         "f4935fd023e944e2419e58698ab59de978615dd4d41b4d68a4177bbb17482a89")


class Redaction(unittest.TestCase):
    def test_credential_shapes(self):
        # Built from parts so the fixtures never match the repo's own secret scanner.
        for raw in ["sk-proj-" + "x" * 30, "xo" + "xb-12345-abcdefghij", "AK" + "IAABCDEFGHIJKLMNOP", "ops_" + "y" * 30,
                    "postgres://user:hunter2pass@db.example.com/x", "NEON_PASSWORD=supersecret1",
                    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"]:
            self.assertNotIn(raw, pub.redact(f"before {raw} after"), raw)

    def test_ordinary_text_untouched(self):
        s = "merged PR #431 at 4394e662; tests 15/15; op://secrets/x/credential is a reference"
        self.assertEqual(pub.redact(s), s)


class Delivery(unittest.TestCase):
    def setUp(self):
        self.snap, self.local = pub.build(NOW)
        self.item = {"message_id": "msg_1", "task_id": "task_A", "pane_id": "w1:p2", "agent_id": "term_a",
                     "text": "please add a test\nfor the empty case", "client_name": "Zero<script>"}
        (TMP / "argv").unlink(missing_ok=True)

    def argv(self):
        return (TMP / "argv").read_bytes().split(b"\0")[:-1]

    def test_delivers_framed_single_argv_without_force(self):
        os.environ["FAKE_RC"] = "0"
        self.assertEqual(pub.deliver(self.item, self.local)["outcome"], "delivered")
        pane, text = [a.decode() for a in self.argv()]
        self.assertEqual(pane, "w1:p2")
        self.assertTrue(text.startswith("[REMOTE NOTE via herdr-mcp from Zeroscript"))
        self.assertTrue(text.endswith("please add a test for the empty case"))
        self.assertNotIn("\n", text)

    def test_exit_codes_map_to_outcomes(self):
        for rc, outcome in ((5, "retry"), (6, "retry"), (4, "failed"), (7, "refused"), (3, "refused"), (9, "failed")):
            os.environ["FAKE_RC"] = str(rc)
            self.assertEqual(pub.deliver(self.item, self.local)["outcome"], outcome, rc)

    def test_refuses_without_typing_when_the_mac_disagrees(self):
        for change in ({"task_id": "task_R"}, {"agent_id": "term_other"}, {"pane_id": "w1:p3"}, {"task_id": "nope"},
                       {"text": "x" * 2001}, {"text": "\x1b\n\r"}):
            out = pub.deliver({**self.item, **change}, self.local)
            self.assertEqual(out["outcome"], "refused", change)
        self.assertFalse((TMP / "argv").exists(), "nothing may be typed when a re-check fails")


if __name__ == "__main__":
    unittest.main(verbosity=1)
