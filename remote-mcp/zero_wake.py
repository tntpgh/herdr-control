"""herdr-mcp zero-wake: a bounded, durable "something needs you" bell posted
to one Slack channel (HERDR_ZERO_WAKE_CHANNEL), separate from the inbound
bridge's normal alert/reply traffic. Part of SPEC zero-wake-design.md.

Design constraints this module enforces (publisher.py owns the WIRING --
deciding WHEN a reply_ready/task_finished/blocked/decision_needed event
happens; this module owns the OUTBOX itself so that logic is independently
testable, offline, with no real Slack call):

  - One live event per (kind, ref, state_key); a repeat while the existing
    event is pending/posted only bumps last_at (`raise_event`).
  - A ref must match REF_RE AND be a live id the caller's publisher state
    actually knows about (`raise_event`'s `known_refs`), or the event is
    refused and logged -- never silently dropped, never silently posted on
    a name that could be guessed.
  - Posting (`tick`) retries at most MAX_ATTEMPTS times, exponential backoff
    capped at MAX_BACKOFF_S, then the event is marked failed. An AMBIGUOUS
    outcome (timeout or 5xx -- the message may have gone through) retries
    with the SAME event_id rather than minting a new one, so a duplicate on
    the Slack side is the worst case, never a silent drop.
  - At most MAX_POSTS_PER_TICK posts per call to `tick`, oldest-due first.
  - `consume_ack` is the only way an event reaches status "acked"; it is
    looked up by event_id alone (the ack message carries nothing else) and
    is idempotent -- a second ack for an already-acked or already-tombstoned
    id is a no-op ("duplicate"), an id this outbox never issued is a no-op
    ("unknown"). Never touches anything resembling typing into a pane; that
    is a publisher.py concern (it must never call deliver_owner for one of
    these).
  - `tombstone_finished`/`prune_tombstones` are retention: acked/failed rows
    move to a separate list (so they stop being postable/ackable) and age
    out after TOMBSTONE_RETENTION_DAYS or past TOMBSTONE_HARD_CAP, oldest
    first. Pending/posted rows in `events` are never touched by pruning.
"""
from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

EVENT_KINDS = {"reply_ready", "task_finished", "blocked", "decision_needed"}
REF_RE = re.compile(r"^(oex|rtask)_[0-9A-Za-z_]+$")
CHANNEL_RE = re.compile(r"^[CGD][A-Z0-9]{8,}$")
ACK_RE = re.compile(r"^ack ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$")
# The one owner_label this module ever speaks to; Zero sends its ack here
# (design doc: send_owner_message(owner_label=OWNER_LABEL, body=f"ack {id}")).
OWNER_LABEL = "herdr-control-dots"

MAX_ATTEMPTS = 5
BASE_BACKOFF_S = 60
MAX_BACKOFF_S = 3600
MAX_POSTS_PER_TICK = 10
TOMBSTONE_RETENTION_DAYS = 30
TOMBSTONE_HARD_CAP = 5000

_LIVE_STATUSES = ("pending", "posted")


def log(msg: str) -> None:
    print(f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} herdr-mcp-zero-wake: {msg}", flush=True)


def wake_channel(raw: str) -> str | None:
    """Validated HERDR_ZERO_WAKE_CHANNEL. Empty means off (no log, that is
    the documented default). A malformed non-empty value means off AND
    logged -- the config error must not be silent, but it must not crash
    the tick either (the rest of the sync still has to run)."""
    raw = (raw or "").strip()
    if not raw:
        return None
    if not CHANNEL_RE.match(raw):
        log(f"HERDR_ZERO_WAKE_CHANNEL={raw!r} is not a valid Slack channel id; emitter off")
        return None
    return raw


def new_outbox() -> dict:
    return {"events": [], "tombstones": []}


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s: str) -> float:
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def _event_key(ev_or_kind, ref=None, state_key=None) -> tuple:
    if ref is None:
        ev = ev_or_kind
        return (ev["kind"], ev["ref"], ev["state_key"])
    return (ev_or_kind, ref, state_key)


def raise_event(outbox: dict, kind: str, ref: str, state_key: str, known_refs: set[str], now_ts: float) -> dict | None:
    """Create (or coalesce into) an event. Returns the event, or None when
    refused -- an unknown kind, a ref failing REF_RE, or a ref not present in
    `known_refs` (the caller's own publisher-state existence check)."""
    if kind not in EVENT_KINDS:
        log(f"refusing event: unknown kind {kind!r}")
        return None
    if not ref or not REF_RE.match(ref) or ref not in known_refs:
        log(f"refusing event kind={kind}: ref {ref!r} is malformed or not known to publisher state")
        return None
    now_iso = _iso(now_ts)
    key = (kind, ref, state_key)
    for ev in outbox["events"]:
        if ev["status"] in _LIVE_STATUSES and _event_key(ev) == key:
            ev["last_at"] = now_iso
            return ev
    ev = {"event_id": str(uuid.uuid4()), "kind": kind, "ref": ref, "state_key": state_key,
          "first_at": now_iso, "last_at": now_iso, "attempts": 0, "status": "pending"}
    outbox["events"].append(ev)
    return ev


def post_text(ev: dict) -> str:
    return f"[zero-wake] {ev['kind']} {ev['ref']} {ev['event_id']}"


def _next_retry_ts(ev: dict) -> float:
    delay = min(BASE_BACKOFF_S * (2 ** (ev["attempts"] - 1)), MAX_BACKOFF_S)
    return _parse_iso(ev["last_at"]) + delay


def due_events(outbox: dict, now_ts: float) -> list[dict]:
    """Pending events ready to (re)post, oldest-raised first, capped at
    MAX_POSTS_PER_TICK. A never-attempted event (attempts==0) is always
    due; a retry is due once its backoff has elapsed since last_at."""
    ready = [ev for ev in outbox["events"]
             if ev["status"] == "pending" and (ev["attempts"] == 0 or now_ts >= _next_retry_ts(ev))]
    ready.sort(key=lambda ev: ev["first_at"])
    return ready[:MAX_POSTS_PER_TICK]


def apply_post_result(ev: dict, ok: bool, ambiguous: bool, now_ts: float) -> None:
    """ok -> posted. Not ok: ambiguous (timeout/5xx) or not, attempts always
    increments and the SAME event_id is kept either way -- only the status
    differs once MAX_ATTEMPTS is reached (failed, logged, no further posts).
    `ambiguous` has no separate effect here beyond documenting at the call
    site why a retry (not a fresh event) is correct: SPEC's "retry with the
    SAME event_id" is simply what every non-ok outcome already does."""
    del ambiguous  # see docstring: both failure shapes retry identically
    ev["attempts"] += 1
    ev["last_at"] = _iso(now_ts)
    if ok:
        ev["status"] = "posted"
    elif ev["attempts"] >= MAX_ATTEMPTS:
        ev["status"] = "failed"


def default_poster(token: str, channel: str, text: str, timeout: float = 10.0) -> tuple[bool, bool, str]:
    """Real chat.postMessage call. Returns (ok, ambiguous, detail).
    ambiguous=True on a timeout/network error or a 5xx -- the message may
    have gone through, so the caller retries with the same event_id rather
    than treating it as a clean miss."""
    body = json.dumps({"channel": channel, "text": text}).encode()
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage", data=body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            doc = json.load(r)
    except urllib.error.HTTPError as exc:
        return False, 500 <= exc.code < 600, f"http {exc.code}"
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return False, True, str(exc)
    if doc.get("ok"):
        return True, False, "ok"
    return False, False, str(doc.get("error"))


def tick(outbox: dict, channel: str | None, token: str, now_ts: float, poster=default_poster) -> list[dict]:
    """Post every due event (capped), update the outbox in place, return
    what happened this tick for logging. Off (channel is None) is a no-op:
    events still accumulate and will post once the config is fixed."""
    if not channel:
        return []
    out = []
    for ev in due_events(outbox, now_ts):
        ok, ambiguous, detail = poster(token, channel, post_text(ev))
        apply_post_result(ev, ok, ambiguous, now_ts)
        out.append({"event_id": ev["event_id"], "kind": ev["kind"], "ref": ev["ref"],
                    "outcome": ev["status"] if ev["status"] in ("posted", "failed") else "retry", "detail": detail})
    return out


def consume_ack(outbox: dict, event_id: str, now_ts: float) -> str:
    """'acked' | 'duplicate' | 'unknown'. Matching is by event_id alone --
    the ack message carries nothing else to disambiguate -- and is
    idempotent both while the event is still live and after it has been
    tombstoned."""
    for ev in outbox["events"]:
        if ev["event_id"] == event_id:
            if ev["status"] == "acked":
                return "duplicate"
            ev["status"] = "acked"
            ev["last_at"] = _iso(now_ts)
            return "acked"
    for t in outbox["tombstones"]:
        if t["event_id"] == event_id and t["status"] == "acked":
            return "duplicate"
    return "unknown"


def tombstone_finished(outbox: dict, now_ts: float) -> None:
    """Moves acked/failed events out of the live list and into tombstones,
    so they stop being postable (tick/due_events only ever look at
    'pending') and stop being coalesce targets (raise_event only coalesces
    into pending/posted)."""
    keep = []
    for ev in outbox["events"]:
        if ev["status"] in ("acked", "failed"):
            outbox["tombstones"].append({"event_id": ev["event_id"], "kind": ev["kind"], "ref": ev["ref"],
                                          "status": ev["status"], "at": _iso(now_ts)})
        else:
            keep.append(ev)
    outbox["events"] = keep


def prune_tombstones(outbox: dict, now_ts: float) -> None:
    """30-day age-out, then a hard cap of TOMBSTONE_HARD_CAP, oldest first.
    Only ever touches `tombstones` -- a pending/posted row in `events` is
    never dropped, no matter how large the outbox gets."""
    cutoff = now_ts - TOMBSTONE_RETENTION_DAYS * 86400
    outbox["tombstones"] = [t for t in outbox["tombstones"] if _parse_iso(t["at"]) >= cutoff]
    if len(outbox["tombstones"]) > TOMBSTONE_HARD_CAP:
        outbox["tombstones"].sort(key=lambda t: t["at"])
        outbox["tombstones"] = outbox["tombstones"][-TOMBSTONE_HARD_CAP:]
