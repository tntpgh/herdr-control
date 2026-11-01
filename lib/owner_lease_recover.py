"""owner_lease_recover.py — two authorized, narrowly-scoped emergency-recovery
paths for a REGISTERED label's lifecycle_end_at, mutually exclusive by
construction (each refuses cleanly on the other's precondition, never
silently falling through):

  recover_lifecycle()       -- bound is SET and has already PASSED.
  bind_missing_lifecycle()  -- bound was NEVER SET at all (NULL).

The original docstring below (recover_lifecycle()'s own design) is
unchanged except for this lead-in; bind_missing_lifecycle()'s own
docstring (below recover_lifecycle()) repeats only what differs from it.

recover_lifecycle() is the authorized emergency-recovery path for a
REGISTERED label whose lifecycle_end_at has already passed with an empty (or
otherwise unknown-to-the-caller) unregister_token, so neither the normal
renewal pass (owner_lease_renew.renew_due: "lifecycle_ended", never revives
it) nor the normal unregister_owner()+reregister_owner() cycle
(unregister_owner() REQUIRES a truthy stored token it can verify --
R13-BOUNDS.md: "A label registered with no token can never be unregistered
through this function") can ever move the row again. A owner_projects-row-
only CAS, same posture and TOCTOU discipline as reregister_owner() (r16/F3):
the advisory pre-check below is NOT the authorization for a real --apply --
it only CAPTURES the (lifecycle_end_at, unregister_token) pair this call
itself just read, and the final write is keyed on that EXACT captured pair,
never re-derived from any caller-supplied "expected" value (there is no such
parameter here -- unlike reregister_owner's `old_token`, nothing about the
current row's bound or token is a secret the caller must already know; the
actual authorization is the confirmation leg below). A concurrent
register/reregister/recover call that already committed a DIFFERENT pair in
the window makes the WHERE clause match nothing (rowcount 0) -> "race_lost",
nothing written, never silently overwriting the other caller's already-
reported success.

Authorization has two independent legs, both required, both checked in
EVERY mode (dry-run must report the SAME refusal a real run would --
unregister_owner()'s own convention):
  1. `confirmation_ref` is required and non-empty. This module is DB-only
     (same separation as every other owner_lease* module: owner_lease.py,
     owner_lease_renew.py, owner_lease_delivery.py) and never opens a forms
     directory itself -- the CLI (owner-lease-recover.py) is the ONLY place
     that reads a formserve answer id against the pinned forms state dir and
     checks it is ANSWERED, approved, and bound to this exact
     (label, new_lifecycle_end_at, caller identity). `confirmation_ref` here
     is the opaque, already-validated form id, recorded ONLY in the audit
     event for traceability; this module trusts the CLI already did that
     work and never re-derives or re-checks it.
  2. Never self-extension: if the label currently has a live lease, its
     holder's (pane_id, pane_birth) must NOT equal the caller's own
     (caller_pane_id, caller_pane_birth) -- an agent can never grant itself
     more runway by running this against a label it already holds. With no
     live lease there is no holder to compare against and this leg is
     satisfied trivially.

Bounded: `new_lifecycle_end_at` can be at most ol.MAX_TTL_S (24h) past `now`,
and must strictly extend the label's CURRENT bound -- a stuck label gets a
short runway, never an unbounded jump in one call; a second recovery later
extends it again if still needed. This is also the replay guard: a
replayed confirmation against a label whose bound this call already moved
into the future reads back as "not_expired" (nothing left to recover), not
a second grant.

Refuses (ol.Disabled, same exception ol._tx raises for every other writer)
while owner_state.enabled != 1 -- checked in an explicit pre-read too so a
dry-run reports the same refusal a real --apply would, not a false
"would_recover" while the whole system is off.

Refuses (InvalidOwner) a label with no owner_projects row at all, a label
registered to a DIFFERENT project than the caller named (same "wrong
owner/label" guard reregister_owner's project check gives), and a label
that is already unregistered (unregistered_at IS NOT NULL) -- that row
already has its own documented, explicit, authorized restore path,
owner-lease-reregister.py; this module is never a second way to clear it.

Refuses ("no_lifecycle_bound" / "not_expired", informational strings, not
exceptions -- nothing wrong with the caller's authorization, just nothing
to recover) a label with no lifecycle_end_at recorded at all, or one whose
current bound has not actually passed yet -- the ordinary renewal/
unregister path covers either case; this is strictly the
already-past-its-bound emergency.

Never creates or revives a lease, never touches owner_leases: this is a
owner_projects-row-only update, same scope as reregister_owner().
"""
from __future__ import annotations

import secrets
import time
from datetime import datetime, timezone

import owner_lease as ol


def _ts(iso: str) -> float:
    return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


def recover_lifecycle(conn, label: str, project: str, new_lifecycle_end_at: float,
                      caller_pane_id: str, caller_pane_birth: str, confirmation_ref: str,
                      now: float | None = None, dry_run: bool = True) -> tuple[str, str | None]:
    """Returns (status, new_token). new_token is non-None only on
    "recovered" -- printed ONCE by the caller (owner-lease-recover.py);
    never stored anywhere but the owner_projects row and never written into
    owner_events (the event's ref/detail stay free of secrets, same
    convention as every other owner_events row in this tree).

    status is one of: "recovered", "would_recover", "race_lost",
    "no_lifecycle_bound", "not_expired".

    Raises InvalidOwner (no such label, project mismatch, or already
    unregistered), Unauthorized (self-extension), ValueError (missing
    confirmation_ref or an out-of-bounds new_lifecycle_end_at), ol.Disabled
    (owner_state.enabled != 1)."""
    now = time.time() if now is None else now
    ol._check_holder(caller_pane_id, caller_pane_birth)
    if not confirmation_ref or not isinstance(confirmation_ref, str):
        raise ValueError("confirmation_ref is required")
    if not isinstance(new_lifecycle_end_at, (int, float)) or isinstance(new_lifecycle_end_at, bool):
        raise ValueError("new_lifecycle_end_at must be an epoch-seconds value")
    if new_lifecycle_end_at <= now:
        raise ValueError("new_lifecycle_end_at must be in the future")
    if new_lifecycle_end_at - now > ol.MAX_TTL_S:
        raise ValueError(f"new_lifecycle_end_at exceeds the {ol.MAX_TTL_S}s bound")
    proj = ol.canonical_project(project)

    if conn.execute("SELECT enabled FROM owner_state WHERE id=1").fetchone() != (1,):
        raise ol.Disabled("owner leasing is disabled")

    row = conn.execute("SELECT project, unregistered_at, lifecycle_end_at, unregister_token "
                       "FROM owner_projects WHERE label=?", (label,)).fetchone()
    if not row:
        raise ol.InvalidOwner(f"{label} is not a registered owner")
    stored_project, unregistered_at, end_iso, stored_token = row
    if stored_project != proj:
        raise ol.InvalidOwner(f"{label} is registered to {stored_project!r}, not {proj!r}")
    if unregistered_at is not None:
        raise ol.InvalidOwner(f"{label} is unregistered; use owner-lease-reregister.py, not this path")
    if end_iso is None:
        return "no_lifecycle_bound", None
    end_at = _ts(end_iso)
    if now < end_at:
        return "not_expired", None
    if new_lifecycle_end_at <= end_at:
        raise ValueError("new_lifecycle_end_at must extend past the current bound")

    cur = ol._live(conn, label, now)
    if cur and (cur[1], cur[2]) == (caller_pane_id, caller_pane_birth):
        raise ol.Unauthorized(f"{label}: self-extension refused -- caller is the current live holder")

    if dry_run:
        return "would_recover", None

    new_token = secrets.token_hex(32)
    new_end_iso = ol._iso(new_lifecycle_end_at)

    def body():
        cur2 = conn.execute(
            "UPDATE owner_projects SET lifecycle_end_at=?, unregister_token=? "
            "WHERE label=? AND unregistered_at IS NULL AND lifecycle_end_at IS ? AND unregister_token IS ?",
            (new_end_iso, new_token, label, end_iso, stored_token))
        if cur2.rowcount == 0:
            return "race_lost", None
        ol._event(conn, now, label, "lifecycle_recovered", ref=confirmation_ref,
                  detail=f"new_lifecycle_end_at:{new_end_iso}")
        return "recovered", new_token

    return ol._tx(conn, body)


def bind_missing_lifecycle(conn, label: str, project: str, new_lifecycle_end_at: float,
                           caller_pane_id: str, caller_pane_birth: str, confirmation_ref: str,
                           now: float | None = None, dry_run: bool = True) -> tuple[str, str | None]:
    """The companion to recover_lifecycle(), for the OTHER gap neither
    renew_due() nor recover_lifecycle() itself covers: a REGISTERED label
    whose lifecycle_end_at was never recorded at all (NULL), predating
    R13-BOUNDS.md or inserted by a caller that omitted it. recover_lifecycle()
    refuses this exact row ("no_lifecycle_bound") on purpose -- it is strictly
    the already-expired-bound emergency, never a first-time bind. This
    function is strictly the opposite: it refuses ("already_bound") the
    moment lifecycle_end_at is anything but NULL, so it can never be used as
    a second way to move a bound recover_lifecycle() already owns.

    Same two-leg authorization (confirmation_ref required and checked by the
    CLI, never self-extension), same CAS discipline keyed on the EXACT
    (unregistered_at, lifecycle_end_at) pair this call read -- a concurrent
    bind/recover/reregister that already committed a different pair makes
    the WHERE clause match nothing ("race_lost"), nothing written.

    Deliberately narrower than recover_lifecycle(): mints NO fresh
    unregister_token (the row's existing token, however empty, is left
    exactly as-is -- unregister capability is a separate, unrequested
    concern; this call's only job is the missing bound) and touches no
    table but owner_projects -- existing owner_leases/owner_requests
    history for the label is never read or written here.

    status is one of: "bound", "would_bind", "race_lost", "already_bound".

    Raises InvalidOwner (no such label, project mismatch, or already
    unregistered), Unauthorized (self-extension), ValueError (missing
    confirmation_ref or an out-of-bounds new_lifecycle_end_at), ol.Disabled
    (owner_state.enabled != 1)."""
    now = time.time() if now is None else now
    ol._check_holder(caller_pane_id, caller_pane_birth)
    if not confirmation_ref or not isinstance(confirmation_ref, str):
        raise ValueError("confirmation_ref is required")
    if not isinstance(new_lifecycle_end_at, (int, float)) or isinstance(new_lifecycle_end_at, bool):
        raise ValueError("new_lifecycle_end_at must be an epoch-seconds value")
    if new_lifecycle_end_at <= now:
        raise ValueError("new_lifecycle_end_at must be in the future")
    if new_lifecycle_end_at - now > ol.MAX_TTL_S:
        raise ValueError(f"new_lifecycle_end_at exceeds the {ol.MAX_TTL_S}s bound")
    proj = ol.canonical_project(project)

    if conn.execute("SELECT enabled FROM owner_state WHERE id=1").fetchone() != (1,):
        raise ol.Disabled("owner leasing is disabled")

    row = conn.execute("SELECT project, unregistered_at, lifecycle_end_at, unregister_token "
                       "FROM owner_projects WHERE label=?", (label,)).fetchone()
    if not row:
        raise ol.InvalidOwner(f"{label} is not a registered owner")
    stored_project, unregistered_at, end_iso, stored_token = row
    if stored_project != proj:
        raise ol.InvalidOwner(f"{label} is registered to {stored_project!r}, not {proj!r}")
    if unregistered_at is not None:
        raise ol.InvalidOwner(f"{label} is unregistered; use owner-lease-reregister.py, not this path")
    if end_iso is not None:
        return "already_bound", None

    cur = ol._live(conn, label, now)
    if cur and (cur[1], cur[2]) == (caller_pane_id, caller_pane_birth):
        raise ol.Unauthorized(f"{label}: self-extension refused -- caller is the current live holder")

    if dry_run:
        return "would_bind", None

    new_end_iso = ol._iso(new_lifecycle_end_at)

    def body():
        cur2 = conn.execute(
            "UPDATE owner_projects SET lifecycle_end_at=? "
            "WHERE label=? AND unregistered_at IS NULL AND lifecycle_end_at IS NULL AND unregister_token IS ?",
            (new_end_iso, label, stored_token))
        if cur2.rowcount == 0:
            return "race_lost", None
        ol._event(conn, now, label, "lifecycle_bound", ref=confirmation_ref,
                  detail=f"new_lifecycle_end_at:{new_end_iso}")
        return "bound", None

    return ol._tx(conn, body)
