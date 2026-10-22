"""owner_lease.py — INERT contract for project-owner leases, delivery fencing,
a bounded per-owner request queue and stale-owner detection.

Nothing calls this yet. It exists so the hierarchy's safety properties are
reviewable source with offline proofs before any activation decision:

  * lease CAS      — one live holder per owner label. Acquire is
                     BEGIN IMMEDIATE + check + insert in ONE transaction, so
                     two contenders can never both win (unlike owners'
                     INSERT OR REPLACE, which is last-write-wins).
  * generation     — every new holder gets MAX(generation)+1 over the scope's
                     whole history (same rule as lib/claims.sh). A delivery
                     carries the generation it was addressed to and is refused
                     unless that is the CURRENT live holder's generation, so a
                     message aimed at a replaced owner cannot land on the new one.
  * queue bound    — enqueue is fence-check + open-count + insert in one
                     IMMEDIATE transaction; the bound holds under concurrency.
                     Idempotent per request_id (a retry never double-queues).
  * stale owners   — a holder whose (pane, birth) is not in the live pane set,
                     or whose lease expired, is stale. reap() is dry-run unless
                     told otherwise and only RELEASES the lease row — it never
                     closes or touches a pane (that behaviour belongs to the
                     frozen #348 lifecycle work).

Storage: leases reuse the existing `claims` table under scope `owner:<label>`.
The queue needs one NEW table, `owner_requests`; ensure_queue_table() creates
it only when called (tests call it). Applying it to the live registry is a
migration and is NOT done by this file.

ceiling: pane birth is identity, not liveness proof — the caller supplies the
live pane set (herdr pane list). Clock is the caller's `now` (UTC seconds).
"""
from __future__ import annotations

import sqlite3
import time
import uuid
from datetime import datetime, timezone

DEFAULT_BOUND = 5
OPEN_STATES = ("queued", "acked")


class LeaseConflict(Exception):
    """Another live holder owns this label."""


class FencedOut(Exception):
    """Delivery generation is not the current live holder's generation."""


class QueueFull(Exception):
    """The owner already has `bound` open requests."""


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)  # explicit BEGINs only
    conn.execute("PRAGMA busy_timeout=10000")
    return conn


def ensure_queue_table(conn: sqlite3.Connection) -> None:
    conn.execute(
        """CREATE TABLE IF NOT EXISTS owner_requests (
             request_id  TEXT PRIMARY KEY,
             label       TEXT NOT NULL,
             generation  INTEGER NOT NULL,
             state       TEXT NOT NULL CHECK (state IN ('queued','acked','done','cancelled')),
             created_at  TEXT NOT NULL,
             updated_at  TEXT NOT NULL)"""
    )


def _scope(label: str) -> str:
    return f"owner:{label}"


def _live_lease(conn: sqlite3.Connection, label: str, now: float):
    return conn.execute(
        "SELECT claim_id, pane_id, pane_birth, generation FROM claims "
        "WHERE scope=? AND released_at IS NULL AND expires_at > ? ORDER BY generation DESC LIMIT 1",
        (_scope(label), _iso(now)),
    ).fetchone()


def acquire(conn, label: str, pane_id: str, pane_birth: str, ttl_s: int, now: float | None = None) -> int:
    """Acquire or renew the owner lease. Returns the holder's generation.

    Same (pane, birth) re-acquiring is a renewal (generation unchanged).
    A different live holder raises LeaseConflict."""
    now = time.time() if now is None else now
    conn.execute("BEGIN IMMEDIATE")
    try:
        cur = _live_lease(conn, label, now)
        if cur:
            claim_id, pane, birth, gen = cur
            if (pane, birth) != (pane_id, pane_birth):
                raise LeaseConflict(f"{label} held by {pane}@{birth} gen {gen}")
            conn.execute("UPDATE claims SET renewed_at=?, expires_at=? WHERE claim_id=?",
                         (_iso(now), _iso(now + ttl_s), claim_id))
            conn.execute("COMMIT")
            return gen
        gen = conn.execute("SELECT COALESCE(MAX(generation),0)+1 FROM claims WHERE scope=?",
                           (_scope(label),)).fetchone()[0]
        conn.execute(
            "INSERT INTO claims(claim_id, scope, pane_id, pane_birth, purpose, parent, claimed_at, renewed_at, expires_at, generation) "
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (f"cl_{uuid.uuid4().hex}", _scope(label), pane_id, pane_birth, "owner-lease", "",
             _iso(now), _iso(now), _iso(now + ttl_s), gen),
        )
        conn.execute("COMMIT")
        return gen
    except BaseException:
        conn.execute("ROLLBACK")
        raise


def release(conn, label: str, generation: int, now: float | None = None) -> bool:
    """Release only if `generation` is the current holder (a stale holder cannot release its successor)."""
    now = time.time() if now is None else now
    cur = conn.execute(
        "UPDATE claims SET released_at=? WHERE scope=? AND generation=? AND released_at IS NULL",
        (_iso(now), _scope(label), generation),
    )
    return cur.rowcount == 1


def check_fence(conn, label: str, generation: int, now: float | None = None) -> None:
    now = time.time() if now is None else now
    cur = _live_lease(conn, label, now)
    if not cur or cur[3] != generation:
        raise FencedOut(f"{label}: delivery gen {generation}, live gen {cur[3] if cur else None}")


def enqueue(conn, label: str, generation: int, request_id: str, bound: int = DEFAULT_BOUND,
            now: float | None = None) -> str:
    """Fence-check + bound-check + insert, atomically. Returns 'queued' or 'duplicate'."""
    now = time.time() if now is None else now
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = conn.execute("SELECT label, generation FROM owner_requests WHERE request_id=?", (request_id,)).fetchone()
        if row:
            conn.execute("COMMIT")
            if row != (label, generation):
                raise ValueError(f"request_id {request_id} already bound to {row}")
            return "duplicate"
        check_fence(conn, label, generation, now)
        open_n = conn.execute(
            f"SELECT COUNT(*) FROM owner_requests WHERE label=? AND state IN ({','.join('?' * len(OPEN_STATES))})",
            (label, *OPEN_STATES),
        ).fetchone()[0]
        if open_n >= bound:
            raise QueueFull(f"{label}: {open_n} open >= bound {bound}")
        conn.execute("INSERT INTO owner_requests VALUES (?,?,?,?,?,?)",
                     (request_id, label, generation, "queued", _iso(now), _iso(now)))
        conn.execute("COMMIT")
        return "queued"
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def transition(conn, request_id: str, to: str, now: float | None = None) -> bool:
    now = time.time() if now is None else now
    allowed = {"acked": ("queued",), "done": ("queued", "acked"), "cancelled": ("queued", "acked")}[to]
    cur = conn.execute(
        f"UPDATE owner_requests SET state=?, updated_at=? WHERE request_id=? AND state IN ({','.join('?' * len(allowed))})",
        (to, _iso(now), request_id, *allowed),
    )
    return cur.rowcount == 1


def stale_owners(conn, live_panes: set[tuple[str, str]], now: float | None = None) -> list[dict]:
    """Unreleased owner leases whose holder is gone from the live pane set or whose lease expired."""
    now = time.time() if now is None else now
    out = []
    for label_scope, pane, birth, gen, expires in conn.execute(
        "SELECT scope, pane_id, pane_birth, generation, expires_at FROM claims "
        "WHERE scope LIKE 'owner:%' AND released_at IS NULL"
    ):
        reason = "expired" if expires <= _iso(now) else ("pane-gone" if (pane, birth) not in live_panes else None)
        if reason:
            out.append({"label": label_scope[len("owner:"):], "pane": pane, "birth": birth,
                        "generation": gen, "reason": reason})
    return out


def reap(conn, live_panes: set[tuple[str, str]], now: float | None = None, dry_run: bool = True) -> list[dict]:
    """Release stale owner leases (registry row only; never closes a pane). Dry-run by default."""
    now = time.time() if now is None else now
    stale = stale_owners(conn, live_panes, now)
    if not dry_run:
        for s in stale:
            s["released"] = release(conn, s["label"], s["generation"], now)
    return stale
