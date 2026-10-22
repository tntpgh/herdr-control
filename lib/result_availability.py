"""Result AVAILABILITY receipts for dispatched owner requests (off by default).

The problem: an owner finishes a request, writes its result file, and the
result then sits unread until someone happens to look. This module only
observes and announces. It never authenticates, accepts, forwards or acts.

  AVAILABLE means "the registered artifact files were observed, stable and
  bound to the registered request". It NEVER means the reply is authentic,
  the evidence is accepted, or the work is done. Result text is never read
  for meaning, forwarded, or used as authority for anything.

Off unless HERDR_RESULT_AVAILABILITY=1, HERDR_RESULT_AVAILABILITY_DB and
HERDR_RESULT_AVAILABILITY_ROOTS (os.pathsep-separated absolute roots) are all
set. Off means no scan, no DB open, no notice.

Binding (register): the dispatcher records, at dispatch time, the request id,
its exact request directory, the sha256 of the request text it sent, the
intended owner (label, pane_id, pane_birth, session_id, lease generation from
the authoritative owner-lease route) and an explicit bounded artifact manifest
(plain file names inside that directory). The directory must be a direct
child, named rid, of one of the configured allowed roots. Every open descends
from "/" one component at a time with O_NOFOLLOW under the parent's dir fd,
so no symlink anywhere on the path (ancestor, request dir, or leaf) is ever
followed, and a swapped ancestor cannot redirect a later read. A directory that was never
registered is `unverified_held`: legacy artifacts are never scanned.

tick():
  - registered, non-terminal requests only; no root walk, no glob, no
    traversal, symlinks refused (O_NOFOLLOW under a dir fd);
  - request.txt must still hash to the registered digest -> else held;
  - the owner lease must still be the registered generation/pane -> else
    held:stale_generation;
  - all manifest files present, regular, <= MAX_FILE_BYTES, and identical
    across two CONSECUTIVE ticks -> staged in the durable outbox; a tick that
    finds any file missing/invalid clears the observation;
  - a staged digest that later changes is held:changed and never inherits
    the earlier observation;
  - notice: the digest is re-verified, then a compare-and-set
    (state='staged' AND observed=<that digest>) commits `notifying` BEFORE the
    external call; only the one caller whose CAS changed the row calls out. A row found in
    `notifying` older than NOTIFY_TIMEOUT_S (crash across the boundary), or
    whose call raised/returned non-True, is `ambiguous` and is never retried;
    a younger one is left alone as another caller's in-flight call. `staged` (pre-notice) survives a crash and is retried.
The notice text is fixed: id, short manifest digest, directory. No content.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import stat
import time
from pathlib import Path
from typing import Callable

RID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,100}$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]{0,63}$")
MAX_MANIFEST = 8
MAX_FILE_BYTES = 4 * 1024 * 1024
REQUEST_FILE = "request.txt"
# A `notifying` row younger than this may be another process's in-flight call;
# older means that call crashed or hung past the deliver timeout -> ambiguous.
NOTIFY_TIMEOUT_S = 180
TERMINAL = ("notified", "ambiguous", "held:request_changed", "held:stale_generation", "held:changed",
            "held:invalid")

SCHEMA = """
CREATE TABLE IF NOT EXISTS ra_requests (
  rid TEXT PRIMARY KEY, request_dir TEXT NOT NULL, request_digest TEXT NOT NULL,
  owner_label TEXT NOT NULL, pane_id TEXT NOT NULL, pane_birth TEXT NOT NULL,
  session_id TEXT NOT NULL, generation INTEGER NOT NULL, manifest TEXT NOT NULL,
  state TEXT NOT NULL, observed TEXT, updated_at REAL NOT NULL);
"""

Holder = Callable[[str], "tuple[str, str, str, int] | None"]  # label -> (pane_id, pane_birth, session_id, generation)
Notify = Callable[[str], bool]


class Refused(ValueError):
    pass


def from_env(environ=os.environ) -> "Availability | None":
    if environ.get("HERDR_RESULT_AVAILABILITY") != "1":
        return None
    db = environ.get("HERDR_RESULT_AVAILABILITY_DB")
    roots = [r for r in environ.get("HERDR_RESULT_AVAILABILITY_ROOTS", "").split(os.pathsep) if r]
    if not db or not roots:
        raise Refused("HERDR_RESULT_AVAILABILITY=1 needs HERDR_RESULT_AVAILABILITY_DB and _ROOTS")
    return Availability(db, roots)


def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def classify_unregistered(_path) -> str:
    return "unverified_held"


def _open_dir(path: str) -> int:
    """Dir fd for an absolute path, descending from / with O_NOFOLLOW at every
    component: a symlink anywhere on the path raises OSError."""
    parts = Path(path).parts
    if not parts or parts[0] != "/":
        raise OSError("not absolute")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for comp in parts[1:]:
            if comp in ("", ".", ".."):
                raise OSError("bad component")
            nfd = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nfd
        return fd
    except BaseException:
        os.close(fd)
        raise


class Availability:
    def __init__(self, db_path: str, allowed_roots: list[str]):
        roots = []
        for r in allowed_roots:
            if not os.path.isabs(r) or os.path.normpath(r) != r:
                raise Refused(f"allowed root must be absolute and normalized: {r!r}")
            try:
                os.close(_open_dir(r))  # exists, symlink-free at every component
            except OSError as exc:
                raise Refused(f"allowed root unusable (missing or symlinked): {r!r}") from exc
            roots.append(r)
        if not roots:
            raise Refused("no allowed roots")
        self.roots = tuple(roots)
        self.conn = sqlite3.connect(db_path, isolation_level=None, timeout=10)
        self.conn.executescript(SCHEMA)

    def close(self):
        self.conn.close()

    # --- binding, at dispatch time ---
    def register(self, rid: str, request_dir: str, request_text: bytes, owner_label: str, pane_id: str,
                 pane_birth: str, session_id: str, generation: int, manifest: list[str],
                 now: float | None = None) -> str:
        now = time.time() if now is None else now
        if not RID_RE.match(rid):
            raise Refused("bad rid")
        d = Path(request_dir)
        if d.name != rid or str(d.parent) not in self.roots or os.path.normpath(request_dir) != request_dir:
            raise Refused("request_dir must be <allowed root>/<rid>")
        if not manifest or len(manifest) > MAX_MANIFEST or len(set(manifest)) != len(manifest) \
                or not all(NAME_RE.match(n) for n in manifest) or REQUEST_FILE in manifest:
            raise Refused("manifest must be 1..8 distinct plain file names, excluding request.txt")
        if not (owner_label and pane_id and pane_birth and session_id
                and isinstance(generation, int) and generation > 0):
            raise Refused("owner identity incomplete")
        digest = _sha(request_text)
        if self._read(d, REQUEST_FILE) != (digest, len(request_text)):
            raise Refused("request.txt on disk does not match the dispatched request")
        row = (str(d), digest, owner_label, pane_id, pane_birth, session_id, generation, json.dumps(sorted(manifest)))
        old = self.conn.execute("SELECT request_dir, request_digest, owner_label, pane_id, pane_birth, session_id,"
                                " generation, manifest FROM ra_requests WHERE rid=?", (rid,)).fetchone()
        if old is not None:
            if tuple(old) != row:
                raise Refused("rid already registered with a different binding")
            return "already_registered"
        self.conn.execute("INSERT INTO ra_requests VALUES (?,?,?,?,?,?,?,?,?,'pending',NULL,?)", (rid, *row, now))
        return "registered"

    # --- observation ---
    @staticmethod
    def _read(d: Path, name: str):
        """(sha256, size) of a plain regular file directly inside d, or None.
        No symlink anywhere on the path is followed (_open_dir); never walks."""
        try:
            dfd = _open_dir(str(d))
        except OSError:
            return None
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
        except OSError:
            os.close(dfd)
            return None
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_FILE_BYTES:
                return None
            h, n = hashlib.sha256(), 0
            while chunk := os.read(fd, 65536):
                h.update(chunk)
                n += len(chunk)
            return (h.hexdigest(), n) if n == st.st_size else None
        finally:
            os.close(fd)
            os.close(dfd)

    def _snapshot(self, d: Path, manifest: list[str]) -> str | None:
        parts = []
        for name in manifest:
            r = self._read(d, name)
            if r is None:
                return None
            parts.append(f"{name}:{r[0]}:{r[1]}")
        return _sha("\n".join(parts).encode())

    _KEEP = object()

    def _set(self, rid, state, observed=_KEEP, now=None):
        now = time.time() if now is None else now
        if observed is Availability._KEEP:
            self.conn.execute("UPDATE ra_requests SET state=?, updated_at=? WHERE rid=?", (state, now, rid))
        else:
            self.conn.execute("UPDATE ra_requests SET state=?, observed=?, updated_at=? WHERE rid=?",
                              (state, observed, now, rid))

    def _finish(self, rid, final, now):
        """notifying -> final, only from notifying (never overwrites a row a
        stale-recovery already settled)."""
        cur = self.conn.execute("UPDATE ra_requests SET state=?, updated_at=? WHERE rid=? AND state='notifying'",
                                (final, now, rid))
        return final if cur.rowcount == 1 else self.state(rid)[0]

    def state(self, rid):
        r = self.conn.execute("SELECT state, observed FROM ra_requests WHERE rid=?", (rid,)).fetchone()
        return tuple(r) if r else ("unverified_held", None)

    def tick(self, holder: Holder, notify: Notify, now: float | None = None) -> dict:
        now = time.time() if now is None else now
        out: dict[str, str] = {}
        rows = self.conn.execute("SELECT rid, request_dir, request_digest, owner_label, pane_id, pane_birth,"
                                 " session_id, generation, manifest, state, observed, updated_at FROM ra_requests WHERE state NOT IN"
                                 f" ({','.join('?' * len(TERMINAL))}) ORDER BY rid", TERMINAL).fetchall()
        for rid, rdir, rdig, label, pane, birth, sess, gen, man, st, seen, upd in rows:
            d, manifest = Path(rdir), json.loads(man)
            if st == "notifying":
                if now - upd < NOTIFY_TIMEOUT_S:
                    out[rid] = "in_flight"
                    continue
                self._finish(rid, "ambiguous", now)  # crashed across the notice boundary
                out[rid] = "ambiguous"
                continue
            req = self._read(d, REQUEST_FILE)
            if req is None or req[0] != rdig:
                self._set(rid, "held:request_changed", now=now)
                out[rid] = "held:request_changed"
                continue
            if holder(label) != (pane, birth, sess, gen):
                self._set(rid, "held:stale_generation", now=now)
                out[rid] = "held:stale_generation"
                continue
            snap = self._snapshot(d, manifest)
            if st == "staged":
                if snap != seen:
                    self._set(rid, "held:changed", now=now)
                    out[rid] = "held:changed"
                    continue
                # CAS, committed BEFORE the external side effect: only the one
                # caller that moves this exact staged observation calls out.
                cas = self.conn.execute("UPDATE ra_requests SET state='notifying', updated_at=? WHERE rid=?"
                                        " AND state='staged' AND observed=?", (now, rid, seen))
                if cas.rowcount != 1:
                    out[rid] = "lost_race"
                    continue
                text = (f"RESULT AVAILABLE (UNVERIFIED: artifact observed, not accepted, not done) {rid} "
                        f"manifest {seen[:16]} dir {rdir}")
                try:
                    ok = notify(text) is True
                except Exception:
                    ok = False
                out[rid] = self._finish(rid, "notified" if ok else "ambiguous", now)
                continue
            if snap is None:  # interruption: the next observation starts over
                self._set(rid, "pending", observed=None, now=now)
                out[rid] = "pending"
            elif snap == seen:
                self._set(rid, "staged", now=now)
                out[rid] = "staged"
            else:
                self._set(rid, "observing", observed=snap, now=now)
                out[rid] = "observing"
        return out
