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


class Dispatch(Protocol):
    def dispatch(self, label: str, rid: str, request_text: bytes, manifest: list[str], auth_id: str) -> str: ...


Accepted = Callable[[str, str], bool]  # (label, rid) -> accepted stage present
Events = Callable[[str, str], "dict | None"]  # (label, rid) -> latest queue_blocked/queue_cancelled event
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


def tick_lane(lane: Lane, dispatcher: Dispatch, accepted: Accepted, events: Events, notify: Notify) -> str:
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
    out = dispatcher.dispatch(lane.label, rid_for(lane.label, nxt["id"]), str(nxt.get("request", "")).encode(),
                              list(nxt.get("manifest", [])), str(nxt.get("auth_id", "")))
    if out in _SENT:
        lane.append(kind="dispatched", item=nxt["id"], outcome=out)
        return f"dispatched:{nxt['id']}"
    if out.startswith("held:not_dispatched:"):
        reason = out.split(":", 2)[2]
        if reason in RETRY_SAFE:
            _escalate(lane, escalated, notify, nxt["id"], out)  # nothing consumed, nothing sent
            return f"held:{nxt['id']}:{out}"
        lane.append(kind="held_consumed", item=nxt["id"], outcome=out)
        _escalate(lane, escalated, notify, nxt["id"], f"held_consumed:{out}")
        return f"frozen:held_consumed:{nxt['id']}"
    lane.append(kind="uncertain", item=nxt["id"], outcome=out)
    _escalate(lane, escalated, notify, nxt["id"], f"uncertain:{out}")
    return f"frozen:uncertain:{nxt['id']}"


def tick(root: Path, labels: list[str], dispatcher: Dispatch, accepted: Accepted, events: Events,
         notify: Notify, environ=os.environ) -> dict[str, str]:
    """One pass over every lane, serialized by an exclusive non-blocking lock so
    two passes can never both dispatch the same item."""
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
                result[label] = tick_lane(Lane(root, label), dispatcher, accepted, events, notify)
            except Exception as exc:  # noqa: BLE001 — one bad lane must not stall the others
                result[label] = f"error:{type(exc).__name__}"
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
