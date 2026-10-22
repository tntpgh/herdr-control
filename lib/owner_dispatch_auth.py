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

Contract `owner-dispatch-auth/1`: one row is one grant, bound to protocol,
owner label, request id, exact body sha256, sorted manifest, the
prompt/approval identity that decided it, and a one-time auth id. consume()
is one BEGIN IMMEDIATE check-and-set: exactly one caller turns `granted` into
`consumed`. Everything else is a typed hold:
  missing | denied | consumed | mismatch | ambiguous (store error).

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

PROTOCOL = "owner-dispatch-auth/1"
MAX_REQUEST_BYTES = 64 * 1024

SCHEMA = """CREATE TABLE IF NOT EXISTS owner_dispatch_auth (
  auth_id      TEXT PRIMARY KEY,
  protocol     TEXT NOT NULL,
  owner_label  TEXT NOT NULL,
  request_id   TEXT NOT NULL,
  body_sha256  TEXT NOT NULL,
  manifest     TEXT NOT NULL,
  prompt_id    TEXT NOT NULL,
  approval_id  TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('granted','denied','consumed')),
  decided_at   TEXT NOT NULL,
  consumed_at  TEXT
)"""


def migrate(conn: sqlite3.Connection) -> None:
    """Creates the table in a store the CALLER chose (tests: a temp file)."""
    conn.execute(SCHEMA)


def manifest_key(manifest) -> str:
    return json.dumps(sorted(manifest), separators=(",", ":"))


def consume(conn: sqlite3.Connection, auth_id: str, *, label: str, request_id: str, body_sha256: str,
            manifest) -> str:
    """'ok' (this call consumed the grant) or a hold reason. Never raises."""
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            row = conn.execute("SELECT protocol, owner_label, request_id, body_sha256, manifest, prompt_id,"
                               " approval_id, status FROM owner_dispatch_auth WHERE auth_id=?",
                               (auth_id,)).fetchone()
            if row is None:
                return "auth_missing"
            proto, olabel, rid, sha, man, prompt, approval, st = row
            if (proto, olabel, rid, sha, man) != (PROTOCOL, label, request_id, body_sha256, manifest_key(manifest)) \
                    or not prompt or not approval:
                return "auth_mismatch"
            if st == "denied":
                return "auth_denied"
            if st == "consumed":
                return "auth_consumed"
            changed = conn.execute("UPDATE owner_dispatch_auth SET status='consumed', consumed_at=?"
                                   " WHERE auth_id=? AND status='granted'",
                                   (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), auth_id)).rowcount
            if changed != 1:
                return "auth_consumed"
            conn.execute("COMMIT")
            return "ok"
        finally:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
    except (sqlite3.Error, TypeError, ValueError) as exc:
        return f"auth_ambiguous:{type(exc).__name__}"


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
