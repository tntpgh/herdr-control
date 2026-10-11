#!/usr/bin/env python3
"""Deterministic action/receipt races against isolated real SQLite connections."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


storage = load("authorization_transaction_fixture", ROOT / "lib/task-authorization.py")
fixtures = load("registry_transaction_fixture", ROOT / "verify-task-authorization.py")


class ActionTransactionTests(unittest.TestCase):
    def setUp(self):
        self.fx = fixtures.RegistryAuthorization("test_remote_source_is_not_main_approval")
        self.fx.setUp()
        self.fx.execute = self.execute
        self.fx.query = self.query
        self.task = self.fx.task()
        self.fx.call("accept-local", "local-action-source", "w1:p1", "source-birth", self.task["repo"], self.task["manifest"])
        self.fx.call("register", fixtures.canonical(self.task), "local-action-source")
        for status in ("launch_claimed", "launched"):
            self.fx.call("launch", "local-action-source", self.task["task_id"], self.task["run_id"], status)
        self.executions = 0
        self.reset_request()

    def tearDown(self):
        self.fx.tearDown()

    def execute(self, sql, args=()):
        with closing(sqlite3.connect(self.fx.db)) as db, db:
            db.execute(sql, args)

    def query(self, sql, args=()):
        with closing(sqlite3.connect(self.fx.db)) as db:
            return db.execute(sql, args).fetchall()

    def reset_request(self, status="approved", grant="once", route="conductor"):
        self.fx.execute("DELETE FROM action_requests")
        with closing(sqlite3.connect(self.fx.db)) as db, db:
            db.execute("""INSERT INTO action_requests
                (request_id,run_id,task_id,tool,action_sha256,command,route,grant_kind,status,created_at,
                 authority,decided_by,code_path,code_sha256)
                VALUES ('request-1',?,?, 'bash','action-hash','synthetic fixture',?,?,?,
                        '2026-10-10T01:01:01Z','conductor','w72:p1','/synthetic/script.sh','code-hash')""",
                       (self.task["run_id"], self.task["task_id"], route, grant, status))
            db.row_factory = sqlite3.Row
            self.reviewed_request = dict(db.execute("SELECT * FROM action_requests WHERE request_id='request-1'").fetchone())

    def mutate(self, operation, trace=None):
        with closing(storage.connect(str(self.fx.db))) as db, db:
            if trace:
                db.set_trace_callback(trace)
            if operation == "consume":
                result = storage.action_consume(db, "request-1", self.task["run_id"], self.task["task_id"],
                                                "bash", "action-hash", "conductor")
                # A fixture counter represents the caller's execution branch;
                # no actual tool command or external transport is invoked.
                if result["changed"]:
                    self.executions += 1
                return result
            return storage.action_decide(db, "request-1", "approved", "conductor", "w72:p1",
                                         "local-build", "fixture", fixtures.canonical(self.reviewed_request), "main-birth")

    def assert_held(self, result, initial):
        self.assertEqual(result["changed"], False)
        self.assertEqual(result["hold"], True)
        self.assertTrue(result["reason"].startswith("authorization hold: "), result)
        self.assertEqual(self.fx.query("SELECT status FROM action_requests"), [(initial,)])
        self.assertEqual(self.executions, 0)

    def invalidation_precedes_lock(self, operation, invalidation):
        initial = "approved" if operation == "consume" else "pending"
        self.reset_request(initial)
        # Demonstrate that a successful earlier preflight is not reused.
        with closing(storage.connect(str(self.fx.db))) as snapshot, snapshot:
            storage.check(snapshot, fixtures.canonical(self.task))
        writer = sqlite3.connect(self.fx.db)
        writer.execute("BEGIN IMMEDIATE")
        writer.execute(invalidation)
        attempted_lock = threading.Event()
        def trace(statement):
            if statement == "BEGIN IMMEDIATE":
                attempted_lock.set()
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(self.mutate, operation, trace)
            self.assertTrue(attempted_lock.wait(5), "mutation did not attempt writer lock")
            writer.commit()
            writer.close()
            result = future.result(timeout=10)
        self.assert_held(result, initial)

    def test_receipt_deleted_before_consume_acquires_lock(self):
        self.invalidation_precedes_lock("consume", "DELETE FROM task_authorizations")

    def test_receipt_deleted_before_approve_acquires_lock(self):
        self.invalidation_precedes_lock("approve", "DELETE FROM task_authorizations")

    def test_task_ends_before_consume_acquires_lock(self):
        self.invalidation_precedes_lock("consume", "UPDATE tasks SET state='completed'")

    def test_task_ends_before_approve_acquires_lock(self):
        self.invalidation_precedes_lock("approve", "UPDATE tasks SET state='completed'")

    def invalidator_cannot_interleave(self, operation):
        self.reset_request("approved" if operation == "consume" else "pending")
        validated = threading.Event()
        release = threading.Event()
        original = storage._action_task
        def pause_after_validation(db, request):
            task = original(db, request)
            self.assertTrue(db.in_transaction)
            validated.set()
            self.assertTrue(release.wait(5), "test failed to release validated transaction")
            return task
        with patch.object(storage, "_action_task", pause_after_validation):
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(self.mutate, operation)
                self.assertTrue(validated.wait(5), "mutation did not validate source")
                try:
                    with closing(sqlite3.connect(self.fx.db, timeout=0)) as invalidator, invalidator:
                        with self.assertRaises(sqlite3.OperationalError) as caught:
                            invalidator.execute("DELETE FROM task_authorizations")
                        self.assertEqual(caught.exception.sqlite_errorcode & 255, sqlite3.SQLITE_BUSY)
                finally:
                    release.set()
                result = future.result(timeout=10)
        self.assertTrue(result["changed"], result)
        self.fx.execute("DELETE FROM task_authorizations")
        # Once invalidation commits, even an old snapshot cannot consume again.
        prior_executions = self.executions
        later = self.mutate("consume")
        self.assertFalse(later["changed"])
        self.assertTrue(later["hold"])
        self.assertEqual(self.executions, prior_executions)

    def test_invalidator_cannot_commit_between_validation_and_consume(self):
        self.invalidator_cannot_interleave("consume")

    def test_invalidator_cannot_commit_between_validation_and_approve(self):
        self.invalidator_cannot_interleave("approve")

    def test_competing_consumers_change_and_execute_once(self):
        barrier = threading.Barrier(2)
        def consume():
            barrier.wait(timeout=5)
            return self.mutate("consume")
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(lambda _: consume(), range(2)))
        self.assertEqual(sum(r["changed"] for r in outcomes), 1)
        self.assertEqual(self.executions, 1)

    def test_action_snapshot_and_route_checked_in_transaction(self):
        for args, why in ((["wrong-run", "task_1", "bash", "action-hash", "conductor"], "snapshot"),
                          (["run_1", "wrong-task", "bash", "action-hash", "conductor"], "snapshot"),
                          (["run_1", "task_1", "write", "action-hash", "conductor"], "snapshot"),
                          (["run_1", "task_1", "bash", "changed-hash", "conductor"], "snapshot"),
                          (["run_1", "task_1", "bash", "action-hash", "human"], "authority")):
            with self.subTest(args=args), closing(storage.connect(str(self.fx.db))) as db, db:
                result = storage.action_consume(db, "request-1", *args)
                self.assert_held(result, "approved")
                self.assertIn(why, result["reason"])

    def test_approval_rechecks_current_conductor_birth(self):
        self.reset_request("pending")
        self.fx.execute("UPDATE tasks SET conductor_pane_birth='new-pane-birth'")
        result = self.mutate("approve")
        self.assert_held(result, "pending")
        self.assertIn("pane/birth changed", result["reason"])

    def test_approval_binds_reviewed_request_fields(self):
        for field in ("run_id", "task_id", "tool", "action_sha256", "route", "grant_kind", "code_path", "code_sha256", "command", "verdict"):
            with self.subTest(field=field):
                self.reset_request("pending")
                self.fx.execute("UPDATE action_requests SET " + field + "='changed-after-review'")
                result = self.mutate("approve")
                self.assert_held(result, "pending")
                self.assertIn("snapshot binding mismatch", result["reason"])

    def test_approved_task_action_survives_supervisor_handover(self):
        self.fx.execute("UPDATE tasks SET conductor_pane_id='w9:p9',conductor_pane_birth='new-supervisor'")
        self.assertTrue(self.mutate("consume")["changed"])

    def test_file_grant_and_decision_commit_together(self):
        self.reset_request("pending", "file")
        self.fx.execute("CREATE TRIGGER fixture_decision_failure BEFORE UPDATE ON action_requests BEGIN SELECT RAISE(ABORT,'fixture decision failure'); END")
        result = self.mutate("approve")
        self.assert_held(result, "pending")
        self.assertEqual(self.fx.query("SELECT COUNT(*) FROM file_approvals"), [(0,)])
        self.fx.execute("DROP TRIGGER fixture_decision_failure")
        self.assertTrue(self.mutate("approve")["changed"])
        self.assertEqual(self.fx.query("SELECT status FROM action_requests"), [("approved",)])
        self.assertEqual(self.fx.query("SELECT COUNT(*) FROM file_approvals"), [(1,)])

    def test_decline_and_supersede_remain_available_without_source(self):
        self.fx.execute("DELETE FROM task_authorizations")
        self.fx.execute("UPDATE tasks SET state='completed'")
        for status in ("declined", "superseded"):
            self.reset_request("pending")
            with closing(storage.connect(str(self.fx.db))) as db, db:
                result = storage.action_decide(db, "request-1", status, "human", "fixture-person", "", "fixture",
                                              fixtures.canonical(self.reviewed_request), "")
            self.assertTrue(result["changed"], result)
            self.assertEqual(self.fx.query("SELECT status FROM action_requests"), [(status,)])

    def test_cli_returns_structured_refusal(self):
        self.fx.execute("DELETE FROM task_authorizations")
        proc = subprocess.run([sys.executable, str(ROOT / "lib/task-authorization.py"), str(self.fx.db),
                               "action-consume", "request-1", "run_1", "task_1", "bash", "action-hash", "conductor"],
                              text=True, capture_output=True)
        self.assertEqual(proc.returncode, 1)
        self.assert_held(json.loads(proc.stdout), "approved")


if __name__ == "__main__":
    unittest.main(verbosity=2)
