"""Queue supervisor: keeps approved project lanes advancing (DEFAULT OFF).

One tick() per hub pass. For each lane (one project conductor / owner label)
it either settles the lane's in-flight item, or dispatches the lane's next
approved item through the EXISTING fenced lib/owner_dispatch.Dispatcher
(lease, one-time owner-dispatch-auth grant, DeliveryGate, journal). It never
sends anything itself, never issues, re-grants or re-arms authorization, and
never retries anything that may have crossed the send boundary.

Inputs (operator-approved, never written here):
  <root>/<label>.queue.json
    [{"id": "...", "request": "...", "manifest": ["..."], "auth_id": "...", "hold": false}]
  "hold": true is an intentional hold: skipped, never dispatched. auth_id names
  the one-time grant the operator issued for exactly that request.
State: <root>/<label>.ledger.jsonl, append-only, fsynced, 0600.

Completion is CONSUMED, never inferred:
  done       result_availability stage `accepted` exists for the rid
             (accepted requires verified AND reply_authenticated there).
             A worker-written event or a hash-shaped string is NOT completion.
  blocked    owner event {"event":"queue_blocked","rid":..,"reason":..}
             -> escalate once, lane frozen until the operator appends "resume"
  cancelled  owner event {"event":"queue_cancelled","rid":..} -> advance
Dispatch outcomes:
  dispatched/registered -> in flight
  held:not_dispatched:<r>, r in RETRY_SAFE (refused BEFORE the grant is
             consumed; nothing journaled, nothing sent) -> retried next tick,
             escalated once per reason
  held:not_dispatched:<other> (grant consumed or rid journaled) -> frozen,
             escalated; the item is never retried (no automatic re-grant)
  anything else (dispatched:unregistered, ambiguous*, ...) -> frozen,
             escalated; the item is never redispatched
Activation: HERDR_QUEUE_SUPERVISOR=1. Otherwise tick() returns "off" and
touches nothing.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import time
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

ENV_FLAG = "HERDR_QUEUE_SUPERVISOR"
_SENT = {"dispatched", "registered"}
# owner_dispatch.Dispatcher._dispatch raises these BEFORE self.authorize()
# consumes the grant and before any journal file exists (owner_dispatch.py:141-163).
RETRY_SAFE = frozenset({"label_has_no_root", "bad_request", "bad_manifest", "owner_project_unmapped",
                        "registry_lease_mismatch", "auth_missing"})
TERMINAL = {"done", "cancelled"}
FREEZING = {"blocked", "uncertain", "held_consumed"}
MAX_LANES = 5  # operator-requested 1-5 canonical lanes
MAX_IN_FLIGHT = 5  # TOTAL dispatched-and-unsettled items across all lanes and ticks
MAX_DISPATCH_PER_TICK = 4  # additionally: at most this many new sends per pass
ITEM_KEYS = {"id", "request", "manifest", "auth_id", "hold"}
_ID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,64}$")
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]{0,63}$")  # result_availability.NAME_RE
MAX_MANIFEST = 8  # result_availability.MAX_MANIFEST


class LedgerCorrupt(ValueError):
    pass


class Dispatch(Protocol):
    def dispatch(self, label: str, rid: str, request_text: bytes, manifest: list[str], auth_id: str) -> str: ...


Accepted = Callable[[str, str], bool]  # (label, rid) -> result_availability `accepted` stage present
Events = Callable[[str, str], "dict | None"]  # (label, rid) -> latest queue_blocked/queue_cancelled event
Notify = Callable[[str, str, str], None]  # (label, item_id, reason)
# (label, rid) -> None (no journal dir: never dispatched) | "settled" | "refused" | "uncertain" | "intent_only"
Journal = Callable[[str, str], "str | None"]


def validate_queue(items) -> list[dict]:
    """Strict operator-queue schema. Raises ValueError on anything else; never coerces."""
    if not isinstance(items, list):
        raise ValueError("queue is not a list")
    seen: set[str] = set()
    for i in items:
        if not isinstance(i, dict) or set(i) - ITEM_KEYS or not {"id", "request", "auth_id"} <= set(i):
            raise ValueError("item keys")
        if not isinstance(i["id"], str) or not _ID_RE.match(i["id"]) or i["id"] in seen:
            raise ValueError(f"item id: {i.get('id')!r}")
        seen.add(i["id"])
        if not isinstance(i["request"], str) or not i["request"].strip():
            raise ValueError(f"request: {i['id']}")
        if not isinstance(i["auth_id"], str) or not i["auth_id"]:
            raise ValueError(f"auth_id: {i['id']}")
        man = i.get("manifest", [])
        if (not isinstance(man, list) or len(man) > MAX_MANIFEST or len(set(map(str, man))) != len(man)
                or not all(isinstance(m, str) and _NAME_RE.match(m) for m in man)):
            raise ValueError(f"manifest: {i['id']}")
        if not isinstance(i.get("hold", False), bool):
            raise ValueError(f"hold: {i['id']}")
    return items


def enabled(environ=os.environ) -> bool:
    return environ.get(ENV_FLAG) == "1"


def rid_for(label: str, item_id: str) -> str:
    return f"q-{label}-{item_id}"


class Lane:
    def __init__(self, root: Path, label: str):
        self.label = label
        self.queue_path = root / f"{label}.queue.json"
        self.ledger_path = root / f"{label}.ledger.jsonl"

    def queue(self) -> list[dict]:
        try:
            raw = self.queue_path.read_text()
        except FileNotFoundError:
            return []
        return validate_queue(json.loads(raw))

    def ledger(self) -> list[dict]:
        """Every line must be a JSON object. Anything else (torn write, edit) is
        LedgerCorrupt: the lane freezes rather than guessing its own history."""
        out = []
        try:
            with self.ledger_path.open() as f:
                for n, line in enumerate(f, 1):
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        raise LedgerCorrupt(f"{self.ledger_path}:{n}") from None
                    if not isinstance(rec, dict):
                        raise LedgerCorrupt(f"{self.ledger_path}:{n}")
                    out.append(rec)
        except FileNotFoundError:
            pass
        return out

    def append(self, **rec) -> None:
        rec.setdefault("at", time.time())
        fd = os.open(self.ledger_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, (json.dumps(rec, sort_keys=True) + "\n").encode())
            os.fsync(fd)
        finally:
            os.close(fd)


def _lane_state(ledger: list[dict]):
    """-> (in_flight_item | None, frozen_reason | None, settled_ids, escalated_keys)"""
    in_flight = frozen = None
    settled: set[str] = set()
    escalated: set[str] = set()
    for r in ledger:
        kind, item = r.get("kind"), r.get("item")
        if kind == "dispatched":
            in_flight = item
        elif kind in TERMINAL:
            settled.add(item)
            in_flight = None if in_flight == item else in_flight
        elif kind in FREEZING:
            settled.add(item)
            in_flight, frozen = None, f"{kind}:{item}"
        elif kind == "resume":
            frozen = None
        elif kind == "escalated":
            escalated.add(r.get("key", ""))
    return in_flight, frozen, settled, escalated


def _escalate(lane: Lane, escalated: set[str], notify: Notify, item: str, reason: str) -> None:
    key = f"{item}:{reason}"
    if key in escalated:
        return
    notify(lane.label, item, reason)
    lane.append(kind="escalated", item=item, key=key, reason=reason)
    escalated.add(key)


def tick_lane(lane: Lane, dispatcher: Dispatch, accepted: Accepted, events: Events, notify: Notify,
              journal: Journal, may_dispatch: bool = True) -> str:
    in_flight, frozen, settled, escalated = _lane_state(lane.ledger())
    if in_flight is not None:
        rid = rid_for(lane.label, in_flight)
        if accepted(lane.label, rid):
            lane.append(kind="done", item=in_flight, evidence="result_availability:accepted")
            return f"done:{in_flight}"
        ev = events(lane.label, rid) or {}
        if ev.get("event") == "queue_cancelled":
            lane.append(kind="cancelled", item=in_flight, reason=str(ev.get("reason", "")))
            return f"cancelled:{in_flight}"
        if ev.get("event") == "queue_blocked":
            reason = str(ev.get("reason", "blocked"))
            lane.append(kind="blocked", item=in_flight, reason=reason)
            _escalate(lane, escalated, notify, in_flight, f"blocked:{reason}")
            return f"frozen:blocked:{in_flight}"
        return f"waiting:{in_flight}"
    if frozen:
        return f"frozen:{frozen}"
    nxt = next((i for i in lane.queue() if i["id"] not in settled and not i.get("hold")), None)
    if nxt is None:
        return "idle:empty"
    rid = rid_for(lane.label, nxt["id"])
    # Crash window: the Dispatcher's journal is written before/after the send but
    # our ledger append comes after dispatch() returns. If the journal already
    # knows this rid, reconcile from it and NEVER call dispatch() again.
    js = journal(lane.label, rid)
    if js == "settled":
        lane.append(kind="dispatched", item=nxt["id"], outcome="reconciled:settled")
        return f"dispatched:{nxt['id']}:reconciled"
    if js is not None:
        lane.append(kind="uncertain", item=nxt["id"], outcome=f"reconciled:{js}")
        _escalate(lane, escalated, notify, nxt["id"], f"uncertain:journal_{js}")
        return f"frozen:uncertain:{nxt['id']}"
    if not may_dispatch:
        return f"deferred:{nxt['id']}"
    out = dispatcher.dispatch(lane.label, rid, nxt["request"].encode(), list(nxt.get("manifest", [])), nxt["auth_id"])
    if out in _SENT:
        lane.append(kind="dispatched", item=nxt["id"], outcome=out)
        return f"dispatched:{nxt['id']}"
    if out.startswith("held:not_dispatched:"):
        reason = out.split(":", 2)[2]
        if reason in RETRY_SAFE:
            _escalate(lane, escalated, notify, nxt["id"], out)  # nothing consumed, journaled or sent
            return f"held:{nxt['id']}:{out}"
        lane.append(kind="held_consumed", item=nxt["id"], outcome=out)
        _escalate(lane, escalated, notify, nxt["id"], f"held_consumed:{out}")
        return f"frozen:held_consumed:{nxt['id']}"
    lane.append(kind="uncertain", item=nxt["id"], outcome=out)
    _escalate(lane, escalated, notify, nxt["id"], f"uncertain:{out}")
    return f"frozen:uncertain:{nxt['id']}"


def tick(root: Path, labels: list[str], dispatcher: Dispatch, accepted: Accepted, events: Events,
         notify: Notify, journal: Journal, environ=os.environ) -> dict[str, str]:
    """One pass over the lanes IN THE GIVEN ORDER (operator priority, e.g. revenue
    first), at most MAX_DISPATCH_PER_TICK new sends, serialized by an exclusive
    non-blocking lock so two passes can never both dispatch the same item."""
    if not enabled(environ):
        return {"_": "off"}
    if len(labels) > MAX_LANES or len(set(labels)) != len(labels) or not all(_ID_RE.match(x) for x in labels):
        return {"_": "refused:lanes"}
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = os.open(root / ".tick.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"_": "busy"}
        lanes = [Lane(root, label) for label in labels]
        occupied = 0
        for lane in lanes:  # durable total capacity, counted before any send this pass
            try:
                occupied += _lane_state(lane.ledger())[0] is not None
            except LedgerCorrupt:
                occupied += 1  # unknown history counts as occupied capacity
        result, sends = {}, 0
        for lane in lanes:
            label = lane.label
            try:
                may = sends < MAX_DISPATCH_PER_TICK and occupied < MAX_IN_FLIGHT
                r = tick_lane(lane, dispatcher, accepted, events, notify, journal, may)
            except LedgerCorrupt:
                r = "frozen:ledger_corrupt"
                marker = root / f"{label}.corrupt-notified"
                if not marker.exists():  # escalate once; the ledger itself is not trusted
                    notify(label, "", "ledger_corrupt")
                    marker.touch(mode=0o600)
            except Exception as exc:  # noqa: BLE001 — one bad lane must not stall the others
                r = f"error:{type(exc).__name__}"
            if r.startswith("dispatched:"):  # a reconciled send occupies capacity too
                occupied += 1
                sends += not r.endswith(":reconciled")
            result[label] = r
        return result
    finally:
        os.close(lock)


def latest_queue_event(events_file: Path, rid: str) -> dict | None:
    """Last queue_blocked/queue_cancelled line for rid in an owner events.jsonl.
    Malformed lines are skipped (same tolerance as lib/reconcile.sh:59)."""
    last = None
    try:
        with events_file.open() as f:
            for line in f:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if isinstance(ev, dict) and ev.get("rid") == rid and ev.get("event") in ("queue_blocked", "queue_cancelled"):
                    last = ev
    except (FileNotFoundError, NotADirectoryError):
        return None
    return last
