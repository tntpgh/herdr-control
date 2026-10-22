"""Fenced, journaled dispatch of one owner request (INERT: nothing calls it).

dispatch(label, rid, request_text, manifest) is the only way a request becomes
trackable by lib/result_availability.py:

  1. PRE-SEND PREFLIGHT. The label must have its own configured handoff root
     and a live owner lease carrying a session digest
     (owner_lease.holder_tuple). Otherwise nothing is written and nothing is
     sent: "held:not_dispatched:<reason>". That is a typed refusal, never
     "ambiguous": no send was attempted.
  2. IMMUTABLE JOURNAL in a conductor-private root outside every owner
     handoff root: <journal>/<label>/<rid>/ created exclusively (an existing
     rid is a duplicate and is refused). Every journal file is written
     O_CREAT|O_EXCL|O_NOFOLLOW under a dir fd and fsynced, then the directory
     is fsynced. Order: intent.json -> request.txt in the handoff dir ->
     fence re-check -> send -> exactly one outcome file:
       refused.json   fence moved before the send (nothing sent),
       settled.json   the sender returned True (result_availability.settled_record),
       uncertain.json the sender raised/returned anything else, or recover()
                      found an intent with no outcome (crash across the send).
     An outcome is never rewritten and a send is never retried.
  3. Only after settled.json is durable is the request registered for
     availability, bound to that exact settled record.

The sender is injected. This module never calls herdr, never acquires,
renews, reaps or takes over a lease, and never redispatches.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import time
from typing import Callable

import owner_lease as ol
import result_availability as ra

Send = Callable[[str, tuple, bytes], bool]  # (label, holder tuple, request bytes) -> delivered?
OUTCOMES = ("refused.json", "settled.json", "uncertain.json")
RID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,100}$")


class NotDispatched(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _mkdir_at(dfd: int, name: str, exclusive: bool) -> int:
    try:
        os.mkdir(name, 0o700, dir_fd=dfd)
        os.fsync(dfd)
    except FileExistsError:
        if exclusive:
            raise
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
    if not stat.S_ISDIR(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError("not a directory")
    return fd


def _write_excl(dfd: int, name: str, data: bytes) -> None:
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)
    os.fsync(dfd)


def _exists(dfd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=dfd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def _record(**fields) -> bytes:
    return (json.dumps(fields, sort_keys=True, separators=(",", ":")) + "\n").encode()


class Dispatcher:
    def __init__(self, lease_conn, avail: ra.Availability, send: Send):
        self.lease_conn, self.avail, self.send = lease_conn, avail, send

    def dispatch(self, label: str, rid: str, request_text: bytes, manifest: list[str],
                 now: float | None = None) -> str:
        now = time.time() if now is None else now
        try:
            return self._dispatch(label, rid, request_text, manifest, now)
        except NotDispatched as exc:
            return f"held:not_dispatched:{exc.reason}"

    def _dispatch(self, label, rid, request_text, manifest, now):
        root = self.avail.roots.get(label)
        if root is None:
            raise NotDispatched("label_has_no_root")
        if not RID_RE.match(rid) or not isinstance(request_text, bytes) or not request_text:
            raise NotDispatched("bad_request")
        holder = ol.holder_tuple(self.lease_conn, label, now)
        if holder is None:
            raise NotDispatched("no_live_session_lease")
        pane, birth, sess, gen = holder
        digest = hashlib.sha256(request_text).hexdigest()
        # the same manifest rule register() applies, checked before anything is written
        if not isinstance(manifest, list) or not manifest or len(manifest) > ra.MAX_MANIFEST \
                or len(set(manifest)) != len(manifest) or ra.REQUEST_FILE in manifest \
                or not all(isinstance(n, str) and ra.NAME_RE.match(n) for n in manifest):
            raise NotDispatched("bad_manifest")

        jroot = ra._open_dir(self.avail.journal_root)
        try:
            lfd = _mkdir_at(jroot, label, exclusive=False)
        finally:
            os.close(jroot)
        try:
            try:
                jfd = _mkdir_at(lfd, rid, exclusive=True)
            except FileExistsError:
                raise NotDispatched("duplicate_rid") from None
        finally:
            os.close(lfd)
        try:
            _write_excl(jfd, "intent.json", _record(rid=rid, label=label, request_digest=digest, pane_id=pane,
                                                     pane_birth=birth, session_id=sess, generation=gen,
                                                     manifest=sorted(manifest), at=now))
            rfd = ra._open_dir(root)
            try:
                try:
                    hfd = _mkdir_at(rfd, rid, exclusive=True)
                except FileExistsError:
                    _write_excl(jfd, "refused.json", _record(reason="handoff_dir_exists", at=now))
                    raise NotDispatched("handoff_dir_exists") from None
            finally:
                os.close(rfd)
            try:
                _write_excl(hfd, ra.REQUEST_FILE, request_text)
            finally:
                os.close(hfd)
            if ol.holder_tuple(self.lease_conn, label, now) != holder:  # fence, immediately before the send
                _write_excl(jfd, "refused.json", _record(reason="fenced_before_send", at=now))
                raise NotDispatched("fenced_before_send")
            try:
                ok = self.send(label, holder, request_text) is True
            except Exception:
                ok = False
            if not ok:
                _write_excl(jfd, "uncertain.json", _record(reason="send_not_confirmed", at=now))
                return "ambiguous"
            _write_excl(jfd, ra.SETTLED_FILE, ra.settled_record(rid, digest, label, pane, birth, sess, gen, manifest))
        finally:
            os.close(jfd)
        try:
            self.avail.register(rid, os.path.join(root, rid), request_text, label, pane, birth, sess, gen,
                                manifest, now)
        except ra.Refused:
            return "dispatched:unregistered"  # settled, but the handoff changed before binding: never tracked
        return "dispatched"

    def recover(self, now: float | None = None) -> dict[str, str]:
        """An intent with no outcome crashed somewhere around the send: mark it
        uncertain. Never resends, never registers."""
        now = time.time() if now is None else now
        out: dict[str, str] = {}
        jroot = ra._open_dir(self.avail.journal_root)
        try:
            for label in sorted(os.listdir(jroot)):
                try:
                    lfd = os.open(label, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=jroot)
                except OSError:
                    continue
                try:
                    for rid in sorted(os.listdir(lfd)):
                        try:
                            jfd = os.open(rid, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=lfd)
                        except OSError:
                            continue
                        try:
                            if _exists(jfd, "intent.json") and not any(_exists(jfd, o) for o in OUTCOMES):
                                _write_excl(jfd, "uncertain.json", _record(reason="crash_recovered", at=now))
                                out[f"{label}/{rid}"] = "ambiguous"
                        finally:
                            os.close(jfd)
                finally:
                    os.close(lfd)
        finally:
            os.close(jroot)
        return out
