"""Queue supervisor: keeps approved project lanes advancing (DEFAULT OFF).

One tick() per hub attention interval (120s). For each lane (one project
conductor/owner label) it either
  * settles the lane's in-flight item from EVIDENCE (a handoff event naming the
    item), or
  * dispatches the lane's next approved item through the EXISTING fenced
    lib/owner_dispatch.Dispatcher (lease, auth grant, DeliveryGate, journal).
It never sends anything itself, never issues grants, never retries a send.

State is an append-only ledger per lane (<root>/<label>.ledger.jsonl, fsynced).
The queue is operator-approved input (<root>/<label>.queue.json):
  [{"id": "...", "request": "...", "manifest": ["..."], "hold": false}, ...]
"hold": true is an intentional hold and is skipped, never dispatched.

Lane outcomes and what they do:
  done       evidence with a 40-hex commit or artifact sha256 -> advance
  done_unproven  done event without proof -> escalate, lane frozen
  blocked    -> escalate once, lane frozen until an operator appends "resume"
  cancelled  -> advance, no escalation
  uncertain  dispatcher outcome ambiguous/unrecorded/mismatch -> escalate,
             lane frozen; the item is NEVER redispatched
  held       dispatcher refused before sending (nothing sent) -> retried on a
             later tick; escalated once per distinct reason
Activation: HERDR_QUEUE_SUPERVISOR=1. Anything else -> tick() returns "off"
and touches nothing.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import time
from pathlib import Path
from typing import Callable, Protocol

ENV_FLAG = "HERDR_QUEUE_SUPERVISOR"
_PROOF = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
_SENT = {"dispatched", "registered"}
TERMINAL = {"done", "cancelled"}
FREEZING = {"blocked", "uncertain", "done_unproven"}


class Dispatch(Protocol):
    def dispatch(self, label: str, rid: str, request_text: bytes, manifest: list[str]) -> str: ...


# evidence(label, item_id) -> None | {"state": "done"|"blocked"|"cancelled", "proof": str, "reason": str}
Evidence = Callable[[str, str], "dict | None"]
Notify = Callable[[str, str, str], None]  # (label, item_id, reason)


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
            items = json.loads(self.queue_path.read_text())
        except FileNotFoundError:
            return []
        if not isinstance(items, list) or not all(isinstance(i, dict) and isinstance(i.get("id"), str) for i in items):
            raise ValueError(f"malformed queue: {self.queue_path}")
        return items

    def ledger(self) -> list[dict]:
        out = []
        try:
            with self.ledger_path.open() as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue  # a torn last line must not wedge the lane
                    if isinstance(rec, dict):
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


def tick_lane(lane: Lane, dispatcher: Dispatch, evidence: Evidence, notify: Notify) -> str:
    in_flight, frozen, settled, escalated = _lane_state(lane.ledger())
    if in_flight is not None:
        ev = evidence(lane.label, in_flight)
        if not ev:
            return f"waiting:{in_flight}"
        state = ev.get("state")
        if state == "done":
            if _PROOF.match(str(ev.get("proof", ""))):
                lane.append(kind="done", item=in_flight, proof=ev["proof"])
                return f"done:{in_flight}"
            lane.append(kind="done_unproven", item=in_flight)
            _escalate(lane, escalated, notify, in_flight, "done_without_proof")
            return f"frozen:done_unproven:{in_flight}"
        if state == "cancelled":
            lane.append(kind="cancelled", item=in_flight, reason=str(ev.get("reason", "")))
            return f"cancelled:{in_flight}"
        if state == "blocked":
            reason = str(ev.get("reason", "blocked"))
            lane.append(kind="blocked", item=in_flight, reason=reason)
            _escalate(lane, escalated, notify, in_flight, f"blocked:{reason}")
            return f"frozen:blocked:{in_flight}"
        return f"waiting:{in_flight}"  # unknown evidence state: never guess
    if frozen:
        return f"frozen:{frozen}"
    nxt = next((i for i in lane.queue() if i["id"] not in settled and not i.get("hold")), None)
    if nxt is None:
        return "idle:empty"
    out = dispatcher.dispatch(lane.label, rid_for(lane.label, nxt["id"]),
                              str(nxt.get("request", "")).encode(), list(nxt.get("manifest", [])))
    if out in _SENT:
        lane.append(kind="dispatched", item=nxt["id"], outcome=out)
        return f"dispatched:{nxt['id']}"
    if out.startswith("held:not_dispatched:"):
        _escalate(lane, escalated, notify, nxt["id"], out)  # nothing was sent; retried next tick
        return f"held:{nxt['id']}:{out}"
    # dispatched:unregistered, ambiguous*, unrecorded*, mismatch*, refused*: a send may have
    # happened or cannot be tracked. Freeze; the item is never redispatched.
    lane.append(kind="uncertain", item=nxt["id"], outcome=out)
    _escalate(lane, escalated, notify, nxt["id"], f"uncertain:{out}")
    return f"frozen:uncertain:{nxt['id']}"


def tick(root: Path, labels: list[str], dispatcher: Dispatch, evidence: Evidence, notify: Notify,
         environ=os.environ) -> dict[str, str]:
    """One supervision pass over every lane. Serialized by an exclusive lock so two
    ticks (hub thread + manual run) can never both dispatch the same item."""
    if not enabled(environ):
        return {"_": "off"}
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = os.open(root / ".tick.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"_": "busy"}
        result = {}
        for label in labels:
            try:
                result[label] = tick_lane(Lane(root, label), dispatcher, evidence, notify)
            except Exception as exc:  # one bad lane must not stall the others
                result[label] = f"error:{type(exc).__name__}"
        return result
    finally:
        os.close(lock)
