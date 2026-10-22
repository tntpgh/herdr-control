"""Open an EXISTING private SQLite database by exact path (auth store, lease DB).

Checks, before AND after the connection exists:
  - path absolute and canonical (realpath equal: no symlink in any component);
  - every ancestor directory owned by uid or root and not group/other
    writable (a parent anyone else can write lets them swap the file);
  - the file a regular non-symlink owned by uid with no group/other bits;
  - any -wal / -shm / -journal sidecar likewise private and regular;
  - post-open identity: a descriptor opened O_NOFOLLOW before connecting and
    the path re-stat after SQLite has read the file must name the SAME
    (st_dev, st_ino); otherwise the connection is closed and refused.
SQLite creates new sidecars with the process umask, so callers run under
umask 077 (owner-dispatch.py / owner-lease-claim.py set it).

Not race-proof: a same-UID process can still swap the file between SQLite's
own open() and the post-open check and swap it back. Same-UID writers are
outside this boundary (docs/approval-policy.md rule 7); the checks remove the
cross-user, symlink and stale-sidecar cases, and detect a persisting swap.
Never creates a database. Raises ValueError with a typed reason.
"""
from __future__ import annotations

import os
import sqlite3
import stat

SIDECARS = ("-wal", "-shm", "-journal")


def _private_regular(st, uid) -> bool:
    return stat.S_ISREG(st.st_mode) and st.st_uid == uid and st.st_mode & 0o077 == 0


def check(path: str, uid: int | None = None) -> tuple[int, int]:
    """Pre-open checks; returns (st_dev, st_ino) of the file."""
    uid = os.getuid() if uid is None else uid
    if not isinstance(path, str) or not os.path.isabs(path) or os.path.realpath(path) != path:
        raise ValueError("db_path_not_canonical")
    d = os.path.dirname(path)
    while True:
        pst = os.lstat(d)
        if not stat.S_ISDIR(pst.st_mode) or pst.st_uid not in (uid, 0) or (pst.st_mode & 0o022 and not pst.st_mode & stat.S_ISVTX) \
                or (d == os.path.dirname(path) and (pst.st_uid != uid or pst.st_mode & 0o022)):
            raise ValueError("db_parent_unprotected")
        if d == "/":
            break
        d = os.path.dirname(d)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        raise ValueError("db_missing") from None
    if not _private_regular(st, uid):
        raise ValueError("db_not_private_regular")
    for sfx in SIDECARS:
        try:
            sst = os.lstat(path + sfx)
        except FileNotFoundError:
            continue
        if not _private_regular(sst, uid):
            raise ValueError("db_sidecar_unsafe")
    return st.st_dev, st.st_ino


def open_private(path: str, connect, uid: int | None = None, require_table: str = ""):
    """connect(path) -> sqlite3.Connection (e.g. owner_lease.connect). Returns
    the connection only when pre- and post-open identity agree."""
    ident = check(path, uid)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fst = os.fstat(fd)
        if (fst.st_dev, fst.st_ino) != ident:
            raise ValueError("db_swapped_before_open")
        conn = connect(path)
        try:
            # force SQLite to actually open and read the file
            have = conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
            if require_table and (require_table,) not in have:
                raise ValueError("db_not_migrated")
            after = check(path, uid)
            if after != ident:
                raise ValueError("db_swapped_after_open")
        except BaseException:
            conn.close()
            raise
        return conn
    finally:
        os.close(fd)


def verify_same(path: str, ident: tuple[int, int], uid: int | None = None) -> None:
    if check(path, uid) != ident:
        raise ValueError("db_swapped_after_open")
