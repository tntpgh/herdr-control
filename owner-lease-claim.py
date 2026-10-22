#!/usr/bin/env python3
"""owner-lease-claim.py --label L --ttl SECONDS — one-shot lease acquisition
bound to the EXISTING registry owners row (OFF BY DEFAULT, INERT here).

Refuses unless HERDR_OWNER_LEASE_WRITER=1 and HERDR_OWNER_LEASE_DELIVERY=1
and HERDR_OWNER_LEASE_DB names an existing, migrated DB (never created or
migrated here). The (pane_id, pane_birth, session digest) come ONLY from the
registry row (remote-mcp/publisher.registry_resolver); the digest is a
registry-attested identity, not authentication of the process at the pane.
Requires an existing owner_projects mapping (never registers one). Acquires
only when NO live lease exists: never renews, reaps, or takes over.
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


def main(argv=None, resolve=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--ttl", type=int, required=True)
    a = ap.parse_args(argv)
    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1" or os.environ.get("HERDR_OWNER_LEASE_DELIVERY") != "1":
        print("refused:flags_off")
        return 4
    db = os.environ.get("HERDR_OWNER_LEASE_DB", "")
    if not db or not Path(db).is_file():
        print("refused:lease_db_missing")
        return 4
    if resolve is None:
        import publisher  # noqa: E402
        resolve = publisher.registry_resolver
    reg = resolve(a.label)
    if not reg:
        print("refused:not_registered_or_no_session")
        return 2
    pane, birth, digest = reg
    conn = ol.connect(db)
    try:
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (a.label,)).fetchone():
            print("refused:owner_project_unmapped")
            return 2
        try:
            gen = ol.acquire(conn, a.label, pane, birth, a.ttl, session_digest=digest, allow_renew=False)
        except ol.LeaseConflict:
            print("refused:lease_exists")
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
