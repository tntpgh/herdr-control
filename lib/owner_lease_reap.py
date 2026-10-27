"""owner_lease_reap.py — INERT planning layer for a future stale-pane reap
controller. Nothing imports this module from hub.py; no HERDR_ flag gates it;
it never opens or writes the live lease store on its own.

Problem this closes (see tmp/REAP-WIRING-DESIGN.md, tmp/reap-wiring-REVIEW.md
finding 1): lib/owner_lease.observe_stale()/reap() trust the caller's
`live_panes` set completely. hub.pane_statuses() passes an empty/missing
`birth` field through unfiltered. A controller that silently drops such a
record before building `live_panes` turns "unknown" into "pane-gone" and
releases a genuinely live holder (reproduced in tmp/reap-unknown-birth-check.py,
scenario A1-A3).

`plan_reap()` is the single entry point a future controller must call before
it does anything else. It is read-only — it never calls
`owner_lease.reap(..., dry_run=False)` itself — and it fails the WHOLE tick
closed (SKIP, with a reason, zero candidates) unless the snapshot is a fresh,
well-formed, fully-known-birth projection. Only then does it return
`pane-gone` candidates built from `owner_lease.observe_stale()`. Expired
leases are intentionally excluded from `candidates`: the normal clock-based
`claim_successor()` path owns those (tmp/REAP-WIRING-DESIGN.md, "Reap first" /
"Normal expiry"), and stamping an expired lease `reaped:expired` would break
the standing-grant restart rule's exact `release_reason == "expired"` check
(lib/owner_dispatch_auth.py:307-321).
"""
from __future__ import annotations

import math
import time

import owner_lease as ol

# Seconds. A pane-liveness snapshot older than this cannot be trusted enough
# to reap against; see tmp/REAP-WIRING-DESIGN.md "Probe and trust boundary".
DEFAULT_MAX_SNAPSHOT_AGE_S = 30


def plan_reap(conn, pane_snapshot, snapshot_age_s, now=None,
              max_snapshot_age_s=DEFAULT_MAX_SNAPSHOT_AGE_S) -> dict:
    """Read-only. Returns one of:

      {"status": "skip", "reason": <str>}
      {"status": "ok", "candidates": [<observe_stale() dict>, ...]}

    `pane_snapshot` is the `{pane_id: record}` projection a caller would get
    from something like `hub.pane_statuses()` — `None` means the probe is
    unavailable. `snapshot_age_s` is the age in seconds of the authoritative
    data behind that projection (also `None` when no freshness metadata
    exists). `candidates` contains only `reason == "pane-gone"` observations;
    callers must still pass them through `owner_lease.reap()` themselves
    (default `dry_run=True`) to actually release anything — this function
    never does.

    SKIP, for the whole tick, when:
      - `pane_snapshot` is `None` (probe unavailable) or not a dict (malformed);
      - any record in it is not a dict, or has an empty/missing `birth`;
      - `snapshot_age_s` is missing, negative, or exceeds `max_snapshot_age_s`.
    """
    if pane_snapshot is None:
        return {"status": "skip", "reason": "probe_unavailable"}
    if not isinstance(pane_snapshot, dict):
        return {"status": "skip", "reason": "malformed_snapshot"}
    for pane_id, record in pane_snapshot.items():
        if not isinstance(pane_id, str) or not isinstance(record, dict):
            return {"status": "skip", "reason": "malformed_snapshot"}
        birth = record.get("birth")
        if not isinstance(birth, str) or not ol.BIRTH_RE.fullmatch(birth):
            return {"status": "skip", "reason": "unknown_birth"}
    if not isinstance(snapshot_age_s, (int, float)) or isinstance(snapshot_age_s, bool):
        return {"status": "skip", "reason": "stale_snapshot"}
    if not (math.isfinite(snapshot_age_s) and 0 <= snapshot_age_s <= max_snapshot_age_s):
        return {"status": "skip", "reason": "stale_snapshot"}

    now = time.time() if now is None else now
    live_panes = {(pane_id, record["birth"]) for pane_id, record in pane_snapshot.items()}
    observed = ol.observe_stale(conn, live_panes, now=now)
    candidates = [o for o in observed if o["reason"] == "pane-gone"]
    return {"status": "ok", "candidates": candidates}
