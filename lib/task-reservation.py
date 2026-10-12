#!/usr/bin/env python3
"""Durable worktree ownership for authenticated remote launches.

The trusted receiver verifies source authentication and the bridge observes
the previous pane stopped. This adapter commits their exact bindings before
any shared-worktree mutation. Neither time nor a failed acknowledgement frees
an uncertain owner; only a definitely launched, stopped latest child advances
the lineage. This is protected registry state, never worker-provided evidence.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys

TERMINAL = {"completed", "failed", "cancelled", "lost", "gone"}
_AUTH = None


def auth():
    global _AUTH
    if _AUTH is None:
        spec = importlib.util.spec_from_file_location("reservation_authorization", Path(__file__).with_name("task-authorization.py"))
        _AUTH = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_AUTH)
    return _AUTH


def refuse(detail):
    raise ValueError("worktree reservation: " + detail)


def canonical_path(value):
    if not isinstance(value, str) or not os.path.isabs(value) or os.path.normpath(value) != value:
        refuse("path must be absolute and normalized")
    return os.path.realpath(value)


def schema(db):
    db.execute("""CREATE TABLE IF NOT EXISTS task_worktree_reservations (
        repo TEXT NOT NULL, branch TEXT NOT NULL, worktree TEXT NOT NULL UNIQUE,
        command_id TEXT NOT NULL UNIQUE, parent_run_id TEXT NOT NULL,
        parent_task_id TEXT NOT NULL, mutation_claimed INTEGER NOT NULL DEFAULT 0,
        reserved_at TEXT NOT NULL, PRIMARY KEY(repo,branch))""")
    db.execute("""CREATE TABLE IF NOT EXISTS task_resume_edges (
        parent_task_id TEXT PRIMARY KEY, parent_run_id TEXT NOT NULL,
        command_id TEXT NOT NULL UNIQUE)""")
    db.commit()


def _source(db, command_id):
    receipt = auth().read(db, command_id)
    if receipt is None or receipt["source"] != "oauth_task_delegation":
        refuse("missing authenticated remote source")
    claims = auth()._check_source(receipt)
    return receipt, claims


def _parent(db, payload, repo, worktree, branch, proof):
    parent = db.execute("SELECT * FROM tasks WHERE task_id=? AND run_id=?",
                        (payload.get("local_task_id"), payload.get("local_run_id"))).fetchone()
    if (parent is None or parent["state"] not in TERMINAL or canonical_path(parent["repo"]) != repo
            or canonical_path(parent["worktree"]) != worktree or parent["branch"] != branch):
        refuse("parent identity, terminal state or worktree differs")
    previous = db.execute("SELECT * FROM task_authorizations WHERE task_id=?", (parent["task_id"],)).fetchone()
    if previous is None or previous["status"] != "launched":
        refuse("parent launch is unproven or uncertain")
    auth().verify_receipt(db, previous)
    expected = {key: parent[key] or "" for key in ("task_id", "run_id", "pane_id", "pane_birth", "agent_session")}
    if proof.get("stopped") is not True or proof != {**expected, "stopped": True}:
        refuse("missing exact trusted observation that parent pane stopped")
    return parent


def reserve(db, raw_command, repo, worktree, branch, raw_stopped_parent="{}"):
    adapter = auth()
    command, proof = adapter.parse(raw_command), adapter.parse(raw_stopped_parent)
    original_repo = repo
    repo, worktree = canonical_path(repo), canonical_path(worktree)
    schema(db)
    db.execute("BEGIN IMMEDIATE")
    receipt, claims = _source(db, command.get("command_id"))
    payload = command.get("payload")
    if (not isinstance(payload, dict) or adapter.digest(adapter.canonical(payload)) != receipt["payload_sha256"]
            or any(command.get(key) != claims.get(key) for key in ("command_id", "op", "remote_task_id"))
            or payload.get("repo") != claims["repo"] or os.path.basename(original_repo) != claims["repo"]):
        refuse("original command/source binding differs")
    if receipt["status"] != "accepted" or receipt["task_id"]:
        refuse("source already bound; no new mutation")
    adapter.valid_window(claims)
    if receipt["deadline_at"] and receipt["deadline_at"] <= adapter.now_iso():
        refuse("task deadline expired")
    owner = db.execute("SELECT * FROM task_worktree_reservations WHERE (repo=? AND branch=?) OR worktree=?",
                       (repo, branch, worktree)).fetchall()
    if len(owner) > 1:
        refuse("branch and worktree have different owners")
    owner = owner[0] if owner else None
    if owner and owner["command_id"] == command["command_id"]:
        if (owner["repo"], owner["worktree"], owner["branch"]) != (repo, worktree, branch):
            refuse("existing command paths differ")
        db.commit()
        return {**dict(owner), "newly_reserved": False}
    parent = None
    if command["op"] == "resume":
        if payload.get("branch") != branch:
            refuse("resume branch differs")
        parent = _parent(db, payload, repo, worktree, branch, proof)
        if db.execute("SELECT 1 FROM task_resume_edges WHERE parent_task_id=?", (parent["task_id"],)).fetchone():
            refuse("parent already has a successor; resume the latest child")
        if owner:
            previous = adapter.read(db, owner["command_id"])
            if (previous is None or previous["status"] != "launched" or previous["task_id"] != parent["task_id"]
                    or previous["run_id"] != parent["run_id"]):
                refuse("current owner is not the definitely launched terminal parent")
    elif command["op"] == "start":
        if branch != "remote/" + command["remote_task_id"].rsplit("_", 1)[-1] or owner:
            refuse("start branch differs or already has an owner")
    else:
        refuse("unsupported command")
    # Include tasks created before reservations existed and local tasks. A
    # lexical path alias cannot hide an active occupant of this worktree.
    for task in db.execute("SELECT task_id,repo,worktree,branch,state FROM tasks"):
        # Legacy records may have no path at all; those do not name a
        # competing worktree. Compare every usable identity independently.
        task_wt, task_repo = task["worktree"], task["repo"]
        same_wt = isinstance(task_wt, str) and os.path.isabs(task_wt) and os.path.realpath(task_wt) == worktree
        same_repo = isinstance(task_repo, str) and os.path.isabs(task_repo) and os.path.realpath(task_repo) == repo
        same = same_wt or (same_repo and task["branch"] == branch)
        if same and (command["op"] == "start" or task["state"] not in TERMINAL):
            refuse("worktree already has a task that cannot be superseded")
    if parent:
        db.execute("INSERT INTO task_resume_edges VALUES (?,?,?)", (parent["task_id"], parent["run_id"], command["command_id"]))
    values = (repo, branch, worktree, command["command_id"], parent["run_id"] if parent else "",
              parent["task_id"] if parent else "", adapter.now_iso())
    if owner:
        db.execute("DELETE FROM task_worktree_reservations WHERE command_id=?", (owner["command_id"],))
    db.execute("INSERT INTO task_worktree_reservations(repo,branch,worktree,command_id,parent_run_id,parent_task_id,reserved_at) VALUES (?,?,?,?,?,?,?)", values)
    row = db.execute("SELECT * FROM task_worktree_reservations WHERE command_id=?", (command["command_id"],)).fetchone()
    db.commit()
    return {**dict(row), "newly_reserved": True}


def validate_reservation(db, receipt, task, *, require_mutation=True):
    if receipt["source"] != "oauth_task_delegation":
        return
    try:
        row = db.execute("SELECT * FROM task_worktree_reservations WHERE command_id=?", (receipt["command_id"],)).fetchone()
    except sqlite3.Error as exc:
        refuse("protected reservation unavailable: " + str(exc))
    if (row is None or row["repo"] != canonical_path(task["repo"])
            or row["worktree"] != canonical_path(task["worktree"]) or row["branch"] != task["branch"]
            or (require_mutation and row["mutation_claimed"] != 1)):
        refuse("command does not own this exact worktree mutation")


def claim_mutation(db, command_id, repo, worktree, branch):
    db.execute("BEGIN IMMEDIATE")
    receipt, claims = _source(db, command_id)
    if receipt["status"] != "accepted" or receipt["task_id"]:
        refuse("source already bound; no repeated mutation")
    auth().valid_window(claims)
    if receipt["deadline_at"] and receipt["deadline_at"] <= auth().now_iso():
        refuse("task deadline expired")
    validate_reservation(db, receipt, {"repo": repo, "worktree": worktree, "branch": branch}, require_mutation=False)
    changed = db.execute("UPDATE task_worktree_reservations SET mutation_claimed=1 WHERE command_id=? AND mutation_claimed=0", (command_id,)).rowcount
    if changed != 1:
        refuse("mutation already claimed; uncertain attempt cannot execute again")
    row = db.execute("SELECT * FROM task_worktree_reservations WHERE command_id=?", (command_id,)).fetchone()
    db.commit()
    return dict(row)


def check_unreserved(db, repo, worktree, branch):
    """Conservative guard for existing nonremote launch paths, not a lock.

    It does not serialize a brand-new nonremote launch racing a receiver
    before either registers; that broader local intent lifecycle is separate.
    """
    repo, worktree = canonical_path(repo), canonical_path(worktree)
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='task_worktree_reservations'").fetchone():
        return
    if db.execute("SELECT 1 FROM task_worktree_reservations WHERE (repo=? AND branch=?) OR worktree=?",
                  (repo, branch, worktree)).fetchone():
        refuse("remote command owns this worktree; nonremote mutation refused")


def main():
    path, op, *args = sys.argv[1:]
    if op == "check-unreserved" and not os.path.exists(path):
        return
    with auth().connect(path, readonly=op == "check-unreserved") as db:
        if op == "reserve":
            result = reserve(db, *args)
        elif op == "claim-mutation":
            result = claim_mutation(db, *args)
        elif op == "check-unreserved":
            check_unreserved(db, *args)
            result = {}
        else:
            refuse("unknown operation")
        print(auth().canonical(result))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, KeyError, sqlite3.Error, OSError) as exc:
        print("reservation hold: " + str(exc), file=sys.stderr)
        sys.exit(1)
