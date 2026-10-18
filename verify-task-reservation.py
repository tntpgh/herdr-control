#!/usr/bin/env python3
"""Pure SQLite reservation fixtures; no subprocesses, sockets or worker launch.

The production source-admission, reservation, registration and launch-state
APIs run against a disposable database. Launch counters below are simulated
effects only and are not evidence of a permitted live canary.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import copy
import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "remote-mcp"))
from authorization import verify_command


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


AUTH = module("reservation_fixture_authorization", ROOT / "lib/task-authorization.py")
RES = module("reservation_fixture_reservation", ROOT / "lib/task-reservation.py")
KEY = "reservation-fixture-key-not-a-real-secret-32"
SCOPE = {"job_class": "implement", "secrets": "default", "git": "push-own-branch", "writes": [], "net_read": []}
ALLOWLIST = {"repos": ["sample"], "modes": {"implement": SCOPE}}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


class WorktreeReservations(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="herdr-reservation-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base / "sample"
        self.repo.mkdir()
        self.path = self.base / "registry.sqlite3"
        self.db = AUTH.connect(str(self.path))
        self.addCleanup(self.db.close)
        self.db.execute("CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT)")
        columns = ("run_id", "worker_id", "conductor_id", "conductor_pane_id", "conductor_pane_birth", "pane_id",
                   "pane_birth", "repo", "worktree", "branch", "trunk", "project", "manifest", "approval", "label",
                   "state", "created_at", "updated_at", "remote_task_id", "deadline_at", "agent_session")
        self.db.execute("CREATE TABLE tasks (task_id TEXT PRIMARY KEY," +
                        ",".join(name + " TEXT NOT NULL DEFAULT ''" for name in columns) + ")")
        self.db.execute("CREATE TABLE events (event_id TEXT PRIMARY KEY, run_id TEXT, task_id TEXT, type TEXT, occurred_at TEXT, payload TEXT)")
        # Real registry schema v10 `roles` (lib/run-registry.sh): register()'s
        # orchestrator cap reads it and deliberately fails closed without it.
        self.db.execute("CREATE TABLE roles (label TEXT PRIMARY KEY, pane_id TEXT NOT NULL,"
                        " pane_birth TEXT NOT NULL DEFAULT '', agent_session TEXT NOT NULL DEFAULT '',"
                        " workspace TEXT NOT NULL DEFAULT '', registered_at TEXT NOT NULL, updated_at TEXT NOT NULL)")
        self.db.commit()
        AUTH.schema(self.db)
        AUTH.schema_v13(self.db)
        self.enterContext(mock.patch("subprocess.Popen", side_effect=AssertionError("subprocess forbidden in SQLite fixture")))
        self.enterContext(mock.patch("socket.socket", side_effect=AssertionError("socket forbidden in SQLite fixture")))

    def source(self, number, parent=None):
        remote_id = "rtask_20261010T000000Z_" + f"{number:08x}"
        payload = {"repo": "sample", "mode": "implement"}
        if parent:
            op, branch, wt = "resume", parent["branch"], Path(parent["worktree"])
            payload.update(local_task_id=parent["task_id"], local_run_id=parent["run_id"],
                           branch=branch, text="Continue the exact authorized task.")
        else:
            op, branch = "start", "remote/" + remote_id.rsplit("_", 1)[-1]
            wt = self.base / "worktrees" / "sample" / branch
            wt.mkdir(parents=True, exist_ok=True)
            payload["objective"] = "Inspect and edit fixture bytes; café 🧪."
        cmd = {"command_id": "cmd_" + str(number), "op": op, "remote_task_id": remote_id, "payload": payload}
        issued = int(time.time() * 1000)
        claims = {"version": 1, "source": "oauth_task_delegation", "command_id": cmd["command_id"], "op": op,
                  "remote_task_id": remote_id, "requester_actor": "fixture@example.com", "requester_client": "fixture-client",
                  "scope": "herdr:task.implement", "repo": "sample", "mode": "implement", "effective_scope": copy.deepcopy(SCOPE),
                  "payload_sha256": hashlib.sha256(canonical(payload).encode()).hexdigest(),
                  "issued_at": issued, "expires_at": issued + 900000}
        raw = canonical(claims)
        cmd["authorization"] = {"claims": raw, "signature": hmac.new(KEY.encode(), b"herdr-task-authorization-v1\n" + raw.encode(), hashlib.sha256).hexdigest()}
        verified = verify_command(cmd, KEY, ALLOWLIST)
        AUTH.accept(self.db, canonical(cmd), verified.claims)
        return {"cmd": cmd, "branch": branch, "wt": str(wt), "number": number}

    def stopped(self, task):
        return {key: task[key] for key in ("task_id", "run_id", "pane_id", "pane_birth", "agent_session")} | {"stopped": True}

    def reserve(self, source, parent=None, db=None, stopped=None, repo=None, wt=None, branch=None):
        return RES.reserve(self.db if db is None else db, canonical(source["cmd"]),
                           str(self.repo) if repo is None else repo, source["wt"] if wt is None else wt,
                           source["branch"] if branch is None else branch,
                           canonical(self.stopped(parent) if stopped is None and parent else stopped or {}))

    def claim(self, source, db=None):
        return RES.claim_mutation(self.db if db is None else db, source["cmd"]["command_id"],
                                  str(self.repo), source["wt"], source["branch"])

    def task(self, source):
        number = source["number"]
        return {"task_id": "task_" + str(number), "run_id": "run_" + str(number), "worker_id": "worker_" + str(number),
                "conductor_id": "Main", "conductor_pane_id": "w72:p1", "conductor_pane_birth": "main-birth",
                "pane_id": "fixture:p" + str(number), "pane_birth": "fixture-birth-" + str(number),
                "repo": str(self.repo), "worktree": source["wt"], "branch": source["branch"], "trunk": "main",
                "project": "sample", "label": "reservation fixture", "approval": "menu",
                "manifest": AUTH.expected_remote_manifest(SCOPE)}

    def bind(self, source):
        task = self.task(source)
        AUTH.register(self.db, canonical(task), source["cmd"]["command_id"])
        return dict(self.db.execute("SELECT * FROM tasks WHERE task_id=?", (task["task_id"],)).fetchone())

    def launch(self, source, task):
        AUTH.launch(self.db, source["cmd"]["command_id"], task["task_id"], task["run_id"], "launch_claimed")
        AUTH.launch(self.db, source["cmd"]["command_id"], task["task_id"], task["run_id"], "launched")

    def terminal(self, task, state="completed"):
        self.db.execute("UPDATE tasks SET state=? WHERE task_id=?", (state, task["task_id"]))
        self.db.commit()
        return dict(self.db.execute("SELECT * FROM tasks WHERE task_id=?", (task["task_id"],)).fetchone())

    def parent(self, number=1):
        source = self.source(number)
        self.reserve(source)
        self.claim(source)
        task = self.bind(source)
        self.launch(source, task)
        return source, self.terminal(task)

    def refused(self, fn, *args, reason=None, **kwargs):
        try:
            with self.assertRaises(ValueError) as raised:
                fn(*args, **kwargs)
            if reason:
                self.assertIn(reason, str(raised.exception))
            return str(raised.exception)
        finally:
            self.db.rollback()

    def validate(self, source, task=None, require_mutation=True):
        receipt = AUTH.read(self.db, source["cmd"]["command_id"])
        return RES.validate_reservation(self.db, receipt, self.task(source) if task is None else task, require_mutation=require_mutation)

    def test_start_reserves_exact_canonical_repo_worktree_branch(self):
        source = self.source(1)
        row = self.reserve(source)
        self.assertEqual((row["repo"], row["worktree"], row["branch"], row["command_id"]),
                         (str(self.repo), source["wt"], source["branch"], "cmd_1"))
        self.assertTrue(row["newly_reserved"])
        self.assertFalse(row["mutation_claimed"])
        self.validate(source, require_mutation=False)

    def test_mutation_claim_is_required_and_consumed_once(self):
        source = self.source(1)
        self.reserve(source)
        self.refused(self.validate, source)
        self.claim(source)
        self.validate(source)
        self.refused(self.claim, source)

    def test_missing_reservation_cannot_register_or_validate(self):
        source = self.source(1)
        self.refused(self.validate, source)
        self.refused(self.bind, source)
        self.assertEqual(self.db.execute("SELECT count(*) FROM tasks").fetchone()[0], 0)

    def test_identical_reservation_retry_does_not_restore_mutation_permission(self):
        source = self.source(1)
        self.reserve(source)
        self.claim(source)
        again = self.reserve(source)
        self.assertFalse(again["newly_reserved"])
        self.assertTrue(again["mutation_claimed"])
        self.refused(self.claim, source)

    def test_substituted_payload_cannot_reserve_an_accepted_receipt(self):
        source = self.source(1)
        source["cmd"]["payload"]["objective"] += " different work"
        self.refused(self.reserve, source)

    def test_missing_source_receipt_refuses_reservation(self):
        source = self.source(1)
        self.db.execute("DELETE FROM task_authorizations")
        self.db.commit()
        self.refused(self.reserve, source)

    def test_corrupted_protected_source_cannot_reserve(self):
        source = self.source(1)
        self.db.execute("UPDATE task_authorizations SET source_sha256=?", ("0" * 64,))
        self.db.commit()
        self.refused(self.reserve, source, reason="source receipt integrity mismatch")

    def test_local_source_does_not_enter_remote_reservation_path(self):
        source = self.source(1)
        source["cmd"]["command_id"] = "local_1"
        AUTH.accept_local(self.db, "local_1", "fixture:p1", "birth_1", str(self.repo), AUTH.expected_remote_manifest(SCOPE))
        self.refused(self.reserve, source, reason="missing authenticated remote source")

    def test_start_branch_must_match_remote_task_suffix(self):
        source = self.source(1)
        self.refused(self.reserve, source, branch="remote/00000002")

    def test_different_branches_cannot_claim_same_worktree(self):
        first, second = self.source(1), self.source(2)
        self.reserve(first)
        self.refused(self.reserve, second, wt=first["wt"])
        self.claim(first)
        self.validate(first)

    def test_symlink_aliases_cannot_create_another_owner(self):
        first, second = self.source(1), self.source(2)
        self.reserve(first)
        alias_parent = self.base / "aliased-code"
        alias_parent.mkdir()
        alias_repo, alias_wt = alias_parent / "sample", self.base / "wt-alias"
        alias_repo.symlink_to(self.repo, target_is_directory=True)
        alias_wt.symlink_to(first["wt"], target_is_directory=True)
        self.refused(self.reserve, second, repo=str(alias_repo), wt=str(alias_wt))
        self.claim(first)
        self.validate(first)

    def test_path_parent_segments_cannot_create_another_owner(self):
        first, second = self.source(1), self.source(2)
        self.reserve(first)
        alias = str(Path(first["wt"]).parent / ".." / "remote" / "00000001")
        self.refused(self.reserve, second, wt=alias)

    def test_reservation_validator_rejects_changed_path_or_branch(self):
        source = self.source(1)
        self.reserve(source)
        self.claim(source)
        for field in ("repo", "worktree", "branch"):
            with self.subTest(field=field):
                task = self.task(source)
                task[field] += "_other"
                self.refused(self.validate, source, task)

    def test_changed_mutation_target_refuses_without_consuming_claim(self):
        source = self.source(1)
        self.reserve(source)
        self.refused(RES.claim_mutation, self.db, source["cmd"]["command_id"], str(self.repo),
                     source["wt"], "remote/00000002", reason="does not own this exact worktree")
        self.claim(source)
        self.validate(source)

    def test_resume_requires_launched_terminal_parent_and_exact_attestation(self):
        _, parent = self.parent()
        child = self.source(2, parent)
        for field in ("task_id", "run_id", "pane_id", "pane_birth", "agent_session"):
            with self.subTest(field=field):
                proof = self.stopped(parent)
                proof[field] += "_other"
                self.refused(self.reserve, child, parent, stopped=proof)
        for proof in ({}, {**self.stopped(parent), "stopped": False}, {**self.stopped(parent), "stopped": 1}):
            with self.subTest(proof=proof):
                self.refused(self.reserve, child, parent, stopped=proof)
        row = self.reserve(child, parent)
        self.assertEqual((row["parent_task_id"], row["parent_run_id"]), (parent["task_id"], parent["run_id"]))

    def test_active_parent_cannot_be_replaced_even_with_stopped_claim(self):
        _, parent = self.parent()
        self.db.execute("UPDATE tasks SET state='running' WHERE task_id=?", (parent["task_id"],))
        self.db.commit()
        self.refused(self.reserve, self.source(2, parent), parent)

    def test_two_distinct_signed_resumes_have_one_mutating_consumer(self):
        _, parent = self.parent()
        children = [self.source(2, parent), self.source(3, parent)]
        barrier = threading.Barrier(2)
        mutations = []
        lock = threading.Lock()

        def consumer(source):
            with closing(AUTH.connect(str(self.path))) as db:
                barrier.wait(timeout=5)
                try:
                    row = self.reserve(source, parent, db=db)
                    self.claim(source, db=db)
                    with lock:
                        mutations.append(source["cmd"]["command_id"])
                    return ("reserved", source, row)
                except ValueError as exc:
                    db.rollback()
                    return ("refused", source, str(exc))

        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(consumer, children))
        self.assertEqual(sorted(result[0] for result in outcomes), ["refused", "reserved"], outcomes)
        refusal = next(result[2] for result in outcomes if result[0] == "refused")
        self.assertIn("worktree reservation: parent already has a successor", refusal)
        self.assertEqual(len(mutations), 1)
        winner = next(result[1] for result in outcomes if result[0] == "reserved")
        loser = next(result[1] for result in outcomes if result[0] == "refused")
        self.assertEqual(mutations, [winner["cmd"]["command_id"]])
        self.validate(winner)
        self.refused(self.validate, loser)
        self.refused(self.reserve, loser, parent)
        self.assertEqual(self.db.execute("SELECT count(*) FROM tasks").fetchone()[0], 1)

    def uncertain_owner(self, status):
        _, parent = self.parent()
        first = self.source(2, parent)
        self.reserve(first, parent)
        child_task = None
        if status != "accepted":
            self.claim(first)
            child_task = self.bind(first)
            if status == "launch_claimed":
                AUTH.launch(self.db, first["cmd"]["command_id"], child_task["task_id"], child_task["run_id"], status)
            child_task = self.terminal(child_task, "cancelled")
        future = time.time() + 1800
        with mock.patch("time.time", return_value=future):
            competitor = self.source(3, parent)
            self.refused(self.reserve, competitor, parent)
            if child_task:
                latest_request = self.source(4, child_task)
                self.refused(self.reserve, latest_request, child_task)
                self.refused(AUTH.launch, self.db, first["cmd"]["command_id"], child_task["task_id"], child_task["run_id"], "launch_claimed")
            self.refused(self.claim, first)
        self.assertEqual(AUTH.read(self.db, first["cmd"]["command_id"])["status"], status)

    def test_accepted_crash_expiry_cannot_release_or_late_claim(self):
        self.uncertain_owner("accepted")

    def test_bound_cancelled_crash_expiry_cannot_release_or_late_launch(self):
        self.uncertain_owner("bound")

    def test_launch_claimed_cancelled_crash_cannot_release_or_launch_again(self):
        self.uncertain_owner("launch_claimed")

    def test_latest_launched_terminal_child_permits_exactly_one_successor(self):
        _, parent = self.parent()
        first = self.source(2, parent)
        self.reserve(first, parent)
        self.claim(first)
        child_task = self.bind(first)
        self.launch(first, child_task)
        child_task = self.terminal(child_task)
        successor = self.source(3, child_task)
        self.reserve(successor, child_task)
        self.claim(successor)
        self.validate(successor)
        stale = self.source(4, parent)
        self.refused(self.reserve, stale, parent)
        duplicate_successor = self.source(5, child_task)
        self.refused(self.reserve, duplicate_successor, child_task)
        self.validate(successor)

    def test_new_start_cannot_replace_existing_reservation(self):
        _, parent = self.parent()
        start = self.source(2)
        self.refused(self.reserve, start, wt=parent["worktree"])

    def test_existing_active_local_task_blocks_remote_reservation(self):
        source = self.source(1)
        local = {**self.task(source), "task_id": "local_task", "run_id": "local_run"}
        AUTH.register(self.db, canonical(local))
        self.refused(self.reserve, source, reason="worktree already has a task")

    def test_unmigrated_registry_without_roles_fails_closed(self):
        # PR #334: the orchestrator cap must never be skipped because the
        # schema is old. No roles table -> register() raises, nothing lands.
        self.db.execute("DROP TABLE roles")
        self.db.commit()
        source = self.source(1)
        local = {**self.task(source), "task_id": "unmig_task", "run_id": "unmig_run"}
        with self.assertRaises(sqlite3.OperationalError):
            AUTH.register(self.db, canonical(local))
        self.db.rollback()
        self.assertEqual(self.db.execute("SELECT count(*) FROM tasks").fetchone()[0], 0)

    def test_migrated_registry_caps_orchestrator_children(self):
        # Same fixture with the real roles table: a live orchestrator@* conductor
        # gets at most ORCH_CHILD_CAP non-terminal children.
        source = self.source(1)
        base = self.task(source)
        cp, cb = base["conductor_pane_id"] or "orch:p", base["conductor_pane_birth"] or "orchbirth"
        self.db.execute("INSERT INTO roles VALUES ('orchestrator@sample', ?, ?, '', '', 'now', 'now')", (cp, cb))
        self.db.commit()
        for n in range(AUTH.ORCH_CHILD_CAP):
            self.db.execute("INSERT INTO tasks(task_id,conductor_pane_id,conductor_pane_birth,state) VALUES (?,?,?,'running')",
                            ("child%d" % n, cp, cb))
        self.db.commit()
        over = {**base, "task_id": "over_cap", "run_id": "over_run", "conductor_pane_id": cp, "conductor_pane_birth": cb}
        with self.assertRaises(AUTH.Refused):
            AUTH.register(self.db, canonical(over))
        self.db.rollback()
        self.assertEqual(self.db.execute("SELECT count(*) FROM tasks WHERE task_id='over_cap'").fetchone()[0], 0)

    def test_unrelated_legacy_empty_paths_do_not_block_new_worktree(self):
        self.db.execute("INSERT INTO tasks(task_id,state) VALUES ('legacy_empty','running')")
        self.db.commit()
        source = self.source(1)
        self.reserve(source)
        self.claim(source)
        self.validate(source)

    def test_nonremote_guard_refuses_existing_remote_reservation(self):
        source = self.source(1)
        RES.check_unreserved(self.db, str(self.repo), source["wt"], source["branch"])
        self.reserve(source)
        self.refused(RES.check_unreserved, self.db, str(self.repo), source["wt"], source["branch"],
                     reason="nonremote mutation refused")


if __name__ == "__main__":
    unittest.main(verbosity=2)
