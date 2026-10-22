"""owner_lease_delivery.py — the first runtime adapter onto the owner-lease
contract (lib/owner_lease.py): owner-inbox DELIVERY and REPLY settlement in
remote-mcp/publisher.py.

OFF BY DEFAULT. from_env() returns None unless BOTH
  HERDR_OWNER_LEASE_DELIVERY=1  and  HERDR_OWNER_LEASE_DB=<sqlite path>
are set, and the publisher then runs exactly its legacy path. Turning the flag
off is the rollback; the contract's own disable() makes every gated delivery
fail closed (blocked, never "deliver anyway").

This adapter never acquires, renews, releases or reaps a lease, never
registers an owner, never migrates a live DB and never touches a pane. Lease
acquisition belongs to the owner's own registration path, and closure-time
reap to close-done-workers.sh — both are later activation work (the latter is
frozen by #348). Here a delivery is admitted only when the label's CURRENT
live lease is held by exactly the registered (pane, birth):

  admit()   lease holder == registered pane/birth -> enqueue(exchange_id),
            left QUEUED in the holder's generation. The body file is written
            (deduped) while queued, so a crash before typing leaves a
            recoverable queued request: same-generation `queued` is re-admitted.
            A pre-send approval-prompt block (blocked 'retry:approval') goes
            back to queued. Every other seen id NEVER regains authority.
  begin_notice()  immediately before typing: fenced queued -> delivering, only
            if the live lease has >= DELIVERY_TIMEOUT_S + SAFETY_MARGIN_S left
            (otherwise stays queued: wait for renewal). Only `delivering` is
            ambiguous after a crash, and it is never retried.
  settle()  delivered -> stays `delivering` (a typed notice is not a reply);
            approval prompt (pre-send) -> blocked 'retry:approval';
            anything else -> blocked (terminal for delivery; never retyped).
  on_reply() credits `replied` only if the request is still `delivering` in
            the CURRENT live generation; a reply to a superseded generation
            is reported 'stale' and credits nothing.
  `replied` is never completion: only record_evidence() with an explicit
  evidence ref moves replied -> evidence.
"""
from __future__ import annotations

import os
import sqlite3
import sys
import time
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import owner_lease as ol  # noqa: E402
from datetime import datetime  # noqa: E402


def _ts(iso: str) -> float:
    return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=__import__("datetime").timezone.utc).timestamp()

FLAG = "HERDR_OWNER_LEASE_DELIVERY"
DB_ENV = "HERDR_OWNER_LEASE_DB"
RETRY_APPROVAL = "retry:approval"
DELIVERY_TIMEOUT_S = 120   # publisher's herdr-deliver.sh subprocess timeout
SAFETY_MARGIN_S = 60       # settle + clock skew allowance after a full timeout
MIN_LEASE_REMAINING_S = DELIVERY_TIMEOUT_S + SAFETY_MARGIN_S


@dataclass(frozen=True)
class Admission:
    ok: bool
    reason: str = ""          # publisher-style blocked reason when not ok
    generation: int | None = None


def from_env(environ=os.environ) -> "DeliveryGate | None":
    if environ.get(FLAG) != "1" or not environ.get(DB_ENV):
        return None
    return DeliveryGate(environ[DB_ENV])


class DeliveryGate:
    def __init__(self, db_path: str):
        # Never creates or migrates: a missing/unmigrated DB fails closed.
        if not Path(db_path).is_file():
            raise FileNotFoundError(f"owner-lease DB not found: {db_path}")
        self.conn = ol.connect(db_path)

    min_lease_remaining_s = MIN_LEASE_REMAINING_S

    def close(self):
        self.conn.close()

    def _holder(self, label, now):
        return ol._live(self.conn, label, now)  # (lease_id, pane, birth, gen, renewed, expires) | None

    def _enabled(self):
        row = self.conn.execute("SELECT enabled FROM owner_state WHERE id=1").fetchone()
        return bool(row and row[0])

    def admit(self, label: str, pane_id: str, pane_birth: str, exchange_id: str, now: float | None = None) -> Admission:
        now = time.time() if now is None else now
        try:
            if not self._enabled():
                return Admission(False, "owner_lease_disabled")
            cur = self._holder(label, now)
            if not cur:
                return Admission(False, "owner_no_lease")
            gen = cur[3]
            # enqueue()'s own fence rejects a caller that is not the live holder.
            res = ol.enqueue(self.conn, label, gen, pane_id, pane_birth, exchange_id, now)
            if not res["authority"]:
                row = self.conn.execute("SELECT state, detail, generation, label FROM owner_requests WHERE request_id=?",
                                        (exchange_id,)).fetchone()
                # Generations are label-local and request ids global: recovery
                # needs EXACT (label, generation, state) ownership.
                owned = bool(row and row[3] == label and row[2] == gen)
                if owned and row[0] == "queued":
                    return Admission(True, "", gen)  # crash/recovery before typing
                if not (owned and row[0] == "blocked" and row[1] == RETRY_APPROVAL):
                    return Admission(False, f"owner_lease_duplicate:{res['state']}", gen)
                ol.transition(self.conn, exchange_id, "queued", label, gen, pane_id, pane_birth, "retry", now)
            return Admission(True, "", gen)
        except ol.Disabled:
            return Admission(False, "owner_lease_disabled")
        except ol.QueueFull:
            return Admission(False, "owner_queue_full")
        except (ol.FencedOut, ol.LeaseConflict):
            return Admission(False, "owner_lease_fenced")
        except (ol.InvalidOwner, ol.InvalidTransition, ValueError, sqlite3.Error) as exc:
            return Admission(False, f"owner_lease_error:{type(exc).__name__}")

    def begin_notice(self, label, pane_id, pane_birth, generation, exchange_id, now: float | None = None) -> str:
        """'delivering' (type now) | 'lease_too_short' (stay queued; retry after
        renewal) | 'owner_lease_fenced' | 'owner_lease_disabled' | 'owner_lease_error:*'."""
        now = time.time() if now is None else now
        try:
            if not self._enabled():
                return "owner_lease_disabled"
            cur = self._holder(label, now)
            if not cur or cur[3] != generation:
                return "owner_lease_fenced"
            if _ts(cur[5]) - now < MIN_LEASE_REMAINING_S:
                return "lease_too_short"
            return ol.transition(self.conn, exchange_id, "delivering", label, generation, pane_id, pane_birth, "", now)
        except ol.Disabled:
            return "owner_lease_disabled"
        except (ol.FencedOut, ol.LeaseConflict):
            return "owner_lease_fenced"
        except (ol.InvalidOwner, ol.InvalidTransition, ValueError, sqlite3.Error) as exc:
            return f"owner_lease_error:{type(exc).__name__}"

    def settle(self, label, pane_id, pane_birth, generation, exchange_id, outcome: str, reason: str = "",
               now: float | None = None) -> str:
        """Record the delivery attempt's result. Returns the request state."""
        if outcome == "delivered":
            return "delivering"
        detail = RETRY_APPROVAL if reason == "owner_at_approval_prompt" else reason[:200]
        try:
            return ol.transition(self.conn, exchange_id, "blocked", label, generation, pane_id, pane_birth, detail, now)
        except (ol.Disabled, ol.FencedOut, ol.InvalidTransition, ValueError, sqlite3.Error):
            return "unrecorded"

    def on_reply(self, label: str, exchange_id: str, now: float | None = None) -> str:
        """'replied' | 'stale' | 'unknown' | 'not_delivering' | 'disabled' | 'no_lease'."""
        now = time.time() if now is None else now
        row = self.conn.execute("SELECT label, generation, state FROM owner_requests WHERE request_id=?",
                                (exchange_id,)).fetchone()
        if not row or row[0] != label:
            return "unknown"
        if row[2] == "stale":
            return "stale"
        if row[2] != "delivering":
            return "not_delivering"
        cur = self._holder(label, now)
        if not cur:
            return "no_lease"
        try:  # transition()'s fence rejects a request of a superseded generation
            return ol.transition(self.conn, exchange_id, "replied", label, row[1], cur[1], cur[2], "", now)
        except ol.Disabled:
            return "disabled"
        except ol.FencedOut:
            return "stale"

    def record(self, exchange_id: str):
        """(label, generation, state, detail) of the owner request, or None. Read-only."""
        row = self.conn.execute("SELECT label, generation, state, detail FROM owner_requests WHERE request_id=?",
                                (exchange_id,)).fetchone()
        return tuple(row) if row else None

    def state(self, exchange_id: str) -> str | None:
        row = self.conn.execute("SELECT state FROM owner_requests WHERE request_id=?", (exchange_id,)).fetchone()
        return row[0] if row else None

    def record_evidence(self, label, exchange_id, evidence_ref: str, now: float | None = None) -> str:
        """replied -> evidence, only with a non-empty evidence reference."""
        if not (isinstance(evidence_ref, str) and evidence_ref.strip()):
            raise ValueError("evidence_ref required")
        now = time.time() if now is None else now
        row = self.conn.execute("SELECT generation, state FROM owner_requests WHERE request_id=? AND label=?",
                                (exchange_id, label)).fetchone()
        cur = self._holder(label, now)
        if not row or not cur or cur[3] != row[0]:
            raise ol.FencedOut(f"{exchange_id}: no live lease for its generation")
        return ol.transition(self.conn, exchange_id, "evidence", label, row[0], cur[1], cur[2], evidence_ref[:200], now)
