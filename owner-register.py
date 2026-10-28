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
EXISTING private DB (owner_projects table present; never CREATES one).
R17b: this script NEVER migrates the schema. --dry-run opens read-only
(ol.open_ro(), sqlite mode=ro) and reports `schema_pending:<cur>-><target>`
if the store is behind, alongside the row it would write -- the engine
itself rejects any write attempt, not caller discipline. The real write
path (ol.open_rw_checked()) refuses `schema_migration_required:<cur>-><target>`
before opening for write if the store is behind -- never advances the
schema as a side effect of a register call. owner-lease-migrate.py is the
one explicit, backed-up path a schema now advances through (R17b; R17's
open_and_migrate(), which migrated on every open including --dry-run, was
rejected on review: "zero business-row writes" is not read-only).
Refuses a label whose registry row (pane_id/pane_birth/session digest) is
not resolvable — mirrors owner-lease-claim.py's own registry_resolver()
gate: a label can never be mapped to a project unless something is
actually running in that pane right now, same as the lease claim it feeds.

--dry-run prints the exact row (label, project, max_open, registered_at)
without writing it, and is still subject to every refusal above (a dry-run
of a refused call reports the refusal, not a fake preview).

Exit: 0 registered (or dry-run); 2 refused (typed reason, including
AlreadyUnregistered -- r15/F2: a plain re-run of this script on a label
owner-lease-unregister.py has already turned off REFUSES rather than
silently clearing unregistered_at and discarding whatever token/bound was
just supplied; owner-lease-reregister.py is the real, explicit, authorized
recovery path, see its own docstring); 4 config.
Rollback: owner-lease-unregister.py (R12-RENEWAL.md) is the supported
per-label rollback -- releases any live lease and sets
owner_projects.unregistered_at (schema v4), returning the label to legacy
delivery under the per-label gate, refusing while open owner_requests
exist. It never DELETEs the owner_projects row either (lib/owner_lease.py's
unregister_owner() never attempts one). The row's raw DELETE path below
remains available for a same-run typo before anything else references the
label, but is no longer the primary rollback once a lease or request
exists. register_owner() itself remains intentionally append-only/
idempotent; this is a separate, later rollback script, not a change to
register_owner()'s own contract. For a same-run typo before any lease or
request references the label, the raw DELETE still works too:
    DELETE FROM owner_projects WHERE label=?
run directly against the configured HERDR_OWNER_LEASE_DB, before any lease
or request references the label — owner_leases/owner_requests both FOREIGN
KEY onto owner_projects.label, so SQLite's own foreign_keys=ON (every
connection here) refuses that DELETE once anything does. This script prints
that exact rollback line after every successful registration and dry-run
(REVIEW.md round-2 Minor: including the idempotent re-registration of an
already-active, already-leased label, by which point the DELETE is
guaranteed to be refused). Once the DELETE is refused: owner-lease-unregister.py
is the real per-label procedure (above); the global, non-destructive fallback is
lib/owner_lease.py's own disable(conn) — a single non-destructive
`UPDATE owner_state SET enabled=0`, so every mutation fails closed while
every table, grant and the owner_events/owner_requests/owner_dispatch_auth
audit trail is preserved and readers (observe_stale, check_fence,
export_backup) keep working — or unsetting HERDR_OWNER_LEASE_DELIVERY /
HERDR_OWNER_DISPATCH / HERDR_QUEUE_SUPERVISOR. Stop admission; never delete
once anything references the label. This script prints that fallback line
too whenever the DELETE would be refused (any existing lease or request for
the label at the time of this run).
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


def _rollback_line(db: str, label: str, delete_will_be_refused: bool) -> str:
    line = (f"rollback: DELETE FROM owner_projects WHERE label={label!r} "
            f"(run against {db}; refused by foreign_keys=ON once any lease/request exists for this label)")
    if delete_will_be_refused:
        line += (f"\nDELETE refused (lease/request already exists for {label!r}): "
                 "stop admission instead -- disable the label via lib/owner_lease.py's "
                 "disable(conn) (non-destructive: flips owner_state.enabled=0, fails every "
                 "mutation closed, preserves every grant and the full audit trail) or unset "
                 "HERDR_OWNER_LEASE_DELIVERY / HERDR_OWNER_DISPATCH / HERDR_QUEUE_SUPERVISOR; "
                 "never delete once a lease or request references the label.")
    return line


def main(argv=None, resolve=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--max-open", type=int, default=ol.DEFAULT_MAX_OPEN)
    ap.add_argument("--lifecycle-end", type=float, default=None,
                    help="ABSOLUTE epoch seconds (R13-BOUNDS.md); owner_lease_renew.py never renews a label "
                         "with no bound recorded here, and never renews past it")
    ap.add_argument("--unregister-token", default=None,
                    help="the authorization owner-lease-unregister.py will require verbatim; a label "
                         "registered with none can never be unregistered through that script")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1":
        print("refused:flags_off")
        return 4
    os.umask(0o077)
    db = os.environ.get("HERDR_OWNER_LEASE_DB", "")

    # R17b: the DB open is the ONLY thing that differs between dry-run and
    # a real write -- dry-run opens read-only (sqlite mode=ro) and NEVER
    # migrates; the real write path refuses schema_migration_required
    # instead of migrating implicitly. Everything else below runs in the
    # SAME order as before this fix (permission/open check, THEN resolve,
    # THEN canonical_project, THEN max_open) so a non-DB validation failure
    # on an unresolvable/invalid label never masks a DB-permission refusal.
    if a.dry_run:
        try:
            conn = ol.open_ro(db, require_table="owner_projects")
        except ValueError as exc:
            print(f"refused:lease_{exc}")
            return 4
    else:
        try:
            conn = ol.open_rw_checked(db, require_table="owner_projects")
        except ValueError as exc:
            print(f"refused:lease_{exc}")
            return 4
        except ol.SchemaMigrationRequired as exc:
            print(f"refused:schema_migration_required:{exc.cur}->{exc.target}:owner-lease-migrate.py --db {db} --apply")
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
            cur, target = ol.schema_status(conn)
            if cur < target:
                print(f"schema_pending:{cur}->{target} (owner-lease-migrate.py --db {db} --apply)")
            iso = datetime.fromtimestamp(time.time(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
            end_iso = (datetime.fromtimestamp(a.lifecycle_end, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
                      if a.lifecycle_end is not None else None)
            print(f"dry-run:owner_projects(label={a.label!r}, project={proj!r}, "
                  f"registered_at={iso!r}, max_open={a.max_open}, lifecycle_end_at={end_iso!r}, "
                  f"unregister_token={'<set>' if a.unregister_token else None})")
            refused_delete = bool(conn.execute(
                "SELECT 1 FROM owner_leases WHERE label=? UNION SELECT 1 FROM owner_requests WHERE label=? LIMIT 1",
                (a.label, a.label)).fetchone())
            print(_rollback_line(db, a.label, refused_delete))
            return 0

        try:
            proj = ol.register_owner(conn, a.label, a.project, a.max_open, lifecycle_end_at=a.lifecycle_end,
                                     unregister_token=a.unregister_token)
        except ol.AlreadyUnregistered as exc:
            print(f"refused:AlreadyUnregistered:{exc}")
            return 2
        except (ol.InvalidOwner, ol.Disabled, ValueError) as exc:
            print(f"refused:{type(exc).__name__}")
            return 2
        refused_delete = bool(conn.execute(
            "SELECT 1 FROM owner_leases WHERE label=? UNION SELECT 1 FROM owner_requests WHERE label=? LIMIT 1",
            (a.label, a.label)).fetchone())
    finally:
        conn.close()
    print(f"registered:{a.label}:{proj}")
    print(_rollback_line(db, a.label, refused_delete))
    return 0


if __name__ == "__main__":
    sys.exit(main())
