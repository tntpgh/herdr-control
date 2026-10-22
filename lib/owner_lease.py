"""owner_lease.py — INERT contract for project owners: canonical project
mapping, lease CAS, generation/pane/birth fencing, a bounded per-owner request
queue with explicit dispositions, stale-request disposition, CAS reap, and an
append-only event log.

Nothing calls this. It is reviewable source with offline proofs ahead of any
activation decision. It never closes, spawns or touches a pane, never grants a
worker anything (that is spawn-task.sh / lib/worker-grant.py, frozen #348) and
does not drain queues or create conductors.

Invariants
  * One owner label per canonical project, one project per label
    (owner_projects: label PK, project UNIQUE).
  * At most one LIVE lease per label, enforced by the DB itself
    (partial UNIQUE index on owner_leases(label) WHERE released_at IS NULL).
    acquire() releases an expired holder and inserts the successor in ONE
    IMMEDIATE transaction, so expiry never blocks the index and two
    contenders can never both win.
  * Generation = MAX(generation)+1 over the label's whole history; renewal by
    the same (pane, birth) keeps it.
  * Every queue mutation is fenced: the caller's (generation, pane, birth)
    must be the current live lease, and the request must belong to that
    generation.
  * When a new generation takes the lease, every OPEN request of older
    generations is disposed `stale` in the same transaction: it no longer
    counts toward the successor's bound (no starvation) and can never be
    delivered or replied to (no replay).
  * enqueue() of an existing request_id never grants delivery authority again:
    it returns the durable prior outcome with authority=False.
  * reap() releases a lease only by CAS on the observed
    (lease_id, renewed_at, expires_at): a holder that renewed after the
    observation keeps its lease.
  * owner_events is append-only (UPDATE/DELETE rejected by triggers).

Request dispositions
  open:      queued, held, blocked, delivering
  terminal:  replied, evidence, timeout, stale, cancelled
  queued -> held | blocked | delivering | cancelled
  held -> queued | cancelled            blocked -> queued | cancelled
  delivering -> replied | timeout | blocked
  replied -> evidence
  (any open) -> stale   — only by acquire() on generation change

Migration (design; NOT applied to the live registry by this file)
  migrate(conn) is versioned (owner_schema_version) and idempotent; v1 only
  CREATEs owner_* tables/indexes/triggers and alters no existing table.
  Rollback of v1: DROP the five owner_* tables (their indexes and triggers go
  with them); nothing else references them. Applying it live is a separate
  approval with a registry backup first.

ceiling: pane birth is identity, not liveness proof — the caller supplies the
live pane set (herdr pane list). Clock is the caller's `now` (UTC seconds).
"""
from __future__ import annotations

import re
import sqlite3
import time
import uuid
from datetime import datetime, timezone

SCHEMA_VERSION = 1
DEFAULT_BOUND = 5
LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")
_PROJECT_RE = re.compile(
    r"^(?:(?:https://|ssh://git\x40)?github\.com[/:]|git\x40github\.com:)?(tntpgh)/([A-Za-z0-9._-]+?)(?:\.git)?/?$"
)

OPEN = ("queued", "held", "blocked", "delivering")
TERMINAL = ("replied", "evidence", "timeout", "stale", "cancelled")
TRANSITIONS = {
    "queued": {"held", "blocked", "delivering", "cancelled"},
    "held": {"queued", "cancelled"},
    "blocked": {"queued", "cancelled"},
    "delivering": {"replied", "timeout", "blocked"},
    "replied": {"evidence"},
}


class LeaseConflict(Exception):
    """Another live holder owns this label."""


class FencedOut(Exception):
    """Caller is not the current live holder (generation/pane/birth), or the
    request belongs to another generation."""


class QueueFull(Exception):
    """The owner already has `bound` open requests."""


class InvalidOwner(ValueError):
    """Bad label/project, or a mapping that would give a project two owners."""


class InvalidTransition(ValueError):
    pass


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)  # explicit BEGINs only
    conn.execute("PRAGMA busy_timeout=10000")
    return conn


MIGRATIONS = {
    1: [
        "CREATE TABLE owner_projects (label TEXT PRIMARY KEY, project TEXT NOT NULL UNIQUE, registered_at TEXT NOT NULL)",
        """CREATE TABLE owner_leases (
             lease_id TEXT PRIMARY KEY, label TEXT NOT NULL REFERENCES owner_projects(label),
             pane_id TEXT NOT NULL, pane_birth TEXT NOT NULL, generation INTEGER NOT NULL,
             acquired_at TEXT NOT NULL, renewed_at TEXT NOT NULL, expires_at TEXT NOT NULL,
             released_at TEXT, release_reason TEXT, UNIQUE(label, generation))""",
        "CREATE UNIQUE INDEX owner_leases_one_live ON owner_leases(label) WHERE released_at IS NULL",
        """CREATE TABLE owner_requests (
             request_id TEXT PRIMARY KEY, label TEXT NOT NULL, generation INTEGER NOT NULL,
             state TEXT NOT NULL CHECK (state IN ('queued','held','blocked','delivering','replied','evidence','timeout','stale','cancelled')),
             created_at TEXT NOT NULL, updated_at TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '')""",
        "CREATE INDEX owner_requests_label_state ON owner_requests(label, state)",
        "CREATE INDEX owner_requests_label_gen ON owner_requests(label, generation)",
        """CREATE TABLE owner_events (
             seq INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, label TEXT NOT NULL,
             kind TEXT NOT NULL, ref TEXT NOT NULL DEFAULT '', generation INTEGER, detail TEXT NOT NULL DEFAULT '')""",
        "CREATE INDEX owner_events_label_seq ON owner_events(label, seq)",
        "CREATE TRIGGER owner_events_no_update BEFORE UPDATE ON owner_events BEGIN SELECT RAISE(ABORT, 'owner_events is append-only'); END",
        "CREATE TRIGGER owner_events_no_delete BEFORE DELETE ON owner_events BEGIN SELECT RAISE(ABORT, 'owner_events is append-only'); END",
    ],
}


def migrate(conn: sqlite3.Connection) -> int:
    """Apply pending versioned migrations atomically. Returns the schema version."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS owner_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
        cur = conn.execute("SELECT COALESCE(MAX(version),0) FROM owner_schema_version").fetchone()[0]
        for v in sorted(MIGRATIONS):
            if v > cur:
                for stmt in MIGRATIONS[v]:
                    conn.execute(stmt)
                conn.execute("INSERT INTO owner_schema_version VALUES (?,?)", (v, _iso(time.time())))
                cur = v
        conn.execute("COMMIT")
        return cur
    except BaseException:
        conn.execute("ROLLBACK")
        raise


def _event(conn, now, label, kind, ref="", generation=None, detail=""):
    conn.execute("INSERT INTO owner_events(at,label,kind,ref,generation,detail) VALUES (?,?,?,?,?,?)",
                 (_iso(now), label, kind, ref, generation, detail))


def _tx(conn, fn):
    conn.execute("BEGIN IMMEDIATE")
    try:
        out = fn()
        conn.execute("COMMIT")
        return out
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def canonical_project(value: str) -> str:
    """'tntpgh/X', github https/ssh URLs, with or without .git -> 'tntpgh/x'."""
    m = _PROJECT_RE.match((value or "").strip())
    if not m:
        raise InvalidOwner(f"not a canonical tntpgh project: {value!r}")
    return f"{m.group(1)}/{m.group(2).lower()}"


def register_owner(conn, label: str, project: str, now: float | None = None) -> str:
    """Map label <-> canonical project. Idempotent for the same pair; any other
    overlap (label to another project, project to another label) is refused."""
    now = time.time() if now is None else now
    if not LABEL_RE.match(label or ""):
        raise InvalidOwner(f"invalid owner label {label!r}")
    proj = canonical_project(project)

    def body():
        row = conn.execute("SELECT label, project FROM owner_projects WHERE label=? OR project=?", (label, proj)).fetchall()
        if row == [(label, proj)]:
            return proj
        if row:
            raise InvalidOwner(f"{label} -> {proj} conflicts with existing {row}")
        conn.execute("INSERT INTO owner_projects VALUES (?,?,?)", (label, proj, _iso(now)))
        _event(conn, now, label, "registered", proj)
        return proj

    return _tx(conn, body)


def _live(conn, label, now):
    """Current live lease (unreleased, unexpired) or None."""
    return conn.execute(
        "SELECT lease_id, pane_id, pane_birth, generation, renewed_at, expires_at FROM owner_leases "
        "WHERE label=? AND released_at IS NULL AND expires_at > ?", (label, _iso(now))).fetchone()


def acquire(conn, label: str, pane_id: str, pane_birth: str, ttl_s: int, now: float | None = None) -> int:
    """Acquire or renew. Returns the holder's generation. On a generation change,
    the expired predecessor is released and its open requests disposed `stale`,
    all in the same transaction as the successor's insert."""
    now = time.time() if now is None else now

    def body():
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (label,)).fetchone():
            raise InvalidOwner(f"{label} is not a registered owner")
        cur = _live(conn, label, now)
        if cur:
            lease_id, pane, birth, gen, _r, _e = cur
            if (pane, birth) != (pane_id, pane_birth):
                raise LeaseConflict(f"{label} held by {pane}@{birth} gen {gen}")
            conn.execute("UPDATE owner_leases SET renewed_at=?, expires_at=? WHERE lease_id=?",
                         (_iso(now), _iso(now + ttl_s), lease_id))
            _event(conn, now, label, "renewed", lease_id, gen)
            return gen
        for (old_id, old_gen) in conn.execute(
                "SELECT lease_id, generation FROM owner_leases WHERE label=? AND released_at IS NULL", (label,)).fetchall():
            conn.execute("UPDATE owner_leases SET released_at=?, release_reason='expired' WHERE lease_id=?", (_iso(now), old_id))
            _event(conn, now, label, "released", old_id, old_gen, "expired")
        gen = conn.execute("SELECT COALESCE(MAX(generation),0)+1 FROM owner_leases WHERE label=?", (label,)).fetchone()[0]
        lease_id = f"ol_{uuid.uuid4().hex}"
        conn.execute("INSERT INTO owner_leases(lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,expires_at) "
                     "VALUES (?,?,?,?,?,?,?,?)", (lease_id, label, pane_id, pane_birth, gen, _iso(now), _iso(now), _iso(now + ttl_s)))
        _event(conn, now, label, "acquired", lease_id, gen, f"{pane_id}@{pane_birth}")
        stale = conn.execute(
            f"SELECT request_id, generation FROM owner_requests WHERE label=? AND generation<? AND state IN ({_q(OPEN)})",
            (label, gen, *OPEN)).fetchall()
        for rid, rgen in stale:
            conn.execute("UPDATE owner_requests SET state='stale', updated_at=? WHERE request_id=?", (_iso(now), rid))
            _event(conn, now, label, "request:stale", rid, rgen, f"superseded by gen {gen}")
        return gen

    return _tx(conn, body)


def _q(items):
    return ",".join("?" * len(items))


def _fence(conn, label, generation, pane_id, pane_birth, now):
    cur = _live(conn, label, now)
    if not cur or (cur[3], cur[1], cur[2]) != (generation, pane_id, pane_birth):
        raise FencedOut(f"{label}: caller gen {generation} {pane_id}@{pane_birth}, live {cur[1:4] if cur else None}")


def check_fence(conn, label, generation, pane_id, pane_birth, now=None) -> None:
    _fence(conn, label, generation, pane_id, pane_birth, time.time() if now is None else now)


def release(conn, label, generation, pane_id, pane_birth, now=None) -> bool:
    """Voluntary release by the current holder only (fenced)."""
    now = time.time() if now is None else now

    def body():
        _fence(conn, label, generation, pane_id, pane_birth, now)
        conn.execute("UPDATE owner_leases SET released_at=?, release_reason='released' "
                     "WHERE label=? AND generation=? AND released_at IS NULL", (_iso(now), label, generation))
        _event(conn, now, label, "released", "", generation, "voluntary")
        return True

    return _tx(conn, body)


def enqueue(conn, label, generation, pane_id, pane_birth, request_id, bound=DEFAULT_BOUND, now=None) -> dict:
    """Fenced, bounded, atomic. A new id -> {'state':'queued','authority':True}.
    An existing id -> its durable prior outcome with authority False (never a
    fresh delivery grant, whatever generation it was queued under)."""
    now = time.time() if now is None else now

    def body():
        row = conn.execute("SELECT label, generation, state FROM owner_requests WHERE request_id=?", (request_id,)).fetchone()
        if row:
            return {"request_id": request_id, "label": row[0], "generation": row[1], "state": row[2], "authority": False}
        _fence(conn, label, generation, pane_id, pane_birth, now)
        n = conn.execute(f"SELECT COUNT(*) FROM owner_requests WHERE label=? AND state IN ({_q(OPEN)})", (label, *OPEN)).fetchone()[0]
        if n >= bound:
            raise QueueFull(f"{label}: {n} open >= bound {bound}")
        conn.execute("INSERT INTO owner_requests(request_id,label,generation,state,created_at,updated_at) VALUES (?,?,?,?,?,?)",
                     (request_id, label, generation, "queued", _iso(now), _iso(now)))
        _event(conn, now, label, "request:queued", request_id, generation)
        return {"request_id": request_id, "label": label, "generation": generation, "state": "queued", "authority": True}

    return _tx(conn, body)


def transition(conn, request_id, to, label, generation, pane_id, pane_birth, detail="", now=None) -> str:
    """Fenced state change. The request must belong to the caller's label AND
    current generation; `stale` is never a caller transition."""
    now = time.time() if now is None else now

    def body():
        row = conn.execute("SELECT label, generation, state FROM owner_requests WHERE request_id=?", (request_id,)).fetchone()
        if not row:
            raise InvalidTransition(f"unknown request {request_id}")
        _fence(conn, label, generation, pane_id, pane_birth, now)
        if row[:2] != (label, generation):
            raise FencedOut(f"{request_id} belongs to {row[0]} gen {row[1]}, caller {label} gen {generation}")
        if to not in TRANSITIONS.get(row[2], set()):
            raise InvalidTransition(f"{request_id}: {row[2]} -> {to} not allowed")
        conn.execute("UPDATE owner_requests SET state=?, updated_at=?, detail=? WHERE request_id=? AND state=?",
                     (to, _iso(now), detail, request_id, row[2]))
        _event(conn, now, label, f"request:{to}", request_id, generation, detail)
        return to

    return _tx(conn, body)


def observe_stale(conn, live_panes: set, now=None) -> list[dict]:
    """Unreleased leases whose holder is gone from the live pane set or expired,
    with the exact identity reap() must CAS on."""
    now = time.time() if now is None else now
    out = []
    for lease_id, label, pane, birth, gen, renewed, expires in conn.execute(
            "SELECT lease_id,label,pane_id,pane_birth,generation,renewed_at,expires_at FROM owner_leases WHERE released_at IS NULL"):
        reason = "expired" if expires <= _iso(now) else ("pane-gone" if (pane, birth) not in live_panes else None)
        if reason:
            out.append({"lease_id": lease_id, "label": label, "pane": pane, "birth": birth, "generation": gen,
                        "renewed_at": renewed, "expires_at": expires, "reason": reason})
    return out


def reap(conn, observed: list[dict], now=None, dry_run=True) -> list[dict]:
    """Release observed stale leases (registry rows only; never a pane) by CAS on
    (lease_id, renewed_at, expires_at). Dry-run by default."""
    now = time.time() if now is None else now
    if dry_run:
        return [dict(o, released=False, dry_run=True) for o in observed]

    def body():
        res = []
        for o in observed:
            cur = conn.execute("UPDATE owner_leases SET released_at=?, release_reason=? WHERE lease_id=? AND renewed_at=? "
                               "AND expires_at=? AND released_at IS NULL",
                               (_iso(now), f"reaped:{o['reason']}", o["lease_id"], o["renewed_at"], o["expires_at"]))
            ok = cur.rowcount == 1
            _event(conn, now, o["label"], "reaped" if ok else "reap-skipped", o["lease_id"], o["generation"], o["reason"])
            res.append(dict(o, released=ok))
        return res

    return _tx(conn, body)
