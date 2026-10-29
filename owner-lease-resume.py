#!/usr/bin/env python3
"""owner-lease-resume.py --label L --ttl SECONDS --expect-prev-generation N
[--apply] — one-shot RESUME of a label's own EXPIRED, unreleased lease by
the SAME registered holder (OFF BY DEFAULT, INERT here; see tmp/in/r10/
SAME-HOLDER.md / tmp/in/r11/RESUME.md for why this exists).

Resuming is not an ownership change: the holder is already the registry's
own `owners` row for this label (remote-mcp/publisher.registry_resolver),
so unlike owner-dispatch-issue.py's build-form/issue flow (whose whole
point is a human approving a GRANT of dispatch authority, possibly to a
new holder) this needs no approval form, no auth/grant row, no sha256-
pinned record -- it is pure continuity of an identity the system already
trusts, the same reasoning owner-lease-claim.py already applies to initial
claims. See owner-dispatch-issue.py:394-414's own docstring: "a same-holder
'successor' is a renewal in disguise ... that is acquire()'s job, not
[claim_successor's]." This wraps exactly that job: lib/owner_lease.py's
acquire(), never claim_initial/claim_successor.

Refuses unless HERDR_OWNER_LEASE_WRITER=1 and HERDR_OWNER_LEASE_DELIVERY=1
and HERDR_OWNER_LEASE_DB names an existing, migrated DB (never created or
migrated here). The (pane_id, pane_birth, session digest) come ONLY from
the registry row (remote-mcp/publisher.registry_resolver) -- identical to
owner-lease-claim.py's own identity-sourcing rule -- never from a CLI flag.

DRY-RUN BY DEFAULT: without --apply, prints the plan and writes nothing.
--apply is required to actually call acquire().

Preconditions, all refused (rc 2, nothing written) before any write:
  - no prior lease row for this label at all            -> no_predecessor
    (this is an INITIAL case: use owner-lease-claim.py instead)
  - the most recent lease row's generation != --expect-prev-generation
    (an explicit CAS precondition, same shape as claim_successor's own
    expected_prev_gen, since acquire() itself takes no such parameter)
                                                          -> wrong_prev_generation
  - that row is still LIVE as of `now` (expires_at > now AND
    released_at IS NULL) -- never takes over an unexpired lease, same
    identity or not; that is acquire()'s own renewal branch, reached only
    when the SAME identity resumes a lease still live, which this script
    deliberately never attempts (it exists for the EXPIRED case only)
                                                          -> live_predecessor
  - that row's (pane_id, pane_birth, session_digest) != the CURRENT
    registry-resolved identity for this label -- a holder change belongs
    to owner-dispatch-issue.py's claim_successor path (human-approved
    grant), never this script                            -> different_holder

CONCURRENT-MUTATION GUARD (best effort, not a true CAS -- see NOTES.md):
acquire() takes no "expected current generation" parameter the way
claim_successor() does, and its own internal transaction (lib/owner_lease.
py:_tx, BEGIN IMMEDIATE) cannot be composed with a caller-held transaction
on the same connection, so the precondition read above and the acquire()
call below are NOT one atomic unit -- a concurrent acquire()/claim_successor
()/release() between them is possible (same-process serialization via
SQLite's own busy_timeout prevents corruption, never a stale assumption).
acquire()'s OWN identity check still makes it impossible for this call to
silently steal a DIFFERENT holder's lease (LeaseConflict). The residual
risk is a SURPRISING generation number -- e.g. a concurrent same-identity
resume already renewed or re-minted in between. Caught AFTER the fact: the
returned generation is compared to --expect-prev-generation + 1; a
mismatch prints `ambiguous:resumed_unexpected_generation:...` and exits 6
(the write already happened and cannot be undone non-destructively -- same
"needs inspection by hand, never silently accepted" posture as rc 6 in
owner-dispatch-issue.py).

Exit: 0 resumed (prints the new generation) or dry-run plan printed;
2 refused (typed reason, pre-claim, nothing written); 4 config/flags;
6 resumed but at an unexpected generation (written; inspect by hand).
Rollback: unset the flags; a resumed lease still expires on its own TTL,
same as any other acquire()/claim_* lease.
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))

import owner_lease as ol  # noqa: E402
import owner_lease_delivery as oled  # noqa: E402


def main(argv=None, resolve=None, now=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--ttl", type=int, required=True)
    ap.add_argument("--expect-prev-generation", type=int, required=True)
    ap.add_argument("--apply", action="store_true", help="without this, print the plan and write nothing")
    a = ap.parse_args(argv)
    clock = (lambda: now) if now is not None else time.time

    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1" or os.environ.get("HERDR_OWNER_LEASE_DELIVERY") != "1":
        print("refused:flags_off")
        return 4
    if a.ttl < oled.CLAIM_TTL_FLOOR_S:
        print(f"refused:ttl_below_delivery_floor:{oled.CLAIM_TTL_FLOOR_S}")
        return 2
    if a.expect_prev_generation < 1:
        print("refused:expect_prev_generation_must_be_1_or_more")
        return 2

    os.umask(0o077)
    db = os.environ.get("HERDR_OWNER_LEASE_DB", "")
    if a.apply:
        try:
            conn = ol.open_rw_checked(db, require_table="owner_leases")
        except ValueError as exc:
            print(f"refused:lease_{exc}")
            return 4
        except ol.SchemaMigrationRequired as exc:
            print(f"refused:schema_migration_required:{exc.cur}->{exc.target}:owner-lease-migrate.py --db {db} --apply")
            return 4
    else:
        # R17b: without --apply this never migrates, never writes -- read-only open.
        try:
            conn = ol.open_ro(db, require_table="owner_leases")
        except ValueError as exc:
            print(f"refused:lease_{exc}")
            return 4

    if resolve is None:
        import publisher  # noqa: E402
        resolve = publisher.registry_resolver
    reg = resolve(a.label)
    if not reg:
        conn.close()
        print("refused:not_registered_or_no_session")
        return 2
    pane, birth, digest = reg

    try:
        if not a.apply:
            cur_v, target_v = ol.schema_status(conn)
            if cur_v < target_v:
                print(f"schema_pending:{cur_v}->{target_v} (owner-lease-migrate.py --db {db} --apply) -- "
                      f"plan cannot be confirmed until migrated")
                return 0
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (a.label,)).fetchone():
            print("refused:owner_project_unmapped")
            return 2
        row = conn.execute(
            "SELECT pane_id, pane_birth, session_digest, generation, expires_at, released_at "
            "FROM owner_leases WHERE label=? ORDER BY generation DESC LIMIT 1", (a.label,)).fetchone()
        if not row:
            print("refused:no_predecessor")
            return 2
        prev_pane, prev_birth, prev_digest, prev_gen, prev_expires_at, prev_released_at = row
        if prev_gen != a.expect_prev_generation:
            print(f"refused:wrong_prev_generation:observed={prev_gen}:expected={a.expect_prev_generation}")
            return 2
        now_s = clock()
        # same freshness test as lib/owner_lease.py's own _live(): unreleased AND unexpired
        if prev_released_at is None and ol._iso(now_s) < prev_expires_at:  # noqa: SLF001 (same-module reuse)
            print("refused:live_predecessor")
            return 2
        if (prev_pane, prev_birth, prev_digest) != (pane, birth, digest):
            print("refused:different_holder")  # a holder change is claim_successor's job, not this script's
            return 2

        if not a.apply:
            print(f"plan:resume:{a.label}:from_gen{prev_gen}:pane={pane}:birth={birth}:ttl={a.ttl}"
                  " (dry-run; pass --apply to write)")
            return 0

        new_gen = ol.acquire(conn, a.label, pane, birth, a.ttl, now_s, session_digest=digest)
    except (ol.Disabled, ol.InvalidOwner, ValueError) as exc:
        print(f"refused:{type(exc).__name__}")
        return 2
    except ol.LeaseConflict as exc:
        print(f"refused:LeaseConflict:{exc}")
        return 2
    finally:
        conn.close()

    if new_gen != a.expect_prev_generation + 1:
        print(f"ambiguous:resumed_unexpected_generation:expected={a.expect_prev_generation + 1}:actual={new_gen}"
              " -- a concurrent writer changed state between the precondition read and this call;"
              " the resume DID happen (acquire() never silently steals a different holder's lease -- see"
              " NOTES.md), but not at the generation this run expected. Inspect the store by hand.")
        return 6
    print(f"resumed:{a.label}:gen{new_gen}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
