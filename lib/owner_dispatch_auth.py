"""Owner-dispatch authorization contract (INERT: no issuer, no live store).

Why a new contract: the existing approval records do not authorize "send
request R to owner L".
  - `approvals` (lib/run-registry.sh) records pane approval-prompt decisions
    (prompt_id, choice, policy_verdict, free-form command): no owner, request
    or body digest.
  - `action_requests` (lib/action-request.sh, task-authorization.py
    action_consume) is a one-shot grant bound to a worker TASK's tool call
    (run_id, task_id, tool, action_sha256), so it cannot name an owner
    request.
A free-form command string is never hashed or re-parsed into authority.

Contract `owner-dispatch-auth/2`: one row is one grant, bound to protocol,
owner label AND canonical project, the exact owner holder (pane_id,
pane_birth, full session digest, lease generation), request id, exact body
sha256, sorted manifest, the prompt/approval identity that decided it, a
one-time auth id and an explicit expiry. A grant therefore cannot follow a
replacement owner or a later lease generation, and an unused grant dies at
expires_at. consume() is one BEGIN IMMEDIATE check-and-set: exactly one caller
turns `granted` into `consumed`. Everything else is a typed hold:
  missing | denied | consumed | expired | mismatch | ambiguous (store error).

Consumed-but-unsent: consumption happens before admission and before any
journal write, so a crash or a queue refusal after it burns the grant with no
journal entry. consume() returns the complete consumed ENVELOPE (auth_id,
binding, consumed_at); the Dispatcher writes it into the immutable
intent.json. unsent() accepts a consumed grant as accounted for ONLY when
<journal>/<label>/<rid>/intent.json, read through no-follow descriptors as a
bounded regular file, parses and carries exactly that envelope. A missing,
older, symlinked, malformed or different intent leaves it unsent. Callers
hold on any such entry: never retried, never regranted.

This module has NO function that writes a grant. A worker or caller cannot
authorize itself. Issuing a grant is a separate, unapproved surface; tests
insert fixture rows directly into a disposable store.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
import time

import private_sqlite

PROTOCOL = "owner-dispatch-auth/2"
MAX_REQUEST_BYTES = 64 * 1024

SCHEMA = """CREATE TABLE IF NOT EXISTS owner_dispatch_auth (
  auth_id      TEXT PRIMARY KEY,
  protocol     TEXT NOT NULL,
  owner_label  TEXT NOT NULL,
  project      TEXT NOT NULL,
  pane_id      TEXT NOT NULL,
  pane_birth   TEXT NOT NULL,
  session_digest TEXT NOT NULL,
  lease_generation INTEGER NOT NULL,
  request_id   TEXT NOT NULL,
  body_sha256  TEXT NOT NULL,
  manifest     TEXT NOT NULL,
  prompt_id    TEXT NOT NULL,
  approval_id  TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('granted','denied','consumed')),
  decided_at   TEXT NOT NULL,
  expires_at   REAL NOT NULL,
  consumed_at  TEXT
)"""


def migrate(conn: sqlite3.Connection) -> None:
    """Creates the table in a store the CALLER chose (tests: a temp file)."""
    conn.execute(SCHEMA)


def manifest_key(manifest) -> str:
    return json.dumps(sorted(manifest), separators=(",", ":"))


ENVELOPE_COLS = ("auth_id", "protocol", "owner_label", "project", "pane_id", "pane_birth", "session_digest",
                 "lease_generation", "request_id", "body_sha256", "manifest", "prompt_id", "approval_id", "consumed_at")


def _envelope(conn, auth_id) -> dict:
    row = conn.execute(f"SELECT {','.join(ENVELOPE_COLS)} FROM owner_dispatch_auth WHERE auth_id=?", (auth_id,)).fetchone()
    return dict(zip(ENVELOPE_COLS, row)) if row else {}


def consume(conn: sqlite3.Connection, auth_id: str, *, label: str, project: str, holder, request_id: str,
            body_sha256: str, manifest, now: float):
    """The consumed envelope (dict) when THIS call consumed the grant, else a
    hold reason (str). Never raises.
    holder = the resolved (pane_id, pane_birth, session_digest, generation)."""
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            row = conn.execute("SELECT protocol, owner_label, project, pane_id, pane_birth, session_digest,"
                               " lease_generation, request_id, body_sha256, manifest, prompt_id, approval_id,"
                               " status, expires_at FROM owner_dispatch_auth WHERE auth_id=?",
                               (auth_id,)).fetchone()
            if row is None:
                return "auth_missing"
            *bound, prompt, approval, st, exp = row
            want = (PROTOCOL, label, project, *tuple(holder), request_id, body_sha256, manifest_key(manifest))
            if tuple(bound) != want or not prompt or not approval or not project:
                return "auth_mismatch"
            if st == "denied":
                return "auth_denied"
            if st == "consumed":
                return "auth_consumed"
            if not isinstance(exp, (int, float)) or now >= exp:
                return "auth_expired"
            changed = conn.execute("UPDATE owner_dispatch_auth SET status='consumed', consumed_at=?"
                                   " WHERE auth_id=? AND status='granted'",
                                   (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), auth_id)).rowcount
            if changed != 1:
                return "auth_consumed"
            env = _envelope(conn, auth_id)
            conn.execute("COMMIT")
            return env
        finally:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
    except (sqlite3.Error, TypeError, ValueError) as exc:
        return f"auth_ambiguous:{type(exc).__name__}"


def _read_intent(journal_root: str, label: str, rid: str) -> dict | None:
    """intent.json via O_NOFOLLOW directory/file descriptors, regular file,
    bounded; None on any irregularity."""
    fds = []
    try:
        fds.append(os.open(journal_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
        for part in (label, rid):
            if not part or "/" in part or part in (".", ".."):
                return None
            fds.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
        fd = os.open("intent.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fds[-1])
        fds.append(fd)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_REQUEST_BYTES:
            return None
        data = os.read(fd, MAX_REQUEST_BYTES + 1)
        obj = json.loads(data)
        return obj if isinstance(obj, dict) else None
    except (OSError, ValueError):
        return None
    finally:
        for f in fds:
            os.close(f)


def unsent(conn: sqlite3.Connection, journal_root: str) -> list[str]:
    """auth_ids of consumed grants NOT accounted for by an intent.json that
    carries exactly their consumed envelope. Read-only."""
    out = []
    for (aid,) in conn.execute("SELECT auth_id FROM owner_dispatch_auth WHERE status='consumed' ORDER BY auth_id").fetchall():
        env = _envelope(conn, aid)
        intent = _read_intent(journal_root, env["owner_label"], env["request_id"])
        if not intent or intent.get("auth") != env or intent.get("rid") != env["request_id"] \
                or intent.get("label") != env["owner_label"]:
            out.append(aid)
    return out


def open_store(path: str, uid: int | None = None) -> sqlite3.Connection:
    """The EXISTING auth store, via lib/private_sqlite.open_private (canonical
    path, private file/parents/sidecars, post-open inode check). Never creates."""
    return private_sqlite.open_private(
        path, lambda p: sqlite3.connect(f"file:{p}?mode=rw", uri=True, isolation_level=None, timeout=10),
        uid, require_table="owner_dispatch_auth")


def read_request_once(parent: str, name: str, max_bytes: int = MAX_REQUEST_BYTES) -> bytes:
    """The request bytes, read ONCE through a bounded regular-file descriptor
    opened O_NOFOLLOW under the exact canonical parent. Raises ValueError."""
    if not os.path.isabs(parent) or os.path.realpath(parent) != parent:
        raise ValueError("parent_not_canonical")
    if not name or "/" in name or name in (".", ".."):
        raise ValueError("bad_name")
    dfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    finally:
        os.close(dfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("not_regular_file")
        if st.st_size == 0 or st.st_size > max_bytes:
            raise ValueError("bad_size")
        chunks, left = [], max_bytes + 1
        while left > 0:
            b = os.read(fd, left)
            if not b:
                break
            chunks.append(b)
            left -= len(b)
        data = b"".join(chunks)
        if len(data) > max_bytes or len(data) != st.st_size:
            raise ValueError("changed_while_reading")
        return data
    finally:
        os.close(fd)


def body_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
