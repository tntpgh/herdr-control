#!/usr/bin/env python3
"""Storage/adapter fixtures only: no live panes, approvals or transport sends."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "lib/task-authorization.py"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class RegistryAuthorization(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="herdr-authorization-")
        self.base = Path(self.temp.name)
        self.env = {**os.environ, "HERDR_RUN_STATE_DIR": str(self.base / "state")}
        self.db = self.base / "state/registry.sqlite3"
        self.sh("registry_init")

    def tearDown(self):
        self.temp.cleanup()

    def sh(self, code, *args, ok=True):
        p = subprocess.run(["bash", "-c", 'source "$1/lib/run-registry.sh"; shift; ' + code,
                            "fixture", str(ROOT), *args], env=self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def call(self, op, *args, ok=True, reason=None):
        p = subprocess.run([sys.executable, str(HELPER), str(self.db), op, *args],
                           text=True, capture_output=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("authorization hold: ", p.stderr)
            if reason:
                self.assertIn(reason, p.stderr)
        return p

    def query(self, sql, args=()):
        with sqlite3.connect(self.db) as db:
            return db.execute(sql, args).fetchall()

    def execute(self, sql, args=()):
        with sqlite3.connect(self.db) as db:
            db.execute(sql, args)

    def source(self, suffix="1", mode="implement"):
        remote = "rtask_20261010T010101Z_" + f"{int(suffix):08x}"
        payload = {"repo": "sample", "mode": mode, "objective": "Inspect, edit, test and commit a synthetic change."}
        cmd = {"command_id": "cmd_" + suffix, "op": "start", "remote_task_id": remote, "payload": payload}
        issued = int(time.time() * 1000)
        scope = {"job_class": "implement" if mode == "implement" else "research",
                 "secrets": "default" if mode == "implement" else "grant",
                 "git": "push-own-branch" if mode == "implement" else "none",
                 "writes": ["src/**"] if mode == "implement" else [], "net_read": ["docs.example.com"]}
        claims = {"version": 1, "source": "oauth_task_delegation", "command_id": cmd["command_id"],
                  "op": cmd["op"], "remote_task_id": remote, "requester_actor": "user@example.com",
                  "requester_client": "connected-client", "scope": "herdr:task.implement" if mode == "implement" else "herdr:task.start",
                  "repo": "sample", "mode": mode, "effective_scope": scope,
                  "payload_sha256": hashlib.sha256(canonical(payload).encode()).hexdigest(),
                  "issued_at": issued, "expires_at": issued + 900000}
        return cmd, claims

    def accept(self, suffix="1", mode="implement"):
        cmd, claims = self.source(suffix, mode)
        row = json.loads(self.call("accept", canonical(cmd), canonical(claims)).stdout)
        return cmd, claims, row

    def task(self, suffix="1", mode="implement"):
        manifest = {"git": "push-own-branch" if mode == "implement" else "none", "net_write": "none",
                    "writes": ["src/**"] if mode == "implement" else [], "net_read": ["docs.example.com"]}
        if mode == "research":
            manifest["handoffs_write"] = "ANSWER.md"
        return {"task_id": "task_" + suffix, "run_id": "run_" + suffix, "worker_id": "worker_" + suffix,
                "conductor_id": "Main", "conductor_pane_id": "w72:p1", "conductor_pane_birth": "main-birth",
                "pane_id": "w2:p" + suffix, "pane_birth": "worker-birth-" + suffix,
                "repo": str(self.base / "sample"), "worktree": str(self.base / ("wt-" + suffix)),
                "branch": "worker/" + suffix, "trunk": "main", "project": "sample", "label": "synthetic",
                "manifest": canonical(manifest), "approval": "menu"}

    def bind(self, suffix="1", mode="implement"):
        cmd, claims, row = self.accept(suffix, mode)
        task = self.task(suffix, mode)
        self.call("register", canonical(task), cmd["command_id"])
        return cmd, claims, task

    def launch(self, suffix="1", mode="implement"):
        cmd, claims, task = self.bind(suffix, mode)
        self.call("launch", cmd["command_id"], task["task_id"], task["run_id"], "launch_claimed")
        self.call("launch", cmd["command_id"], task["task_id"], task["run_id"], "launched")
        return cmd, claims, task

    def concurrent(self, invocations):
        # Barrier releases distinct child processes together. Keep a real SQLite
        # writer lock until all processes have started, so this exercises BUSY
        # waiting and transaction serialization, not a sequential Python loop.
        gate = threading.Barrier(len(invocations) + 1)
        lock = sqlite3.connect(self.db)
        lock.execute("BEGIN IMMEDIATE")
        def run(args):
            p = subprocess.Popen([sys.executable, str(HELPER), str(self.db), *args],
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            gate.wait(timeout=10)
            out, err = p.communicate(timeout=20)
            return p.returncode, out, err
        with ThreadPoolExecutor(max_workers=len(invocations)) as pool:
            futures = [pool.submit(run, args) for args in invocations]
            gate.wait(timeout=10)
            lock.rollback()
            lock.close()
            return [f.result() for f in futures]

    def test_migration_preserves_legacy_hold_and_history(self):
        task = self.task()
        self.call("register", canonical(task))
        history = self.query("SELECT type,payload FROM events ORDER BY sequence")
        self.execute("DROP TABLE task_authorizations")
        self.execute("UPDATE schema_meta SET value='10' WHERE key='schema_version'")
        self.sh("registry_init")
        self.assertEqual(self.query("SELECT value FROM schema_meta WHERE key='schema_version'"), [("11",)])
        self.assertEqual(self.query("SELECT type,payload FROM events ORDER BY sequence"), history)
        self.call("check", canonical(task), ok=False, reason="missing verified task source")
        self.assertEqual(self.query("SELECT COUNT(*) FROM task_authorizations"), [(0,)])
        self.assertNotIn("manifest_approved", [r[0] for r in history])
        self.assertNotIn("approved_by", canonical(history))
        backups = list(self.db.parent.glob("registry.sqlite3.*.v11.bak"))
        self.assertEqual(len(backups), 1)
        with sqlite3.connect(backups[0]) as old:
            self.assertEqual(old.execute("PRAGMA integrity_check").fetchone(), ("ok",))
            self.assertEqual(old.execute("SELECT value FROM schema_meta WHERE key='schema_version'").fetchone(), ("10",))
            self.assertEqual(old.execute("SELECT COUNT(*) FROM tasks").fetchone(), (1,))

    def test_migration_backup_failure_stops_before_schema_and_stamp(self):
        self.execute("DROP TABLE task_authorizations")
        self.execute("UPDATE schema_meta SET value='10' WHERE key='schema_version'")
        p = self.sh('_backup_registry_before_migration() { return 1; }; registry_init; rc=$?; printf "ready=%s\\n" "$_HERDR_REGISTRY_READY"; exit "$rc"', ok=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("ready=0", p.stdout)
        self.assertEqual(self.query("SELECT value FROM schema_meta WHERE key='schema_version'"), [("10",)])
        self.assertEqual(self.query("SELECT name FROM sqlite_master WHERE name='task_authorizations'"), [])

    def test_remote_source_is_not_main_approval(self):
        cmd, claims, task = self.launch()
        self.call("check", canonical(task))
        events = self.query("SELECT type,payload FROM events ORDER BY sequence")
        bound = json.loads(next(p for t, p in events if t == "task_authorization_bound"))
        self.assertEqual(bound["requester_actor"], "user@example.com")
        self.assertEqual(bound["assigned_supervisor"], "Main")
        self.assertNotIn("approved_by", canonical(events))
        read = json.loads(self.sh('read_task "$1" "$2"', task["run_id"], task["task_id"]).stdout)
        self.assertEqual(read["authorization_command_id"], cmd["command_id"])
        self.assertEqual(read["authorization_status"], "launched")

    def test_research_manifest_is_exact_and_restrictions_required(self):
        cmd, _, _ = self.accept(mode="research")
        task = self.task(mode="research")
        bad = {**task, "manifest": canonical({**json.loads(task["manifest"]), "handoffs_write": "*"})}
        self.call("register", canonical(bad), cmd["command_id"], ok=False, reason="repository/manifest differs")
        self.call("register", canonical(task), cmd["command_id"])

    def test_schema_source_expiry_entitlement_and_changed_command_refused(self):
        cmd, claims = self.source()
        variations = [({**claims, "version": 2}, "schema/source"),
                      ({**claims, "source": "inbox"}, "schema/source"),
                      ({**claims, "expires_at": int(time.time() * 1000) - 100}, "validity window"),
                      ({**claims, "scope": "herdr:task.start"}, "entitlement/mode"),
                      ({**claims, "remote_task_id": "rtask_20261010T010101Z_deadbeef"}, "source binding mismatch")]
        for candidate, reason in variations:
            with self.subTest(reason=reason):
                self.call("accept", canonical(cmd), canonical(candidate), ok=False, reason=reason)
        changed = {**cmd, "payload": {**cmd["payload"], "objective": "push another branch"}}
        self.call("accept", canonical(changed), canonical(claims), ok=False, reason="changed command payload")
        self.assertEqual(self.query("SELECT COUNT(*) FROM task_authorizations"), [(0,)])

    def test_accept_retry_conflict_remote_uniqueness(self):
        cmd, claims, first = self.accept()
        again = json.loads(self.call("accept", canonical(cmd), canonical(claims)).stdout)
        self.assertTrue(first["newly_accepted"])
        self.assertFalse(again["newly_accepted"])
        self.assertEqual(first["source_sha256"], again["source_sha256"])
        self.call("accept", canonical(cmd), canonical({**claims, "requester_actor": "forged@example.com"}),
                  ok=False, reason="different immutable source")
        second_cmd, second_claims = self.source("2")
        second_cmd["remote_task_id"] = cmd["remote_task_id"]
        second_claims["remote_task_id"] = cmd["remote_task_id"]
        self.call("accept", canonical(second_cmd), canonical(second_claims), ok=False, reason="UNIQUE constraint")

    def test_concurrent_accept_has_one_new_receipt(self):
        cmd, claims = self.source()
        outcomes = self.concurrent([("accept", canonical(cmd), canonical(claims))] * 8)
        self.assertTrue(all(rc == 0 for rc, _, _ in outcomes), outcomes)
        self.assertEqual(sum(json.loads(out)["newly_accepted"] for _, out, _ in outcomes), 1)
        self.assertEqual(self.query("SELECT COUNT(*) FROM task_authorizations"), [(1,)])

    def test_concurrent_binding_and_launch_each_have_one_winner(self):
        cmd, _, _ = self.accept()
        tasks = [self.task(str(i)) for i in range(1, 9)]
        outcomes = self.concurrent([("register", canonical(task), cmd["command_id"]) for task in tasks])
        self.assertEqual(sum(rc == 0 for rc, _, _ in outcomes), 1, outcomes)
        for rc, _, err in outcomes:
            if rc:
                self.assertIn("receipt missing or already bound", err)
        winner = json.loads(self.call("read", cmd["command_id"]).stdout)
        self.assertEqual(self.query("SELECT COUNT(*) FROM tasks"), [(1,)])
        self.assertEqual(self.query("SELECT COUNT(*) FROM events WHERE type='task_authorization_bound'"), [(1,)])
        for status in ("launch_claimed", "launched"):
            args = ("launch", cmd["command_id"], winner["task_id"], winner["run_id"], status)
            outcomes = self.concurrent([args] * 8)
            self.assertEqual(sum(rc == 0 for rc, _, _ in outcomes), 1, outcomes)
            for rc, _, err in outcomes:
                if rc:
                    self.assertIn("launch claim already consumed", err)

    def test_distinct_concurrent_jobs_cannot_exchange_receipts(self):
        sources = [self.source(str(i)) for i in range(1, 9)]
        outcomes = self.concurrent([("accept", canonical(c), canonical(s)) for c, s in sources])
        self.assertTrue(all(rc == 0 for rc, _, _ in outcomes), outcomes)
        tasks = [self.task(str(i)) for i in range(1, 9)]
        outcomes = self.concurrent([("register", canonical(t), c["command_id"]) for t, (c, _) in zip(tasks, sources)])
        self.assertTrue(all(rc == 0 for rc, _, _ in outcomes), outcomes)
        self.call("launch", sources[0][0]["command_id"], tasks[1]["task_id"], tasks[1]["run_id"],
                  "launch_claimed", ok=False, reason="task binding mismatch")

    def test_binding_and_events_roll_back_together(self):
        cmd, _, _ = self.accept()
        self.execute("CREATE TRIGGER reject_fixture_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'fixture event failure'); END")
        self.call("register", canonical(self.task()), cmd["command_id"], ok=False, reason="fixture event failure")
        self.assertEqual(self.query("SELECT COUNT(*) FROM tasks"), [(0,)])
        self.assertEqual(self.query("SELECT status,task_id FROM task_authorizations"), [("accepted", None)])

    def test_task_binding_wrong_pane_manifest_and_mutable_json_refused(self):
        _, _, task = self.launch()
        for key in ("task_id", "run_id", "worker_id", "repo", "worktree", "branch", "trunk", "approval", "pane_id", "pane_birth"):
            with self.subTest(key=key):
                self.call("check", canonical({**task, key: "forged"}), ok=False,
                          reason="missing verified task source" if key == "task_id" else key + " binding mismatch")
        self.call("check", canonical({**task, "manifest": "{}"}), ok=False, reason="manifest binding mismatch")
        self.execute("UPDATE tasks SET pane_birth='recycled' WHERE task_id=?", (task["task_id"],))
        self.call("check", canonical(task), ok=False, reason="pane_birth binding mismatch")

    def test_handover_preserves_source_with_real_competing_processes(self):
        cmd, _, task = self.launch()
        before = json.loads(self.call("read", cmd["command_id"]).stdout)
        code = 'source "$1/lib/run-registry.sh"; set_task_conductor run_1 task_1 w72:p1 main-birth "$2" "$3" "$4" fixture'
        processes = [subprocess.Popen(["bash", "-c", code, "fixture", str(ROOT), f"w9:p{i}", f"birth{i}", f"conductor{i}"],
                                      env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for i in (1, 2)]
        outputs = [p.communicate(timeout=20) for p in processes]
        self.assertEqual(sum(p.returncode == 0 for p in processes), 1, outputs)
        for p, (_, err) in zip(processes, outputs):
            if p.returncode:
                self.assertIn("CAS miss", err)
        after = json.loads(self.call("read", cmd["command_id"]).stdout)
        self.assertEqual(before, after)
        self.call("check", canonical(task))
        self.assertEqual(self.query("SELECT COUNT(*) FROM events WHERE type='conductor_handover'"), [(1,)])

    def test_crash_windows_never_claim_a_second_launch(self):
        cmd, claims, task = self.bind()
        self.call("check", canonical(task), ok=False, reason="no protected claim")
        self.call("launch", cmd["command_id"], task["task_id"], task["run_id"], "launch_claimed")
        reread = json.loads(self.call("accept", canonical(cmd), canonical(claims)).stdout)
        self.assertEqual(reread["status"], "launch_claimed")
        self.assertFalse(reread["newly_accepted"])
        self.call("launch", cmd["command_id"], task["task_id"], task["run_id"], "launch_claimed", ok=False, reason="already consumed")
        self.call("register", canonical(self.task("2")), cmd["command_id"], ok=False, reason="already bound")
        self.call("launch", cmd["command_id"], task["task_id"], task["run_id"], "launched")
        reread = json.loads(self.call("accept", canonical(cmd), canonical(claims)).stdout)
        self.assertEqual(reread["status"], "launched")
        self.assertEqual(reread["task_id"], task["task_id"])

    def test_delivery_expiry_does_not_expire_running_task(self):
        cmd, claims, task = self.launch()
        claims["issued_at"] -= 1800000
        claims["expires_at"] -= 1800000
        raw = canonical(claims)
        self.execute("UPDATE task_authorizations SET claims=?,source_sha256=?,issued_at=?,expires_at=?",
                     (raw, hashlib.sha256(raw.encode()).hexdigest(), claims["issued_at"], claims["expires_at"]))
        self.call("check", canonical(task))
        self.call("accept", canonical(cmd), raw, ok=False, reason="validity window")

    def test_expired_source_cannot_bind_or_launch(self):
        cmd, claims, _ = self.accept()
        claims["issued_at"] -= 1800000
        claims["expires_at"] -= 1800000
        raw = canonical(claims)
        self.execute("UPDATE task_authorizations SET claims=?,source_sha256=?,issued_at=?,expires_at=?",
                     (raw, hashlib.sha256(raw.encode()).hexdigest(), claims["issued_at"], claims["expires_at"]))
        self.call("register", canonical(self.task()), cmd["command_id"], ok=False, reason="validity window")

    def test_source_integrity_and_absence_fail_closed(self):
        cmd, claims, task = self.launch()
        self.execute("UPDATE task_authorizations SET source_sha256='forged'")
        self.call("check", canonical(task), ok=False, reason="source receipt integrity mismatch")
        self.call("read", cmd["command_id"], ok=False, reason="source receipt integrity mismatch")
        self.call("accept", canonical(cmd), canonical(claims), ok=False, reason="different immutable source")
        self.execute("DELETE FROM task_authorizations")
        self.call("check", canonical(task), ok=False, reason="missing verified task source")
        p = self.sh('task_authorization_check "$1"; rc=$?; printf "%s\\n" "$TASK_AUTHORIZATION_REASON"; exit "$rc"', canonical(task), ok=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("authorization hold: missing verified task source", p.stdout)

    def test_retry_ack_checks_binding_and_permits_terminal_history_only(self):
        cmd, claims, task = self.launch()
        self.execute("UPDATE tasks SET branch='wrong-branch'")
        self.call("read", cmd["command_id"], ok=False, reason="branch binding mismatch")
        self.call("accept", canonical(cmd), canonical(claims), ok=False, reason="branch binding mismatch")
        self.execute("UPDATE tasks SET branch=?,state='completed'", (task["branch"],))
        row = json.loads(self.call("read", cmd["command_id"]).stdout)
        self.assertEqual(row["status"], "launched")
        self.assertFalse(json.loads(self.call("accept", canonical(cmd), canonical(claims)).stdout)["newly_accepted"])
        self.call("check", canonical(task), ok=False, reason="no longer active")
        self.call("launch", cmd["command_id"], task["task_id"], task["run_id"], "launch_claimed", ok=False, reason="already consumed")

    def test_local_source_concurrent_retry_and_changed_actor(self):
        task = self.task()
        args = ("accept-local", "local1", "w1:p1", "local-birth", task["repo"], task["manifest"])
        outcomes = self.concurrent([args] * 8)
        self.assertTrue(all(rc == 0 for rc, _, _ in outcomes), outcomes)
        self.assertEqual(sum(json.loads(out)["newly_accepted"] for _, out, _ in outcomes), 1)
        self.call("accept-local", "local1", "w1:p1", "different-birth", task["repo"], task["manifest"],
                  ok=False, reason="different source")
        self.call("register", canonical(task), "local1")
        self.call("launch", "local1", task["task_id"], task["run_id"], "launch_claimed")
        self.call("check", canonical(task))

    def test_deadline_bound_before_launch_and_retry_does_not_extend_it(self):
        cmd, claims = self.source()
        deadline = "2099-01-01T00:00:00Z"
        self.call("accept", canonical(cmd), canonical(claims), deadline)
        self.call("accept", canonical(cmd), canonical(claims), "2099-02-01T00:00:00Z")
        self.call("register", canonical(self.task()), cmd["command_id"])
        self.assertEqual(self.query("SELECT deadline_at FROM tasks"), [(deadline,)])
        self.assertEqual(self.query("SELECT deadline_at FROM task_authorizations"), [(deadline,)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
