"""owner_lease_renew.py — periodic in-place renewal of a REGISTERED label's
CURRENT live lease, and nothing else.

A separate module from owner_lease_delivery.py, which documents its own
adapter as never acquiring/renewing/releasing/reaping a lease
(lib/owner_lease_delivery.py:11-14) -- that invariant is load-bearing for
DeliveryGate's scope (admit/notice/reply-settlement only) and is not
loosened here. This module NEVER calls owner_lease.acquire() (r15/F1: a
concurrent release() landing between acquire()'s own internal re-read and
its INSERT let it silently mint a NEW lease_id/generation for the SAME
identity instead of raising LeaseConflict -- acquire()'s successor branch
has no way to distinguish "the row I just read is gone because someone
released it" from "no one has ever held this label," so it is never
called from here again). Renewal is exactly ONE conditional UPDATE of the
row renew_due() itself already read, keyed by that EXACT (lease_id,
generation): `UPDATE owner_leases SET renewed_at=?, expires_at=? WHERE
lease_id=? AND label=? AND generation=? AND released_at IS NULL AND
expires_at > ?`. A concurrent release/reap/unregister sets released_at
(this schema has no separate "revoked" column -- released_at IS NOT NULL
is the one way any lease ever stops being live) before this UPDATE can
run, so `rowcount` is 0 and nothing else is written. An expiry landing in
the same instant is caught by the same `expires_at > ?` clause. No INSERT
anywhere in this path: no new lease_id, no new generation, no new owner,
ever -- only the two columns on the one row already proven live are ever
touched.

OFF BY DEFAULT: nothing here is reachable unless a caller wires it behind
its own flag (remote-mcp/publisher.py: HERDR_OWNER_LEASE_RENEW=1, requiring
HERDR_OWNER_LEASE_DELIVERY=1 + HERDR_OWNER_LEASE_DB too -- this renews THAT
lease store, not a separate one).

Fail CLOSED, never a takeover:
  * no live lease for the label -> "no_live_lease", skipped (claiming a
    first lease is owner-lease-claim.py's job, not this pass's; this is
    also the outcome for an expired, released, or otherwise non-live
    lease -- ol._live() filters all three the same way, and none is ever
    revived here).
  * the label has no lifecycle_end_at recorded at all (R13-BOUNDS.md:
    register_owner()'s lifecycle_end_at, set only at approval) ->
    "no_lifecycle_bound", skipped -- renewal requires an explicit absolute
    bound; there is no default/unbounded renewal path.
  * now is already at or past that bound -> "lifecycle_ended", skipped --
    renewal stops for good; the label then fails closed on its own
    existing TTL exactly like any unrenewed lease, through the EXISTING
    owner_no_lease mechanism (lib/owner_lease_delivery.py), nothing extra
    needed here.
  * live lease not yet within margin_s of expiry -> "not_due", skipped (no
    thrashing every tick).
  * the registry has no current resolution for the label ->
    "identity_unresolvable", skipped.
  * the registry's CURRENT (pane, birth, session) does not exactly match
    the live lease's recorded holder -> "identity_mismatch", skipped (the
    holder changed or the pane is gone; re-claiming is a human/
    owner-lease-claim.py decision, never made here).
  * otherwise: the conditional UPDATE above, keyed by the EXACT (lease_id,
    generation) just read, with a TTL clamped so the new expires_at never
    crosses lifecycle_end_at. If a concurrent release/reap/expiry won the
    race (rowcount 0) -> "identity_mismatch", nothing else written; never
    touches any dispatch grant (this module never opens an
    owner_dispatch_auth store at all, and never issues one here either
    way).
"""
from __future__ import annotations

import time
from datetime import datetime, timezone

import owner_lease as ol

RENEW_MARGIN_S = 900   # renew once <=15 min remain. Chosen against publisher.py's
                        # own confirmed launchd cadence (StartInterval=15s,
                        # remote-mcp/com.herdr-control.remote-mcp.plist.template:
                        # 77-78): ~60 renewal attempts before an actual expiry even
                        # if dozens of consecutive ticks fail or are skipped.
RENEW_TTL_S = 3600     # 1h bounded renewal window, re-decided every due tick --
                        # never grows unbounded, and comfortably clears
                        # owner_lease_delivery.CLAIM_TTL_FLOOR_S (480s: the floor a
                        # FIRST claim must clear) by 8x, so a freshly renewed lease
                        # never itself falls below begin_notice()'s own
                        # MIN_LEASE_REMAINING_S (180s) fence before the next renewal
                        # is due.
assert 480 <= RENEW_TTL_S <= ol.MAX_TTL_S


def _ts(iso: str) -> float:
    return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


def renew_due(conn, label: str, registry_identity: tuple[str, str, str] | None, now: float | None = None,
              margin_s: int = RENEW_MARGIN_S, ttl_s: int = RENEW_TTL_S) -> str:
    """One label, one pass. registry_identity is (pane_id, pane_birth,
    session_digest) freshly resolved by the caller THIS pass, or None if
    unresolvable. Returns a short outcome string; never raises."""
    now = time.time() if now is None else now
    cur = ol._live(conn, label, now)
    if not cur:
        return "no_live_lease"
    lease_id, pane, birth, gen, _renewed, expires_at, sess = cur
    row = conn.execute("SELECT lifecycle_end_at FROM owner_projects WHERE label=?", (label,)).fetchone()
    end_iso = row[0] if row else None
    if end_iso is None:
        return "no_lifecycle_bound"
    end_at = _ts(end_iso)
    if now >= end_at:
        return "lifecycle_ended"
    if _ts(expires_at) - now > margin_s:
        return "not_due"
    if registry_identity is None:
        return "identity_unresolvable"
    if (pane, birth, sess) != registry_identity:
        return "identity_mismatch"
    effective_ttl = min(ttl_s, int(end_at - now))  # never renew past lifecycle_end_at
    if effective_ttl < 1:
        return "lifecycle_ended"

    def body():
        # ONE conditional UPDATE, keyed by the EXACT (lease_id, generation)
        # just read -- NEVER ol.acquire(), NEVER an INSERT (r15/F1). A
        # concurrent release/reap/unregister (released_at set) or an
        # expiry landing in the same instant (expires_at <= now_iso) makes
        # rowcount 0; nothing else is written in that case.
        now_iso = ol._iso(now)
        cur2 = conn.execute(
            "UPDATE owner_leases SET renewed_at=?, expires_at=? "
            "WHERE lease_id=? AND label=? AND generation=? AND released_at IS NULL AND expires_at > ?",
            (now_iso, ol._iso(now + effective_ttl), lease_id, label, gen, now_iso))
        if cur2.rowcount == 0:
            return "identity_mismatch"  # lost a race between the read above and here
        ol._event(conn, now, label, "renewed", lease_id, gen)
        return "renewed"

    try:
        return ol._tx(conn, body)
    except ol.Disabled:
        return "renew_refused"


def renew_all_due(conn, registry_resolve, now: float | None = None) -> dict[str, str]:
    """One pass over every REGISTERED label (owner_projects), label order.
    registry_resolve(label) -> (pane_id, pane_birth, session_digest) | None,
    called fresh for each label this pass (never cached across passes)."""
    now = time.time() if now is None else now
    out = {}
    for (label,) in conn.execute("SELECT label FROM owner_projects ORDER BY label").fetchall():
        out[label] = renew_due(conn, label, registry_resolve(label), now)
    return out
