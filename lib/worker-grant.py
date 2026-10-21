#!/usr/bin/env python3
"""Atomic approved-worker budget.

2026-10-21: the user approved exactly two repair workers plus one smoke. The
conductor then spawned two more registered REVIEW workers, and nothing refused
them. A grant here is a count the owner approved. Every spawn claims one slot
inside a single BEGIN IMMEDIATE transaction, so two concurrent spawns can
never both take the last slot. Review workers count like any other class;
smoke workers draw on a separate smoke_max.

A slot frees only when its task reaches a terminal registry state. Expiry,
crash or a missing pane never frees one (same rule as task reservations).

CLI (exit 0 = granted, 3 = refused, 2 = usage):
  worker-grant.py <db> claim <grant_id> <task_id> <job_class>
  worker-grant.py <db> release <task_id>          # only an unused claim
  worker-grant.py <db> status <grant_id>
Minting a grant is deliberately NOT a CLI verb: `mint()` is for the owner's
authenticated path (a gate), never the conductor.
"""
from __future__ import annotations

import json
import sqlite3
import sys
from datetime import datetime, timezone

TERMINAL = {"completed", "failed", "cancelled", "lost", "gone"}


class Refused(Exception):
    pass


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def schema(db: sqlite3.Connection) -> None:
    db.execute("""CREATE TABLE IF NOT EXISTS worker_grants (
        grant_id TEXT PRIMARY KEY, source TEXT NOT NULL,
        max_workers INTEGER NOT NULL CHECK (max_workers >= 0),
        smoke_max INTEGER NOT NULL DEFAULT 0 CHECK (smoke_max >= 0),
        expires_at TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
        created_by TEXT NOT NULL, created_at TEXT NOT NULL)""")
    db.execute("""CREATE TABLE IF NOT EXISTS worker_grant_slots (
        task_id TEXT PRIMARY KEY, grant_id TEXT NOT NULL REFERENCES worker_grants(grant_id),
        job_class TEXT NOT NULL, pool TEXT NOT NULL CHECK (pool IN ('worker','smoke')),
        claimed_at TEXT NOT NULL)""")
    db.execute("""CREATE TABLE IF NOT EXISTS tasks (task_id TEXT PRIMARY KEY, state TEXT)""")
    db.commit()


def mint(db, grant_id, source, max_workers, smoke_max, expires_at, created_by):
    """Owner-authenticated path only (not exposed on the CLI)."""
    schema(db)
    db.execute("INSERT INTO worker_grants VALUES (?,?,?,?,?,0,?,?)",
               (grant_id, source, max_workers, smoke_max, expires_at, created_by, _now()))
    db.commit()


def _live(db, grant_id, pool):
    # A slot is live until ITS task is terminal. A slot with no task row yet
    # (claimed, spawn still in flight or crashed) stays live: uncertain never frees.
    return db.execute(
        """SELECT s.task_id FROM worker_grant_slots s LEFT JOIN tasks t ON t.task_id = s.task_id
           WHERE s.grant_id = ? AND s.pool = ? AND (t.state IS NULL OR t.state NOT IN (%s))"""
        % ",".join("?" * len(TERMINAL)), (grant_id, pool, *sorted(TERMINAL))).fetchall()


def claim(db, grant_id, task_id, job_class, now=None):
    schema(db)
    pool = "smoke" if job_class == "smoke" else "worker"
    db.execute("BEGIN IMMEDIATE")
    try:
        g = db.execute("SELECT * FROM worker_grants WHERE grant_id=?", (grant_id,)).fetchone()
        if g is None:
            raise Refused(f"no such grant {grant_id!r}")
        if g["revoked"]:
            raise Refused(f"grant {grant_id} is revoked")
        if g["expires_at"] <= (now or _now()):
            raise Refused(f"grant {grant_id} expired at {g['expires_at']}")
        if db.execute("SELECT 1 FROM worker_grant_slots WHERE task_id=?", (task_id,)).fetchone():
            raise Refused(f"task {task_id} already holds a slot")
        cap = g["smoke_max"] if pool == "smoke" else g["max_workers"]
        live = [r["task_id"] for r in _live(db, grant_id, pool)]
        if len(live) + 1 > cap:
            raise Refused(f"grant {grant_id} ({g['source']}): {pool} cap {cap} reached; live: "
                          f"{', '.join(live) or 'none'}. Ask the owner for more; it never auto-expands.")
        db.execute("INSERT INTO worker_grant_slots VALUES (?,?,?,?,?)",
                   (task_id, grant_id, job_class, pool, _now()))
        db.commit()
    except BaseException:
        db.rollback()
        raise
    return {"grant_id": grant_id, "task_id": task_id, "pool": pool, "live_after": len(live) + 1, "cap": cap}


def release_unused(db, task_id):
    """Undo a claim whose spawn failed BEFORE a task row existed."""
    schema(db)
    db.execute("BEGIN IMMEDIATE")
    if db.execute("SELECT 1 FROM tasks WHERE task_id=?", (task_id,)).fetchone():
        db.rollback()
        raise Refused(f"task {task_id} was registered; its slot frees only at a terminal state")
    db.execute("DELETE FROM worker_grant_slots WHERE task_id=?", (task_id,))
    db.commit()


def connect(path):
    db = sqlite3.connect(path, timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    return db


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    db, verb, args = connect(argv[1]), argv[2], argv[3:]
    try:
        if verb == "claim" and len(args) == 3:
            print(json.dumps(claim(db, *args)))
        elif verb == "release" and len(args) == 1:
            release_unused(db, args[0])
        elif verb == "status" and len(args) == 1:
            schema(db)
            print(json.dumps({p: [r["task_id"] for r in _live(db, args[0], p)] for p in ("worker", "smoke")}))
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Refused as e:
        print(f"worker-grant: REFUSED: {e}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
