"""Fenced, journaled dispatch of one owner request (INERT: nothing calls it).

dispatch(label, rid, request_text, manifest) is the only way a request becomes
trackable by lib/result_availability.py:

  1. PRE-SEND PREFLIGHT. The label must have its own configured handoff root
     and an owner_projects mapping (never created here);
     the live lease tuple (owner_lease.holder_tuple) must EQUAL the read-only
     registry resolver's (pane, birth, session); and the publisher's real
     a one-time owner-dispatch-auth/1 grant for exactly (label, rid, body
     sha256, sorted manifest) must be consumed (lib/owner_dispatch_auth.py);
     and the publisher's real
     DeliveryGate.admit() (owner_lease.enqueue: bounded max_open queue,
     duplicate and approval-retry fences) must grant it. Otherwise nothing is
     written and nothing is sent: "held:not_dispatched:<reason>".
  2. IMMUTABLE JOURNAL in a conductor-private root outside every owner
     handoff root: <journal>/<label>/<rid>/ created exclusively (an existing
     rid is a duplicate and is refused). Every journal file is written
     O_CREAT|O_EXCL|O_NOFOLLOW under a dir fd and fsynced, then the directory
     is fsynced. Order: intent.json -> request.txt in the handoff dir ->
     FRESH clock read -> registry+lease re-check -> DeliveryGate.begin_notice
     (lease must outlive DELIVERY_TIMEOUT_S + SAFETY_MARGIN_S) -> send ->
     DeliveryGate.settle -> exactly one outcome file:
       refused.json   fence moved before the send (nothing sent),
       settled.json   the sender returned True (result_availability.settled_record),
       uncertain.json the sender raised/returned anything else, or recover()
                      found an intent with no outcome (crash across the send).
     An outcome is never rewritten and a send is never retried.
  3. Only after settled.json is durable is the request registered for
     availability, bound to that exact settled record. recover() registers a
     settled-but-unregistered dispatch idempotently and never resends.

The sender and registry resolver are injected. This module never calls
herdr, never acquires, renews, reaps or takes over a lease, never redispatches.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import time
from pathlib import Path
from typing import Callable

import owner_lease as ol
import result_availability as ra

Send = Callable[[str, tuple, bytes], bool]  # (label, holder tuple, request bytes) -> delivered?
OUTCOMES = ("refused.json", "settled.json", "uncertain.json")
POST_SEND_DETAIL = "send_not_confirmed"   # gate detail that marks a send that may have happened
SETTLED_GATE_STATES = ("delivering", "replied", "evidence")
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


Resolve = Callable[[str], "tuple[str, str, str] | None"]  # label -> registry (pane_id, pane_birth, session_digest)
# (label, project, holder (pane, birth, session, generation), rid, body sha256,
# manifest, now) -> the consumed envelope (dict, lib/owner_dispatch_auth.consume)
# when THIS call consumed a one-time grant bound to all of them; else a hold
# reason. The envelope must restate exactly this call's binding.
Authorize = Callable[[str, str, tuple, str, str, list, float], "dict | str"]


class Dispatcher:
    """gate: the publisher's lib/owner_lease_delivery.DeliveryGate (its queue,
    max_open, approval/retry fences and lease-remaining margin are the ONLY
    admission path). resolve: a read-only lookup of the EXISTING owner
    registry. clock: read fresh immediately before the send."""

    def __init__(self, gate, avail: ra.Availability, send: Send, resolve: Resolve,
                 clock: Callable[[], float] = time.time, authorize: Authorize | None = None):
        self.gate, self.avail, self.send, self.resolve, self.clock = gate, avail, send, resolve, clock
        self.authorize = authorize  # None: every dispatch holds (auth_missing)

    def _bound(self, label, now):
        """The lease holder, only when the registry names exactly that
        (pane, birth, session); else None."""
        holder = ol.holder_tuple(self.gate.conn, label, now)
        try:
            reg = self.resolve(label)
        except Exception:
            reg = None
        if holder is None or reg is None or tuple(reg) != holder[:3]:
            return None
        return holder

    def dispatch(self, label: str, rid: str, request_text: bytes, manifest: list[str],
                 now: float | None = None) -> str:
        now = self.clock() if now is None else now
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
        if not isinstance(manifest, list) or not manifest or len(manifest) > ra.MAX_MANIFEST \
                or len(set(manifest)) != len(manifest) or ra.REQUEST_FILE in manifest \
                or not all(isinstance(n, str) and ra.NAME_RE.match(n) for n in manifest):
            raise NotDispatched("bad_manifest")
        # An owner_projects mapping is required and never created here: the
        # registry row does not imply one.
        mapped = self.gate.conn.execute("SELECT project FROM owner_projects WHERE label=?", (label,)).fetchone()
        if not mapped:
            raise NotDispatched("owner_project_unmapped")
        holder = self._bound(label, now)
        if holder is None:
            raise NotDispatched("registry_lease_mismatch")
        pane, birth, sess, gen = holder
        # One-time authorization, consumed BEFORE admission or any file write.
        # The journal is now opened immediately below, BEFORE gate.admit(): a
        # refused or crashed admission is therefore always durable (intent.json
        # exists with this call's consumed envelope), so
        # owner_dispatch_auth.unsent() -- which only checks THAT intent.json
        # against the consumed envelope, never a terminal outcome -- never
        # again surfaces a refused admission as consumed-unsent.
        if self.authorize is None:
            raise NotDispatched("auth_missing")
        body_sha = hashlib.sha256(request_text).hexdigest()
        try:
            verdict = self.authorize(label, mapped[0], tuple(holder), rid, body_sha, sorted(manifest), now)
        except Exception as exc:
            verdict = f"auth_ambiguous:{type(exc).__name__}"
        if not isinstance(verdict, dict):
            raise NotDispatched(verdict if isinstance(verdict, str) else "auth_not_envelope")
        want = {"owner_label": label, "project": mapped[0], "pane_id": pane, "pane_birth": birth,
                "session_digest": sess, "lease_generation": gen, "request_id": rid, "body_sha256": body_sha,
                "manifest": json.dumps(sorted(manifest), separators=(",", ":"))}
        if any(verdict.get(k) != v for k, v in want.items()) or not verdict.get("auth_id"):
            raise NotDispatched("auth_envelope_mismatch")
        auth_envelope = verdict
        digest = hashlib.sha256(request_text).hexdigest()

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
            # Written BEFORE admission runs: gate_generation/gate_state are
            # provisional (admission has not happened yet) and are never
            # re-read by recovery -- only request_digest/pane_id/pane_birth/
            # session_id/generation/manifest are (see _register, recover()).
            _write_excl(jfd, "intent.json", _record(rid=rid, label=label, request_digest=digest, pane_id=pane,
                                                     pane_birth=birth, session_id=sess, generation=gen,
                                                     manifest=sorted(manifest), gate_request_id=rid,
                                                     gate_generation=None, gate_state="pending_admission", at=now,
                                                     auth=auth_envelope))

            adm = self.gate.admit(label, pane, birth, rid, now)
            if not adm.ok or adm.generation != gen:
                reason = adm.reason or "admit_generation_changed"
                # Most refusals (disabled/no_lease/queue_full/fenced) never
                # created a gate row at all; settle() would transition a row
                # we do not own. Only a genuine race -- admit() succeeded
                # under a DIFFERENT live generation than ours -- leaves a
                # real row behind, so only then is a settle attempted,
                # best-effort (never blocks the durable refused.json below).
                st = "not_admitted"
                if adm.ok and adm.generation is not None:
                    try:
                        st = self.gate.settle(label, pane, birth, adm.generation, rid, "blocked", reason, now)
                    except Exception:
                        st = "not_admitted"
                _write_excl(jfd, "refused.json", _record(reason=reason, gate_state=st, at=now))
                raise NotDispatched(reason)

            def refuse(reason, t):
                # PRE-SEND only. Settle the gate FIRST, then make the journal
                # outcome durable with what the gate actually recorded.
                st = self.gate.settle(label, pane, birth, gen, rid, "blocked", reason, t)
                _write_excl(jfd, "refused.json", _record(reason=reason, gate_state=st, at=t))
                raise NotDispatched(reason if st == "blocked" else f"{reason}:gate_{st}")

            rfd = ra._open_dir(root)
            try:
                try:
                    hfd = _mkdir_at(rfd, rid, exclusive=True)
                except FileExistsError:
                    refuse("handoff_dir_exists", now)
            finally:
                os.close(rfd)
            try:
                _write_excl(hfd, ra.REQUEST_FILE, request_text)
            finally:
                os.close(hfd)
            t = self.clock()  # fresh: the journal/file writes took real time
            if self._bound(label, t) != holder:
                refuse("fenced_before_send", t)
            began = self.gate.begin_notice(label, pane, birth, gen, rid, t)  # enforces MIN_LEASE_REMAINING_S
            if began != "delivering":
                refuse(began, t)
            try:
                ok = self.send(label, holder, request_text) is True
            except Exception:
                ok = False
            t = self.clock()
            if not ok:
                # POST-SEND: may have been typed. Terminal and non-retryable in
                # the gate (blocked, not retry:approval) and in the journal.
                st = self.gate.settle(label, pane, birth, gen, rid, "failed", POST_SEND_DETAIL, t)
                _write_excl(jfd, "uncertain.json", _record(reason=POST_SEND_DETAIL, gate_state=st, at=t))
                return "ambiguous" if st == "blocked" else f"ambiguous:gate_{st}"
            self.gate.settle(label, pane, birth, gen, rid, "delivered", "", t)
            _write_excl(jfd, ra.SETTLED_FILE, ra.settled_record(rid, digest, label, pane, birth, sess, gen, manifest))
        finally:
            os.close(jfd)
        return self._register(label, rid, now)

    def _register(self, label, rid, now) -> str:
        """Bind availability to the exact durable settled.json + intent; idempotent."""
        d = Path(self.avail.journal_root) / label / rid
        try:
            intent = json.loads(_read_small(d, "intent.json"))
            settled = _read_small(d, ra.SETTLED_FILE)
            want = ra.settled_record(rid, intent["request_digest"], label, intent["pane_id"], intent["pane_birth"],
                                     intent["session_id"], intent["generation"], intent["manifest"])
            if intent.get("rid") != rid or intent.get("label") != label or settled != want:
                return "dispatched:unregistered"
            root = self.avail.roots[label]
            text = _read_small(Path(root) / rid, ra.REQUEST_FILE)
            self.avail.register(rid, os.path.join(root, rid), text, label, intent["pane_id"], intent["pane_birth"],
                                intent["session_id"], intent["generation"], intent["manifest"], now)
        except (OSError, ValueError, KeyError, TypeError):
            return "dispatched:unregistered"  # settled, but not exactly bindable: never tracked
        return "dispatched"

    def recover(self, now: float | None = None) -> dict[str, str]:
        """Reconcile EVERY journal entry with its owner_requests row. Never
        resends, never grants a resend. Status per <label>/<rid>:
          dispatched                             settled.json, already registered
          registered / dispatched:unregistered   settled.json registered now / refused (intent mismatch)
          refused                                durable pre-send refusal, gate blocked
          refused_recovered[:gate_*]             crashed pre-send: gate settled now (queued
                                                 -> blocked) and refused.json written
          ambiguous                              post-send uncertainty (never retried)
          mismatch:<outcome>:<gate state>        journal and gate disagree: surfaced, untouched
          unrecorded:<outcome>                   gate has no row for a durable outcome"""
        now = self.clock() if now is None else now
        out: dict[str, str] = {}
        jroot = ra._open_dir(self.avail.journal_root)
        try:
            for label in sorted(os.listdir(jroot)):
                if label not in self.avail.roots:
                    continue
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
                            if _exists(jfd, "intent.json"):
                                out[f"{label}/{rid}"] = self._reconcile(jfd, label, rid, now)
                        finally:
                            os.close(jfd)
                finally:
                    os.close(lfd)
        finally:
            os.close(jroot)
        return out

    def _reconcile(self, jfd, label, rid, now) -> str:
        rec = self.gate.record(rid)
        gstate, gdetail = (rec[2], rec[3]) if rec and rec[0] == label else (None, None)
        post_send = gstate == "delivering" or (gstate == "blocked" and gdetail == POST_SEND_DETAIL)
        outcome = next((o for o in OUTCOMES if _exists(jfd, o)), None)
        if outcome is None:  # crashed between intent and a durable outcome
            if gstate is None or gstate == "queued" or (gstate == "blocked" and not post_send):
                st = gstate or "unrecorded"
                if gstate == "queued":
                    intent = json.loads(_read_small(Path(self.avail.journal_root) / label / rid, "intent.json"))
                    st = self.gate.settle(label, intent["pane_id"], intent["pane_birth"], intent["generation"], rid,
                                          "blocked", "crash_recovered_pre_send", now)
                _write_excl(jfd, "refused.json", _record(reason="crash_recovered_pre_send", gate_state=st, at=now))
                return "refused_recovered" if st == "blocked" else f"refused_recovered:gate_{st}"
            _write_excl(jfd, "uncertain.json", _record(reason="crash_recovered_post_send", gate_state=gstate, at=now))
            return "ambiguous"
        if gstate is None:
            if outcome == "refused.json":
                rj = json.loads(_read_small(Path(self.avail.journal_root) / label / rid, "refused.json"))
                if rj.get("gate_state") == "not_admitted":
                    # Self-declared: admission was refused before any gate row
                    # existed, so no row is EXPECTED here -- this is the
                    # terminal, correct classification, not a mismatch.
                    return "refused"
            return f"unrecorded:{outcome}"
        if outcome == ra.SETTLED_FILE:
            if gstate not in SETTLED_GATE_STATES:
                return f"mismatch:settled:{gstate}"
            if self.avail.conn.execute("SELECT 1 FROM ra_requests WHERE rid=?", (rid,)).fetchone():
                return "dispatched"
            r = self._register(label, rid, now)
            return "registered" if r == "dispatched" else r
        if outcome == "refused.json":
            return "refused" if gstate == "blocked" and not post_send else f"mismatch:refused:{gstate}"
        return "ambiguous" if post_send else f"mismatch:uncertain:{gstate}"

def _read_small(d: Path, name: str) -> bytes:
    """Bytes of a regular file directly in d, opened without following any symlink."""
    dfd = ra._open_dir(str(d))
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
    finally:
        os.close(dfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > ra.MAX_FILE_BYTES:
            raise ValueError("not a small regular file")
        return os.read(fd, st.st_size + 1)
    finally:
        os.close(fd)
