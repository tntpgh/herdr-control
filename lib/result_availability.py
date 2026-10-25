"""Result AVAILABILITY receipts for dispatched owner requests (off by default).

The problem: an owner finishes a request, writes its result file, and the
result then sits unread until someone happens to look. This module only
observes and announces. It never authenticates, accepts, forwards or acts.

  AVAILABLE means "the registered artifact files were observed, stable and
  bound to the registered request". It NEVER means the reply is authentic,
  the evidence is accepted, or the work is done. Result text is never read
  for meaning, forwarded, or used as authority for anything.

Off unless HERDR_RESULT_AVAILABILITY=1, HERDR_RESULT_AVAILABILITY_DB,
HERDR_RESULT_AVAILABILITY_ROOTS (os.pathsep-separated `label=/abs/root`
pairs: each registered owner label maps to EXACTLY one handoff root) and
HERDR_RESULT_AVAILABILITY_JOURNAL (the conductor-private dispatch journal
root, see lib/owner_dispatch.py) are all set. Off means no scan, no DB open,
no notice.

A request is registered only against a SETTLED dispatch: the journal must hold
<journal>/<label>/<rid>/settled.json byte-identical to settled_record() of the
binding being registered. The journal lives outside every owner-writable
handoff root, so an owner cannot forge one. tick() re-hashes it every pass.

Stages are separate, append-only, durable facts (ra_stages), never inferred
from one another: observed -> noticed (the notice), reply_authenticated
(caller-supplied reference from an authenticated channel), verified (artifact
hashes match pins the CALLER supplies, never read from the result body), and
accepted (conductor; requires verified AND reply_authenticated).

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
            "held:invalid", "held:dispatch_changed")
STAGES = ("observed", "noticed", "reply_authenticated", "verified", "accepted")
SETTLED_FILE = "settled.json"

SCHEMA = """
CREATE TABLE IF NOT EXISTS ra_requests (
  rid TEXT PRIMARY KEY, request_dir TEXT NOT NULL, request_digest TEXT NOT NULL,
  owner_label TEXT NOT NULL, pane_id TEXT NOT NULL, pane_birth TEXT NOT NULL,
  session_id TEXT NOT NULL, generation INTEGER NOT NULL, manifest TEXT NOT NULL,
  state TEXT NOT NULL, observed TEXT, updated_at REAL NOT NULL, settled_digest TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS ra_stages (
  rid TEXT NOT NULL REFERENCES ra_requests(rid), stage TEXT NOT NULL, at REAL NOT NULL,
  evidence TEXT NOT NULL, PRIMARY KEY (rid, stage));
CREATE TRIGGER IF NOT EXISTS ra_stages_no_update BEFORE UPDATE ON ra_stages
  BEGIN SELECT RAISE(ABORT, 'ra_stages is append-only'); END;
CREATE TRIGGER IF NOT EXISTS ra_stages_no_delete BEFORE DELETE ON ra_stages
  BEGIN SELECT RAISE(ABORT, 'ra_stages is append-only'); END;
CREATE TABLE IF NOT EXISTS ra_submit_receipts (
  receipt_id TEXT PRIMARY KEY, rid TEXT NOT NULL UNIQUE REFERENCES ra_requests(rid),
  request_digest TEXT NOT NULL, owner_label TEXT NOT NULL, pane_id TEXT NOT NULL,
  pane_birth TEXT NOT NULL, session_id TEXT NOT NULL, generation INTEGER NOT NULL,
  pins TEXT NOT NULL, created_utc REAL NOT NULL, receipt_digest TEXT NOT NULL);
CREATE TRIGGER IF NOT EXISTS ra_submit_receipts_no_update BEFORE UPDATE ON ra_submit_receipts
  BEGIN SELECT RAISE(ABORT, 'ra_submit_receipts is append-only'); END;
CREATE TRIGGER IF NOT EXISTS ra_submit_receipts_no_delete BEFORE DELETE ON ra_submit_receipts
  BEGIN SELECT RAISE(ABORT, 'ra_submit_receipts is append-only'); END;
"""

Holder = Callable[[str], "tuple[str, str, str, int] | None"]  # label -> (pane_id, pane_birth, session_id, generation)
Notify = Callable[[str], bool]


class Refused(ValueError):
    pass


def from_env(environ=os.environ) -> "Availability | None":
    if environ.get("HERDR_RESULT_AVAILABILITY") != "1":
        return None
    db = environ.get("HERDR_RESULT_AVAILABILITY_DB")
    journal = environ.get("HERDR_RESULT_AVAILABILITY_JOURNAL")
    pairs = [r for r in environ.get("HERDR_RESULT_AVAILABILITY_ROOTS", "").split(os.pathsep) if r]
    if not db or not pairs or not journal:
        raise Refused("HERDR_RESULT_AVAILABILITY=1 needs HERDR_RESULT_AVAILABILITY_DB, _ROOTS and _JOURNAL")
    roots: dict[str, str] = {}
    for pair in pairs:
        label, sep, root = pair.partition("=")
        if not sep or label in roots:
            raise Refused(f"_ROOTS entries must be unique label=/abs/root: {pair!r}")
        roots[label] = root
    return Availability(db, roots, journal)


def settled_record(rid: str, request_digest: str, label: str, pane_id: str, pane_birth: str, session_id: str,
                   generation: int, manifest: list[str]) -> bytes:
    """Canonical bytes of a settled dispatch: the one exact form register() accepts."""
    return (json.dumps({"rid": rid, "request_digest": request_digest, "label": label, "pane_id": pane_id,
                        "pane_birth": pane_birth, "session_id": session_id, "generation": generation,
                        "manifest": sorted(manifest), "outcome": "settled"},
                       sort_keys=True, separators=(",", ":")) + "\n").encode()


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


def _usable_root(r: str, what: str) -> str:
    if not isinstance(r, str) or not os.path.isabs(r) or os.path.normpath(r) != r:
        raise Refused(f"{what} must be absolute and normalized: {r!r}")
    try:
        os.close(_open_dir(r))  # exists, symlink-free at every component
    except OSError as exc:
        raise Refused(f"{what} unusable (missing or symlinked): {r!r}") from exc
    return r


class Held:
    """A KNOWN-UNSENT refusal from a notice sender: nothing was typed."""
    __slots__ = ("reason",)

    def __init__(self, reason: str):
        self.reason = reason

    def __repr__(self):
        return f"Held({self.reason!r})"


def notice_text(rid: str, seen: str, rdir: str) -> str:
    return (f"RESULT AVAILABLE (UNVERIFIED: artifact observed, not accepted, not done) {rid} "
            f"manifest {seen[:16]} dir {rdir}")


class Availability:
    def __init__(self, db_path: str, label_roots: dict[str, str], journal_root: str):
        if not isinstance(label_roots, dict) or not label_roots:
            raise Refused("no label roots")
        roots = {}
        for label, r in label_roots.items():
            if not isinstance(label, str) or not NAME_RE.match(label):
                raise Refused(f"bad owner label {label!r}")
            roots[label] = _usable_root(r, "allowed root")
        if len(set(roots.values())) != len(roots):
            raise Refused("each label needs its own handoff root (no shared roots)")
        self.journal_root = _usable_root(journal_root, "journal root")
        for r in roots.values():
            if r == self.journal_root or r.startswith(self.journal_root + os.sep) \
                    or self.journal_root.startswith(r + os.sep):
                raise Refused("journal root must not overlap an owner handoff root")
        self.roots = roots
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
        if d.name != rid or self.roots.get(owner_label) != str(d.parent) or os.path.normpath(request_dir) != request_dir:
            raise Refused("request_dir must be <the owner label's own root>/<rid>")
        if not manifest or len(manifest) > MAX_MANIFEST or len(set(manifest)) != len(manifest) \
                or not all(NAME_RE.match(n) for n in manifest) or REQUEST_FILE in manifest:
            raise Refused("manifest must be 1..8 distinct plain file names, excluding request.txt")
        if not (owner_label and pane_id and pane_birth and session_id
                and isinstance(generation, int) and generation > 0):
            raise Refused("owner identity incomplete")
        digest = _sha(request_text)
        if self._read(d, REQUEST_FILE) != (digest, len(request_text)):
            raise Refused("request.txt on disk does not match the dispatched request")
        settled = _sha(settled_record(rid, digest, owner_label, pane_id, pane_birth, session_id, generation, manifest))
        if self._journal(owner_label, rid) != settled:
            raise Refused("no settled dispatch in the journal for exactly this binding")
        row = (str(d), digest, owner_label, pane_id, pane_birth, session_id, generation, json.dumps(sorted(manifest)),
               settled)
        old = self.conn.execute("SELECT request_dir, request_digest, owner_label, pane_id, pane_birth, session_id,"
                                " generation, manifest, settled_digest FROM ra_requests WHERE rid=?", (rid,)).fetchone()
        if old is not None:
            if tuple(old) != row:
                raise Refused("rid already registered with a different binding")
            return "already_registered"
        self.conn.execute("INSERT INTO ra_requests (rid, request_dir, request_digest, owner_label, pane_id, pane_birth,"
                          " session_id, generation, manifest, settled_digest, state, observed, updated_at)"
                          " VALUES (?,?,?,?,?,?,?,?,?,?,'pending',NULL,?)", (rid, *row, now))
        return "registered"

    def _journal(self, label: str, rid: str) -> str | None:
        r = self._read(Path(self.journal_root) / label / rid, SETTLED_FILE)
        return r[0] if r else None

    # --- item 9: narrow submit-owner-result producer + receipt-based accept ---
    # TRUST LIMIT (state per the spec): this proves the result bytes and the
    # caller's OWN resolved pane identity matched the rid's registered owner
    # incarnation at submit time, and still match at accept time. It is
    # Herdr's same-UID/command-approval boundary only -- NOT human approval,
    # and NOT cryptographic isolation from another process running as the
    # same UID. `caller_pane` must be resolved from process ancestry
    # (lib/pane-guard.sh's caller_pane_from_ancestry) by the CLI BEFORE
    # calling this method -- never a self-asserted env var (security review
    # PR #252, F2: a worker can export HERDR_PANE_ID as anything it likes).
    # `holder` is the SAME Holder protocol tick()/record_reply_authenticated
    # already take (label -> the LIVE (pane_id, pane_birth, session_id,
    # generation), or None) -- this method only COMPARES the caller's
    # resolved pane and the live holder to the rid's registered owner; it
    # never resolves either identity itself.
    def submit_owner_result(self, rid: str, caller_pane: str, holder: Holder,
                            now: float | None = None) -> str | None:
        """Takes rid only (no caller-supplied flags or paths). Every binding
        is DERIVED from the already-registered rid row and the journal.
        Returns the receipt_id on success; None on an ordinary refusal
        (unregistered rid, the rid's owner is no longer the LIVE holder, the
        caller's own pane is not that live holder's pane, journal digest
        mismatch, a manifest file unreadable). Raises Refused only for a
        genuine conflicting resubmit (same rid, different content) -- a
        byte-identical resubmit is idempotent and returns the SAME
        receipt_id, never a second row."""
        row = self.conn.execute(
            "SELECT request_dir, request_digest, owner_label, pane_id, pane_birth, session_id, generation, manifest"
            " FROM ra_requests WHERE rid=?", (rid,)).fetchone()
        if row is None:
            return None
        rdir, rdig, label, pane, birth, sess, gen, man_json = row
        live = holder(label)
        if live is None or live != (pane, birth, sess, gen):
            return None  # the rid's registered owner is no longer the live lease holder
        if caller_pane != pane:
            return None  # the CALLING process (resolved from ancestry) is not that live owner's pane
        manifest = json.loads(man_json)
        if self._journal(label, rid) != _sha(settled_record(rid, rdig, label, pane, birth, sess, gen, manifest)):
            return None
        pins: dict[str, str] = {}
        for name in sorted(manifest):
            got = self._read(Path(rdir), name)
            if got is None:
                return None
            pins[name] = got[0]
        evidence = json.dumps({"rid": rid, "request_digest": rdig, "owner": [pane, birth, sess, gen], "pins": pins},
                              sort_keys=True)
        receipt_digest = _sha(evidence.encode())
        receipt_id = f"recv_{receipt_digest[:32]}"
        now = time.time() if now is None else now
        try:
            self.conn.execute(
                "INSERT INTO ra_submit_receipts (receipt_id, rid, request_digest, owner_label, pane_id, pane_birth,"
                " session_id, generation, pins, created_utc, receipt_digest) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (receipt_id, rid, rdig, label, pane, birth, sess, gen, json.dumps(pins, sort_keys=True), now,
                 receipt_digest))
            return receipt_id
        except sqlite3.IntegrityError:
            prior = self.conn.execute("SELECT receipt_digest FROM ra_submit_receipts WHERE rid=?", (rid,)).fetchone()
            if prior is None:
                raise  # receipt_id collided with a DIFFERENT rid: astronomically unlikely; surface it, never swallow
            if prior[0] != receipt_digest:
                raise Refused(f"{rid}: a receipt already exists with different content (conflicting resubmit)") from None
            return receipt_id

    def accept_receipt(self, receipt_id: str, reviewer_pins: dict[str, str], holder: Holder, by: str,
                       now: float | None = None) -> bool:
        """Consumer (item 9): input is receipt_id plus the INDEPENDENT
        reviewer pins only -- no rid, no auth-ref. Re-verifies every binding
        FRESH (the receipt's own digest, the rid row, the journal, the
        owner's CURRENT live incarnation via `holder`, and the receipt's own
        pins against the CURRENT bytes) before separately requiring the
        reviewer's pins to ALSO match. Writes the SAME 'accepted' stage the
        old verify_pinned/record_reply_authenticated/accept pipeline uses
        (lib/queue_supervisor's lane-completion check is unchanged: it only
        ever looks for "accepted" in stages(rid)), but this path has its own
        complete, self-contained precondition chain -- it never depends on
        and never requires 'verified'/'reply_authenticated' from that other
        pipeline."""
        row = self.conn.execute(
            "SELECT rid, request_digest, owner_label, pane_id, pane_birth, session_id, generation, pins,"
            " receipt_digest FROM ra_submit_receipts WHERE receipt_id=?", (receipt_id,)).fetchone()
        if row is None:
            return False
        rid, rdig, label, pane, birth, sess, gen, pins_json, receipt_digest = row
        try:
            pins = json.loads(pins_json)
            recomputed = _sha(json.dumps(
                {"rid": rid, "request_digest": rdig, "owner": [pane, birth, sess, gen], "pins": pins},
                sort_keys=True).encode())
        except (TypeError, ValueError, json.JSONDecodeError):
            return False  # a stored column has the wrong type/shape: fail closed, never raise to the caller
        if recomputed != receipt_digest:
            return False  # the receipt row itself was forged or edited
        rrow = self.conn.execute(
            "SELECT request_dir, request_digest, owner_label, pane_id, pane_birth, session_id, generation, manifest"
            " FROM ra_requests WHERE rid=?", (rid,)).fetchone()
        if rrow is None:
            return False
        rdir, cur_rdig, cur_label, cur_pane, cur_birth, cur_sess, cur_gen, man_json = rrow
        if (cur_rdig, cur_label, cur_pane, cur_birth, cur_sess, cur_gen) != (rdig, label, pane, birth, sess, gen):
            return False  # the rid row disagrees with the receipt it was issued against
        manifest = json.loads(man_json)
        if self._journal(label, rid) != _sha(settled_record(rid, rdig, label, pane, birth, sess, gen, manifest)):
            return False  # the request was mutated in the journal since the receipt
        live = holder(label)
        if live != (pane, birth, sess, gen):
            return False  # the owner is no longer the SAME live incarnation the receipt was issued to
        for name, sha in pins.items():
            got = self._read(Path(rdir), name)
            if got is None or got[0] != sha:
                return False  # the result changed since the receipt was issued
        if sorted(reviewer_pins) != sorted(manifest):
            return False
        for name, sha in reviewer_pins.items():
            got = self._read(Path(rdir), name)
            if got is None or got[0] != sha:
                return False  # the independent reviewer's own pins do not match the current bytes
        return self._stage(rid, "accepted", receipt_id, time.time() if now is None else now)


    # --- stages (separate durable facts; none implies another) ---
    def stages(self, rid) -> dict[str, str]:
        return dict(self.conn.execute("SELECT stage, evidence FROM ra_stages WHERE rid=?", (rid,)).fetchall())

    def _stage(self, rid, stage, evidence, now) -> bool:
        """Write-once. A repeat is accepted only with byte-identical evidence;
        conflicting evidence raises Refused. Any other DB error propagates."""
        try:
            self.conn.execute("INSERT INTO ra_stages VALUES (?,?,?,?)", (rid, stage, now, evidence))
            return True
        except sqlite3.IntegrityError:
            prior = self.conn.execute("SELECT evidence FROM ra_stages WHERE rid=? AND stage=?", (rid, stage)).fetchone()
            if prior is None:
                raise
            if prior[0] != evidence:
                raise Refused(f"{rid}: {stage} already recorded with different evidence") from None
            return True

    def record_reply_authenticated(self, rid: str, auth_ref: str, now: float | None = None) -> bool:
        """auth_ref names the AUTHENTICATED channel record (e.g. a verified
        inbox exchange id) checked by the caller. Never derived from the result."""
        if not auth_ref or "observed" not in self.stages(rid):
            return False
        return self._stage(rid, "reply_authenticated", auth_ref, time.time() if now is None else now)

    def verify_pinned(self, rid: str, pins: dict[str, str], now: float | None = None) -> bool:
        """pins: {manifest name: sha256} supplied by the CALLER (the request's own
        expectations), covering the manifest exactly. Bound to ONE durable
        occurrence: the request must be `notified`, its observed and noticed
        stages must name the same snapshot, the files re-read now must still be
        that snapshot, and every pin must match it."""
        row = self.conn.execute("SELECT request_dir, manifest, state, observed FROM ra_requests WHERE rid=?",
                                (rid,)).fetchone()
        if not row or row[2] != "notified":
            return False
        st = self.stages(rid)
        occ = st.get("observed")
        if not occ or st.get("noticed") != occ or row[3] != occ:
            return False
        manifest = json.loads(row[1])
        if sorted(pins) != manifest or not all(re.fullmatch(r"[0-9a-f]{64}", v or "") for v in pins.values()):
            return False
        if self._snapshot(Path(row[0]), manifest) != occ:
            return False
        for name in manifest:
            got = self._read(Path(row[0]), name)
            if got is None or got[0] != pins[name]:
                return False
        evidence = json.dumps({"occurrence": occ, "pins": _sha(json.dumps(pins, sort_keys=True).encode())},
                              sort_keys=True)
        return self._stage(rid, "verified", evidence, time.time() if now is None else now)

    def accept(self, rid: str, by: str, now: float | None = None) -> bool:
        st = self.stages(rid)
        if not by or "verified" not in st or "reply_authenticated" not in st:
            return False
        return self._stage(rid, "accepted", by, time.time() if now is None else now)

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

    def tick(self, holder: Holder, notify: Notify, now: float | None = None,
             ready: Callable[[], bool] | None = None, prepare: Callable[[str, str], object] | None = None) -> dict:
        """ready(): the notifier's own pre-send fence (e.g. a live conductor
        lease). False -> "held:not_dispatched": the row stays staged, nothing
        is sent, nothing is ambiguous.
        prepare(rid, text): every pre-send check (admit, body binding, fresh
        identity, begin_notice) BEFORE the notifying CAS. Held -> row stays
        staged, never notifying. Otherwise its result is passed as
        notify(text, prepared); notify returning Held (known unsent at the
        typing boundary) puts the row back to staged, never ambiguous."""
        now = time.time() if now is None else now
        out: dict[str, str] = {}
        rows = self.conn.execute("SELECT rid, request_dir, request_digest, owner_label, pane_id, pane_birth,"
                                 " session_id, generation, manifest, state, observed, updated_at, settled_digest"
                                 " FROM ra_requests WHERE state NOT IN"
                                 f" ({','.join('?' * len(TERMINAL))}) ORDER BY rid", TERMINAL).fetchall()
        for rid, rdir, rdig, label, pane, birth, sess, gen, man, st, seen, upd, sdig in rows:
            d, manifest = Path(rdir), json.loads(man)
            if st == "notifying":
                if now - upd < NOTIFY_TIMEOUT_S:
                    out[rid] = "in_flight"
                    continue
                self._finish(rid, "ambiguous", now)  # crashed across the notice boundary
                out[rid] = "ambiguous"
                continue
            if self._journal(label, rid) != sdig:
                self._set(rid, "held:dispatch_changed", now=now)
                out[rid] = "held:dispatch_changed"
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
                if ready is not None and not ready():
                    out[rid] = "held:not_dispatched"
                    continue
                # CAS, committed BEFORE the external side effect: only the one
                # caller that moves this exact staged observation calls out.
                text = notice_text(rid, seen, rdir)
                prepared = None
                if prepare is not None:
                    try:
                        prepared = prepare(rid, text)
                    except Exception as exc:
                        prepared = Held(f"prepare_error:{type(exc).__name__}")
                    if isinstance(prepared, Held):
                        out[rid] = f"held:not_dispatched:{prepared.reason}"
                        continue
                cas = self.conn.execute("UPDATE ra_requests SET state='notifying', updated_at=? WHERE rid=?"
                                        " AND state='staged' AND observed=?", (now, rid, seen))
                if cas.rowcount != 1:
                    out[rid] = "lost_race"
                    continue
                try:
                    res = notify(text) if prepare is None else notify(text, prepared)
                except Exception:
                    res = False
                if isinstance(res, Held):
                    self.conn.execute("UPDATE ra_requests SET state='staged', updated_at=? WHERE rid=?"
                                      " AND state='notifying'", (now, rid))
                    out[rid] = f"held:not_dispatched:{res.reason}"
                    continue
                out[rid] = self._finish(rid, "notified" if res is True else "ambiguous", now)
                if out[rid] == "notified":
                    self._stage(rid, "noticed", seen, now)
                continue
            if snap is None:  # interruption: the next observation starts over
                self._set(rid, "pending", observed=None, now=now)
                out[rid] = "pending"
            elif snap == seen:
                self._set(rid, "staged", now=now)
                self._stage(rid, "observed", snap, now)
                out[rid] = "staged"
            else:
                self._set(rid, "observing", observed=snap, now=now)
                out[rid] = "observing"
        return out


class GatedNotice:
    """Result-availability notice through the conductor's owner-lease
    DeliveryGate (the same admit/begin_notice/settle path as every owner
    delivery). The exchange id is deterministic and binds the body:
    "ra-notice-" + sha256(text) full hex, so a different body is a different
    request and a repeated body is the same (never re-admitted once settled).
      bound(label) -> (pane, birth, session, generation) only while the
                      registry names that exact lease holder, else None.
      send(pane, text) -> True only on a confirmed type."""

    def __init__(self, gate, label: str, bound: Callable[[str], tuple | None],
                 send: Callable[[str, str], bool], clock: Callable[[], float] = time.time):
        self.gate, self.label, self.bound, self.send, self.clock = gate, label, bound, send, clock

    @staticmethod
    def exchange_id(text: str) -> str:
        return "ra-notice-" + hashlib.sha256(text.encode()).hexdigest()

    def prepare(self, rid: str, text: str):
        cur = self.bound(self.label)
        if cur is None:
            return Held("conductor_identity_gone")
        pane, birth, sess, gen = cur
        xid, now = self.exchange_id(text), self.clock()
        adm = self.gate.admit(self.label, pane, birth, xid, now)
        if not adm.ok:
            return Held(adm.reason)
        if adm.generation != gen:
            self.gate.settle(self.label, pane, birth, adm.generation, xid, "blocked", "admit_generation_changed", now)
            return Held("admit_generation_changed")
        began = self.gate.begin_notice(self.label, pane, birth, gen, xid, self.clock())
        if began != "delivering":
            if began != "lease_too_short":  # too short stays queued: re-admitted after renewal
                self.gate.settle(self.label, pane, birth, gen, xid, "blocked", began, self.clock())
            return Held(began)
        return {"xid": xid, "digest": hashlib.sha256(text.encode()).hexdigest(), "holder": cur}

    def notify(self, text: str, ctx) -> object:
        pane, birth, sess, gen = ctx["holder"]
        if hashlib.sha256(text.encode()).hexdigest() != ctx["digest"]:
            self.gate.settle(self.label, pane, birth, gen, ctx["xid"], "blocked", "body_changed", self.clock())
            return Held("body_changed")
        if self.bound(self.label) != ctx["holder"]:  # fresh registry/lease/session/generation at the boundary
            self.gate.settle(self.label, pane, birth, gen, ctx["xid"], "blocked", "identity_changed_pre_send", self.clock())
            return Held("identity_changed_pre_send")
        try:
            ok = self.send(pane, text) is True
        except Exception:
            ok = False
        t = self.clock()
        if ok:
            self.gate.settle(self.label, pane, birth, gen, ctx["xid"], "delivered", "", t)
            return True
        self.gate.settle(self.label, pane, birth, gen, ctx["xid"], "failed", "send_not_confirmed", t)
        return False
