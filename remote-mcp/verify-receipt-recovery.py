#!/usr/bin/env python3
"""Receipt-to-ack recovery (dot-herdr-recovery-slices.md §3) -- the one hop
NOT covered by verify-task-authorization.py (lib/task-authorization.py's CLI
directly) or authorization-offline.cjs (tasks.py's _receipt_ack against a
real registry, but never pending_receipt_acks()/confirm_receipt_ack()): does
remote-mcp/tasks.py's new recovery pair round-trip correctly through the
REAL remote-mcp/registry-bridge.sh -> lib/run-registry.sh ->
lib/task-authorization.py chain, against a real temporary sqlite registry?

No FAKE_BRIDGE here (contrast verify-tasks.py) -- `tsk.REGISTRY_BRIDGE` is
left pointed at the genuine registry-bridge.sh in this directory. Only the
registry location (HERDR_RUN_STATE_DIR) is a scratch temp dir.

    python3 verify-receipt-recovery.py
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
HELPER = ROOT / "lib/task-authorization.py"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class ReceiptAckRecovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="herdr-receipt-recovery-")
        self.base = Path(self.temp.name)
        self.env = {**os.environ, "HERDR_RUN_STATE_DIR": str(self.base)}
        self.db = self.base / "registry.sqlite3"
        self.sh("registry_init")
        # _bridge() (tasks.py) takes no explicit env -- it inherits whatever
        # this PROCESS's os.environ is at call time, same as the real
        # publisher. HERDR_RUN_STATE_DIR must stay set for the whole test,
        # not just module import, and be restored after so other test
        # modules in the same run never see this scratch dir.
        self._prior_run_state_dir = os.environ.get("HERDR_RUN_STATE_DIR")
        os.environ["HERDR_RUN_STATE_DIR"] = str(self.base)
        spec = importlib.util.spec_from_file_location("tasks_under_recovery_test", HERE / "tasks.py")
        self.tsk = importlib.util.module_from_spec(spec)
        sys.modules["tasks_under_recovery_test"] = self.tsk
        spec.loader.exec_module(self.tsk)
        self.tsk.REGISTRY = self.db  # exec_module already resolved REGISTRY_BRIDGE to the real script

    def tearDown(self):
        if self._prior_run_state_dir is None:
            os.environ.pop("HERDR_RUN_STATE_DIR", None)
        else:
            os.environ["HERDR_RUN_STATE_DIR"] = self._prior_run_state_dir
        self.temp.cleanup()

    def sh(self, code, *args):
        p = subprocess.run(["bash", "-c", 'source "$1/lib/run-registry.sh"; shift; ' + code,
                            "fixture", str(ROOT), *args], env=self.env, text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def call(self, op, *args):
        p = subprocess.run([sys.executable, str(HELPER), str(self.db), op, *args],
                           text=True, capture_output=True, env=self.env)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def source(self, suffix="1"):
        remote = "rtask_20261010T010101Z_" + f"{int(suffix):08x}"
        payload = {"repo": "sample", "mode": "implement", "objective": "Inspect, edit, test and commit a synthetic change."}
        cmd = {"command_id": "cmd_" + suffix, "op": "start", "remote_task_id": remote, "payload": payload}
        issued = int(time.time() * 1000)
        scope = {"job_class": "implement", "secrets": "default", "git": "push-own-branch",
                 "writes": ["src/**"], "net_read": ["docs.example.com"]}
        claims = {"version": 1, "source": "oauth_task_delegation", "command_id": cmd["command_id"],
                  "op": cmd["op"], "remote_task_id": remote, "requester_actor": "user@example.com",
                  "requester_client": "connected-client", "scope": "herdr:task.implement",
                  "repo": "sample", "mode": "implement", "effective_scope": scope,
                  "payload_sha256": hashlib.sha256(canonical(payload).encode()).hexdigest(),
                  "issued_at": issued, "expires_at": issued + 900000}
        return cmd, claims

    def accept(self, suffix="1"):
        cmd, claims = self.source(suffix)
        self.call("accept", canonical(cmd), canonical(claims))
        return cmd

    def test_pending_receipt_acks_recovers_a_registry_only_hold_through_the_real_bridge(self):
        """No local JSON cache exists anywhere in this fixture -- proves the
        exact recovery this slice exists for: pending_receipt_acks() alone,
        through the real chain, rebuilds an ack the publisher's cache lost."""
        cmd = self.accept()
        cid = cmd["command_id"]
        acks = self.tsk.pending_receipt_acks()
        mine = next(a for a in acks if a["command_id"] == cid)
        self.assertEqual(mine["outcome"], "held")
        self.assertEqual(mine["revision"], 1)
        self.assertIn("outcome_unknown", mine["detail"])
        self.assertNotIn("local_task_id", mine)  # never invented without a real binding

    def test_confirm_receipt_ack_round_trips_recorded_and_already_recorded(self):
        cid = self.accept()["command_id"]
        first = self.tsk.confirm_receipt_ack(cid, 1)
        self.assertEqual(first["result"], "recorded")
        second = self.tsk.confirm_receipt_ack(cid, 1)
        self.assertEqual(second["result"], "already_recorded")
        self.assertNotIn(cid, [a["command_id"] for a in self.tsk.pending_receipt_acks()])

    def test_confirm_receipt_ack_reports_conflict_never_silently_recorded(self):
        cmd = self.accept()
        cid = cmd["command_id"]
        task = {"task_id": "task_1", "run_id": "run_1", "worker_id": "worker_1",
                "conductor_id": "Main", "conductor_pane_id": "w72:p1", "conductor_pane_birth": "main-birth",
                "pane_id": "w2:p1", "pane_birth": "worker-birth-1",
                "repo": str(self.base / "sample"), "worktree": str(self.base / "wt-1"),
                "branch": "remote/00000001", "trunk": "main", "project": "sample", "label": "synthetic",
                "manifest": canonical({"git": "push-own-branch", "net_write": "none", "writes": ["src/**"],
                                        "net_read": ["docs.example.com"]}), "approval": "menu"}
        helper = ROOT / "lib/task-reservation.py"
        for op, args in (("reserve", (canonical(cmd), task["repo"], task["worktree"], task["branch"])),
                         ("claim-mutation", (cid, task["repo"], task["worktree"], task["branch"]))):
            proc = subprocess.run([sys.executable, str(helper), str(self.db), op, *args],
                                  text=True, capture_output=True, env=self.env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
        self.call("register", canonical(task), cid)  # revision now 2 (bound)
        stale = self.tsk.confirm_receipt_ack(cid, 1)
        self.assertEqual(stale["result"], "conflict")
        self.assertEqual(stale["current_revision"], 2)
        current = self.tsk.confirm_receipt_ack(cid, 2)
        self.assertEqual(current["result"], "recorded")

    def test_confirm_receipt_ack_unknown_command_never_raises(self):
        result = self.tsk.confirm_receipt_ack("cmd_never_existed", 1)
        self.assertEqual(result["result"], "unknown")

    def test_pending_receipt_acks_is_empty_once_nothing_is_outstanding(self):
        self.assertEqual(self.tsk.pending_receipt_acks(), [])
        self.accept()
        self.assertEqual(len(self.tsk.pending_receipt_acks()), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
