#!/usr/bin/env python3
"""RA (result-availability) SEND agent: the one piece of the RA pipeline
that can block on herdr-deliver.sh (up to 120s).

tmp/in/BRIEF-optC.md, following tmp/LATENCY.md's Option C recommendation:
split out of remote-mcp/publisher.py because launchd's StartInterval does
not overlap runs of the same job -- one slow send used to wedge the WHOLE
15s publisher tick (messaging, tasks, owner-inbox, lease renewal, and the
status sync itself), and a single slow send already exceeds the Worker's
own 90s disconnect threshold on its own (publisher.py's own _sha256_file
docstring documents the identical failure shape under a different cause,
P9: one slow call wedged the whole publisher under launchd's StartInterval).

OFF BY DEFAULT: refuses unless HERDR_RESULT_AVAILABILITY=1 and the owner-
lease gate is configured (HERDR_OWNER_LEASE_DELIVERY=1, HERDR_OWNER_LEASE_DB)
-- the SAME flags/stores publisher.py's now stage-only
result_availability_tick() already requires, and reads the identical
HERDR_RESULT_AVAILABILITY_DB/_JOURNAL/_ROOTS. A `staged` ra_requests row,
written by publisher.py's own tick, IS the hand-off between the two
processes -- no separate queue file, no new state.

One run = a notify budget of exactly one (lib/result_availability.py's
GatedNotice.prepare's `may_begin` hook, the same mechanism publisher.py's
tick used before this split): at most one herdr-deliver.sh call per
invocation. Install this with its OWN StartInterval, independent of the
publisher's -- a slow send here never blocks the publisher's loop, and the
publisher's loop never blocks this.

Double-send safety: the gate's own exchange_id ("ra-notice-" +
sha256(text)) and lib/owner_lease.py's enqueue() (a UNIQUE-constrained,
fenced insert) already dedupe a retried or overlapping admit --
verify-result-availability.py's "RACE: 8 concurrent tickers -> exactly one
callback" proves this under real concurrency. A prior run that crashed
mid-send leaves its exchange stuck `delivering`; the next run's admit()
refuses it with `owner_lease_duplicate:delivering` -- never re-sent, see
verify-ra-sender.py's CRASH case.

Alerting ("nothing is lost silently", BRIEF-optC.md #6): an `ambiguous`
outcome (post-send failure, the gate settles `blocked`) or a
`held:not_dispatched:...send_not_confirmed` outcome is a NON-retryable
hold for that exact body -- lib/owner_lease_delivery.py's admit() never
re-admits a `blocked` exchange_id for unchanged content, so this is not
"try again later", it is lost unless the underlying result changes. Every
such outcome is appended to ALERTS (jsonl, append-only, 0600) and printed
with an ALERT tag so it reaches ~/Library/Logs/com.herdr-control.ra-sender.log.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import publisher as pub  # noqa: E402 -- reuse registry_resolver/owner_lease_gate/DELIVER/the conductor label

LIB = REPO / "lib"
if str(LIB) not in sys.path:
    sys.path.insert(0, str(LIB))
import owner_lease as ol  # noqa: E402
import result_availability as ra  # noqa: E402

# HERDR_RA_SENDER_ALERTS overrides the alert file path -- defense in depth
# on top of HERDR_STATE_DIR: a test (or anything else reusing pub.STATE)
# that forgets to redirect HERDR_STATE_DIR must still be unable to write
# into the real ~/.local/state/herdr/remote-mcp/ (2026-10-29 defect: an
# earlier version of verify-ra-sender.py wrote 3 real ALERT rows there).
OUT = pub.STATE / "remote-mcp"
ALERTS = Path(os.environ["HERDR_RA_SENDER_ALERTS"]) if os.environ.get("HERDR_RA_SENDER_ALERTS") else OUT / "ra-sender-alerts.jsonl"


def log(msg: str) -> None:
    print(f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} herdr-ra-sender: {msg}", flush=True)


def is_alertable(outcome: str) -> bool:
    """`ambiguous` (post-send: unknown whether it typed) or a
    `send_not_confirmed` hold (pre-settle: known not sent, but the SAME
    permanent-duplicate-blocked dead end as ambiguous once content is
    unchanged) -- never the retryable holds (rate-limited, stale
    generation, no lease yet, changed content): those are expected and
    resolve on their own next run."""
    return outcome == "ambiguous" or "send_not_confirmed" in outcome


def alert(rid: str, outcome: str, now: float | None = None) -> None:
    now = time.time() if now is None else now
    ALERTS.parent.mkdir(parents=True, exist_ok=True)
    row = {"at": now, "rid": rid, "outcome": outcome}
    fd = os.open(ALERTS, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, (json.dumps(row, separators=(",", ":")) + "\n").encode())
    finally:
        os.close(fd)
    log(f"ALERT result-availability notice NOT delivered, will not retry (body unchanged): rid={rid} outcome={outcome}")


def send_tick() -> dict | None:
    """OFF unless HERDR_RESULT_AVAILABILITY=1. One pass of
    lib/result_availability.py Availability.tick() with the REAL
    GatedNotice wired (admit/begin_notice/notify/settle), budgeted to at
    most one real herdr-deliver.sh call. Alerts on any non-retryable hold."""
    if os.environ.get("HERDR_RESULT_AVAILABILITY") != "1":
        return None
    gate = pub.owner_lease_gate()
    if gate is None:
        raise RuntimeError("HERDR_RESULT_AVAILABILITY=1 needs the owner-lease gate (HERDR_OWNER_LEASE_DELIVERY=1)")
    avail = ra.from_env()

    def bound(label):
        cur = ol.holder_tuple(gate.conn, label, time.time())
        reg = pub.registry_resolver(label)
        return cur if cur and reg and tuple(reg) == cur[:3] else None

    def type_notice(pane, text):
        proc = subprocess.run([pub.DELIVER, pane, text], capture_output=True, text=True, timeout=120)
        return proc.returncode == 0

    notice = ra.GatedNotice(gate, pub.RESULT_AVAILABILITY_CONDUCTOR, bound, type_notice)
    budget = {"left": 1}

    def may_begin():
        if budget["left"] <= 0:
            return False
        budget["left"] -= 1
        return True

    def prepare_budgeted(rid, text):
        return notice.prepare(rid, text, may_begin=may_begin)

    try:
        out = avail.tick(bound, notice.notify, prepare=prepare_budgeted)
    finally:
        avail.close()
    for rid, outcome in (out or {}).items():
        if is_alertable(outcome):
            alert(rid, outcome)
    return out


def main(argv: list[str]) -> int:
    try:
        out = send_tick()
    except Exception as exc:  # noqa: BLE001 -- this agent's whole job is one tick; log and exit nonzero, never silent
        log(f"send tick failed: {type(exc).__name__}: {exc}")
        return 1
    if out:
        log(f"result availability: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
