"""owner_lease_reap.py — INERT, DRY-RUN-ONLY stale-pane reap controller for
lib/owner_lease. Nothing imports this module from hub.py; no HERDR_ flag gates
it; it never opens a store itself. Design: docs/design/lease-reap-wiring.md.

Problem (docs/design/lease-reap-wiring.md "Why a guard layer"):
lib/owner_lease.observe_stale()/reap() trust the caller's `live_panes` set
completely. A controller that drops an unknown-birth record before building
`live_panes` turns "unknown" into "pane-gone" and would release a genuinely
live holder. Likewise a herdr server restart reissues `terminal_id` (the pane
birth) for every pane whose agent never died (lib/run-registry.sh:229-238,
lib/reconcile.sh corroboration): an exact (pane_id, birth) comparison alone
calls every such holder "pane-gone". A third hazard (S4(c), DESIGN-reap.md
§3a): a pane that spawns and claims AFTER the snapshot was captured can be
absent from that snapshot even though it is alive -- the spawn/register race
lib/reconcile.sh:119-122 already guards against.

Entry points, all read-only on the lease store:
  snapshot_from_pane_list(payload) — `herdr pane list` JSON -> {pane_id: rec}
                                     or None when unparseable.
  plan_reap(conn, snapshot, age, snapshot_at=None) — fails the WHOLE tick
                                     closed (SKIP + reason) unless the
                                     snapshot is fresh, well-formed and every
                                     birth is known; otherwise `pane-gone`
                                     candidates plus `held` leases that are
                                     either claimed at/after `snapshot_at` (or
                                     `snapshot_at` is unknown -- fail-safe) or
                                     whose pane id is still present under a
                                     new birth and not positively proven to be
                                     a different agent session.
  reap_tick(conn, payload, captured_at) — the ONLY caller of observe_stale()
                                     (via plan_reap) and reap(). Always
                                     dry-run: no argument reaches reap()'s
                                     apply mode. Apply is a separate, approved
                                     change (design doc "Turning REAP_APPLY on").
                                     Passes `captured_at` through to
                                     `plan_reap` as `snapshot_at`.

Expired leases are excluded from candidates: the clock-based successor path
owns those, and stamping one `reaped:expired` would break the standing-grant
restart rule's exact `release_reason == "expired"` check
(lib/owner_dispatch_auth.py:307-321).
"""
from __future__ import annotations

import hashlib
import json
import math
import time

import owner_lease as ol

# Seconds. A pane-liveness snapshot older than this cannot be trusted enough
# to reap against; see docs/design/lease-reap-wiring.md "Probe".
DEFAULT_MAX_SNAPSHOT_AGE_S = 30


def snapshot_from_pane_list(payload):
    """`herdr pane list` output (str/bytes JSON, or already-decoded) ->
    {pane_id: {"pane_id", "birth", "agent_session"}}, or None when the payload
    is not the documented `(.result.panes // .panes)` array shape (same
    selector as lib/pane-guard.sh and lib/reconcile.sh). Any non-object entry,
    a pane id that is not a herdr pane id, or a DUPLICATE pane id makes the
    whole payload unparseable: a partial set would turn a dropped row into a
    false `pane-gone`. `birth` is herdr's `terminal_id`, passed through
    unvalidated so plan_reap() reports it as `unknown_birth`, not malformed.
    `agent_session` is `.agent_session.value` or ''."""
    if isinstance(payload, (str, bytes)):
        try:
            payload = json.loads(payload)
        except ValueError:
            return None
    if not isinstance(payload, dict):
        return None
    result = payload.get("result")
    panes = result.get("panes") if isinstance(result, dict) else None
    if panes is None:
        panes = payload.get("panes")
    if not isinstance(panes, list):
        return None
    out = {}
    for p in panes:
        if not isinstance(p, dict):
            return None
        pid = p.get("pane_id")
        if not isinstance(pid, str) or not ol.PANE_RE.fullmatch(pid) or pid in out:
            return None
        sess = p.get("agent_session")
        sess = sess.get("value") if isinstance(sess, dict) else None
        out[pid] = {"pane_id": pid, "birth": p.get("terminal_id"),
                    "agent_session": sess if isinstance(sess, str) else ""}
    return out


def _session_digest(label: str, agent_session: str) -> str:
    # Same derivation as remote-mcp/publisher.owner_session_digest(), the
    # source of every lease's session_digest (owner-lease-claim.py,
    # owner-dispatch-issue.py resolve via publisher.registry_resolver).
    return hashlib.sha256(f"{label}:{agent_session}".encode()).hexdigest()


def _held(o, reason):
    return {"lease_id": o["lease_id"], "label": o["label"], "generation": o["generation"],
            "pane": o["pane"], "reason": reason}


def plan_reap(conn, pane_snapshot, snapshot_age_s, now=None,
              max_snapshot_age_s=DEFAULT_MAX_SNAPSHOT_AGE_S, snapshot_at=None) -> dict:
    """Read-only. Returns one of:

      {"status": "skip", "reason": <str>}
      {"status": "ok", "candidates": [<observe_stale() dict>, ...],
       "held": [{"lease_id", "label", "generation", "pane", "reason"}, ...]}

    `pane_snapshot` is a `{pane_id: record}` projection (snapshot_from_pane_list)
    — `None` means the probe is unavailable. `snapshot_age_s` is the age in
    seconds of the data behind it (`None` when no freshness metadata exists).
    `snapshot_at` is the epoch seconds the snapshot was CAPTURED (reap_tick
    passes its own `captured_at`). `candidates` contains only
    `reason == "pane-gone"` observations; this function never releases
    anything.

    SKIP, for the whole tick, when:
      - `pane_snapshot` is `None` (probe unavailable) or not a dict (malformed);
      - any record in it is not a dict, or has an empty/missing `birth`;
      - `snapshot_age_s` is missing, negative, or exceeds `max_snapshot_age_s`.

    A `pane-gone` observation whose lease was acquired at or after
    `snapshot_at` is held `claimed_after_snapshot`, never a candidate: the
    snapshot predates (or ties) the claim, so the pane being absent from it
    proves nothing about whether the holder is alive (DESIGN-reap.md §3a).
    `snapshot_at=None` holds EVERY pane-gone observation this way -- fail-safe
    for a direct `plan_reap` caller that doesn't know when its snapshot was
    taken; `reap_tick` always passes a real `captured_at` once it has passed
    its own freshness check, so this arm never fires on the hub's path.

    Otherwise, a pane-gone observation whose pane id IS in the snapshot (under
    a different birth) is a candidate only when the record's agent_session is
    present and its digest positively differs from the lease's session_digest
    (the pane id was recycled to another agent). Same digest -> held
    `birth_reissued` (a herdr restart, the holder is alive); either side
    unknown -> held `identity_uncertain`.
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
    candidates, held = [], []
    for o in ol.observe_stale(conn, live_panes, now=now):
        if o["reason"] != "pane-gone":
            continue
        row = conn.execute("SELECT session_digest, acquired_at FROM owner_leases WHERE lease_id=?",
                           (o["lease_id"],)).fetchone()
        lease_digest, acquired_at = (row[0], row[1]) if row else ("", None)
        if snapshot_at is None or acquired_at is None or acquired_at >= ol._iso(snapshot_at):
            held.append(_held(o, "claimed_after_snapshot"))
            continue
        rec = pane_snapshot.get(o["pane"])
        if rec is None:
            candidates.append(o)
            continue
        live_session = rec.get("agent_session")
        if not (isinstance(live_session, str) and live_session
                and isinstance(lease_digest, str) and ol.SESSION_DIGEST_RE.fullmatch(lease_digest)):
            held.append(_held(o, "identity_uncertain"))
        elif _session_digest(o["label"], live_session) == lease_digest:
            held.append(_held(o, "birth_reissued"))
        else:
            candidates.append(o)
    return {"status": "ok", "candidates": candidates, "held": held}


def reap_tick(conn, pane_list_payload, captured_at, now=None,
              max_snapshot_age_s=DEFAULT_MAX_SNAPSHOT_AGE_S) -> dict:
    """One dry-run reap pass. `pane_list_payload` is raw `herdr pane list`
    output (None = the probe did not run or failed); `captured_at` is the
    epoch seconds the CALLER recorded when that output was read (herdr's
    payload carries no timestamp; None = unknown freshness -> skip).

    Returns plan_reap()'s skip dict, or
      {"status": "ok", "would_reap": [<reap() dry-run dict>, ...], "held": [...]}
    always with "dry_run": True. Writes nothing: reap() is called with its
    dry_run=True default and there is deliberately no parameter to change it.
    SQLite errors propagate (a failed tick, never a partial apply)."""
    now = time.time() if now is None else now
    snapshot = None
    if pane_list_payload is not None:
        snapshot = snapshot_from_pane_list(pane_list_payload)
        if snapshot is None:
            return {"status": "skip", "reason": "malformed_snapshot", "dry_run": True}
    age = None
    if isinstance(captured_at, (int, float)) and not isinstance(captured_at, bool):
        age = now - captured_at
    plan = plan_reap(conn, snapshot, age, now=now, max_snapshot_age_s=max_snapshot_age_s, snapshot_at=captured_at)
    if plan["status"] != "ok":
        return dict(plan, dry_run=True)
    return {"status": "ok", "dry_run": True, "would_reap": ol.reap(conn, plan["candidates"], now=now),
            "held": plan["held"]}
