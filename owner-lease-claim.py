#!/usr/bin/env python3
"""owner-lease-claim.py --label L --ttl SECONDS — one-shot lease acquisition
bound to the EXISTING registry owners row (OFF BY DEFAULT, INERT here).

Refuses unless HERDR_OWNER_LEASE_WRITER=1 and HERDR_OWNER_LEASE_DELIVERY=1
and HERDR_OWNER_LEASE_DB names an existing, migrated DB (never created or
migrated here). The (pane_id, pane_birth, session digest) come ONLY from the
registry row (remote-mcp/publisher.registry_resolver); the digest is a
registry-attested identity, not authentication of the process at the pane.
Requires an existing owner_projects mapping (never registers one). Acquires
only as an INITIAL claim (owner_lease.claim_initial): generation 1 for a label
with no lease or request history at all. Never renews, releases, reaps,
stales or takes over. The lease DB is opened via lib/private_sqlite.
--ttl is refused below lib/owner_lease_delivery.py's CLAIM_TTL_FLOOR_S
(MIN_LEASE_REMAINING_S + CLAIM_TO_DELIVERY_SLACK_S, currently 180s + 300s =
480s) (REVIEW.md Low-1, tightened round 2): a lease claimed with too short a
TTL would pass claim_initial()'s own 1..MAX_TTL_S check, then perpetually
fail DeliveryGate.begin_notice()'s `lease_too_short` fence, parking every
queued item at `queued` forever -- fails closed, but silently, so this is
caught here instead. The floor is MIN_LEASE_REMAINING_S PLUS a real
operational margin (CLAIM_TO_DELIVERY_SLACK_S), not just MIN_LEASE_REMAINING_S
itself: begin_notice()'s own remaining-time fence is evaluated at whatever
later wall-clock moment the separate delivery process reaches it, so a claim
with exactly MIN_LEASE_REMAINING_S of TTL has zero slack for that delay.
Exit: 0 acquired (prints generation); 2 refused (typed reason); 4 config.
Rollback: unset the flags; the lease expires on its own TTL.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))

import owner_lease as ol  # noqa: E402
import owner_lease_delivery as oled  # noqa: E402


def main(argv=None, resolve=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--ttl", type=int, required=True)
    a = ap.parse_args(argv)
    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1" or os.environ.get("HERDR_OWNER_LEASE_DELIVERY") != "1":
        print("refused:flags_off")
        return 4
    if a.ttl < oled.CLAIM_TTL_FLOOR_S:
        print(f"refused:ttl_below_delivery_floor:{oled.CLAIM_TTL_FLOOR_S}")
        return 2
    os.umask(0o077)
    db = os.environ.get("HERDR_OWNER_LEASE_DB", "")
    try:
        conn = ol.open_rw_checked(db, require_table="owner_leases")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    except ol.SchemaMigrationRequired as exc:
        print(f"refused:schema_migration_required:{exc.cur}->{exc.target}:owner-lease-migrate.py --db {db} --apply")
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
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (a.label,)).fetchone():
            print("refused:owner_project_unmapped")
            return 2
        try:
            gen = ol.claim_initial(conn, a.label, pane, birth, a.ttl, digest)
        except ol.LeaseConflict:
            print("refused:not_initial")
            return 2
        except (ol.Disabled, ol.InvalidOwner, ValueError) as exc:
            print(f"refused:{type(exc).__name__}")
            return 2
    finally:
        conn.close()
    print(f"acquired:{a.label}:gen{gen}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
