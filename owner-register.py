#!/usr/bin/env python3
"""owner-register.py --label L --project P [--max-open N] [--dry-run] —
one-shot CLI around owner_lease.register_owner() for ONE label (REVIEW.md
Medium-1: `register_owner()` previously had zero production/CLI callers —
every caller in the tree was a verify-*.py test. The owner_projects row it
writes is the first write everything downstream of it (owner-lease-claim.py,
owner-dispatch.py, queue-supervisor.py) is fenced on, so this is the single
most load-bearing write in the whole activation and gets exactly the same
refusal posture as owner-lease-claim.py).

Refuses unless HERDR_OWNER_LEASE_WRITER=1 and HERDR_OWNER_LEASE_DB names an
EXISTING, already-migrated DB (owner_projects table present; this script
never creates or migrates the DB — lib/private_sqlite.open_private only ever
opens one). Refuses a label whose registry row (pane_id/pane_birth/session
digest) is not resolvable — mirrors owner-lease-claim.py's own
registry_resolver() gate: a label can never be mapped to a project unless
something is actually running in that pane right now, same as the lease
claim it feeds.

--dry-run prints the exact row (label, project, max_open, registered_at)
without writing it, and is still subject to every refusal above (a dry-run
of a refused call reports the refusal, not a fake preview).

Exit: 0 registered (or dry-run); 2 refused (typed reason); 4 config.
Rollback: lib/owner_lease.py has no unregister_owner() — register_owner()
is intentionally append-only/idempotent like every other write in this
contract. Undo a mistaken registration with
    DELETE FROM owner_projects WHERE label=?
run directly against the configured HERDR_OWNER_LEASE_DB, before any lease
or request references the label — owner_leases/owner_requests both FOREIGN
KEY onto owner_projects.label, so SQLite's own foreign_keys=ON (every
connection here) refuses that DELETE once anything does. This script prints
that exact rollback line after every successful registration and dry-run.
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))

import owner_lease as ol  # noqa: E402
import private_sqlite  # noqa: E402


def _rollback_line(db: str, label: str) -> str:
    return (f"rollback: DELETE FROM owner_projects WHERE label={label!r} "
            f"(run against {db}; refused by foreign_keys=ON once any lease/request exists for this label)")


def main(argv=None, resolve=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--max-open", type=int, default=ol.DEFAULT_MAX_OPEN)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1":
        print("refused:flags_off")
        return 4
    os.umask(0o077)
    db = os.environ.get("HERDR_OWNER_LEASE_DB", "")
    try:
        conn = private_sqlite.open_private(db, ol.connect, require_table="owner_projects")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    try:
        if resolve is None:
            import publisher  # noqa: E402
            resolve = publisher.registry_resolver
        reg = resolve(a.label)
        if not reg:
            print("refused:not_registered_or_no_session")
            return 2
        try:
            proj = ol.canonical_project(a.project)
        except ol.InvalidOwner as exc:
            print(f"refused:{type(exc).__name__}")
            return 2
        if not isinstance(a.max_open, int) or not 1 <= a.max_open <= ol.MAX_OPEN_LIMIT:
            print(f"refused:max_open_out_of_range:1..{ol.MAX_OPEN_LIMIT}")
            return 2
        if a.dry_run:
            iso = datetime.fromtimestamp(time.time(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
            print(f"dry-run:owner_projects(label={a.label!r}, project={proj!r}, "
                  f"registered_at={iso!r}, max_open={a.max_open})")
            print(_rollback_line(db, a.label))
            return 0
        try:
            proj = ol.register_owner(conn, a.label, a.project, a.max_open)
        except (ol.InvalidOwner, ol.Disabled, ValueError) as exc:
            print(f"refused:{type(exc).__name__}")
            return 2
    finally:
        conn.close()
    print(f"registered:{a.label}:{proj}")
    print(_rollback_line(db, a.label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
