#!/usr/bin/env python3
"""owner-lease-unregister.py --label L --token T [--generation N --pane-id P
--pane-birth B] [--apply] — supported per-label rollback CLI around
lib/owner_lease.unregister_owner() (R12/R13-BOUNDS.md).

Refuses unless HERDR_OWNER_LEASE_WRITER=1 and HERDR_OWNER_LEASE_DB names an
EXISTING, already-migrated DB (owner_projects table present; this script
never creates or migrates the DB — same posture as owner-register.py and
owner-lease-claim.py).

Authorization (R13-BOUNDS.md), checked first: --token must exactly match
the unregister_token recorded on the label at register_owner() time. A
label registered with no token can never be unregistered through this
script (fail closed, no fallback, no --force). If the label currently has
a LIVE lease, --generation/--pane-id/--pane-birth must additionally match
it exactly, proving the caller knows that exact live state before it is
torn down; with no live lease there is nothing to fence against and the
token alone is the authorization.

Dry-run by default: every refusal check still runs (InvalidOwner,
Unauthorized, OpenRequests), only the final mutation is skipped — a
dry-run of a refused call reports the SAME refusal a real run would, never
a fake preview. --apply performs the mutation: releases the label's
current live lease (if any) and sets owner_projects.unregistered_at
(schema v4/v5). After this, DeliveryGate.registered()
(lib/owner_lease_delivery.py) sees the label as never-registered again,
and it returns to the per-label gate's legacy delivery path
(remote-mcp/publisher.py sites 1/2) — RA (site 3) simply never reaches a
registered label here either way.

Refuses (exit 2, nothing changed) while any OPEN owner_requests exist for
the label, in any generation — unregistering must never make a
still-unresolved delivery/reply silently unreachable. No --force: let those
requests resolve (reply/evidence/timeout) or resolve them by hand first;
this script never cancels a request itself.

Idempotent: already-unregistered prints that and exits 0 in both dry-run
and --apply (only reached AFTER the token check -- a wrong token learns
nothing, not even whether the label is already unregistered).

Never DELETEs the owner_projects row (unregister_owner() never attempts
one). Never called from any other script or tick in this tree — this is
the ONLY production caller of lib/owner_lease.unregister_owner()
(R13-BOUNDS.md: no code path auto-unregisters, ever).

Exit: 0 unregistered (or already, or dry-run); 2 refused (typed reason);
4 config.
Rollback of THIS script: none needed — it only ever marks a label
unregistered or releases its lease, both already-supported, auditable
owner_lease.py writes (owner_events rows); there is no unregister-the-
unregister. Recovery is NEVER a plain re-run of owner-register.py --
register_owner() REFUSES (AlreadyUnregistered, r15/F2) on an already-
unregistered (label, project) row rather than silently clearing it and
resuming as if nothing had happened. The real recovery path is
owner-lease-reregister.py: dry-run by default, requires the label's
CURRENT unregister_token as authorization (the same one set here or at
the original registration), and issues a brand-new token + absolute
lifecycle_end at that approval -- never inherits the old ones.
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import owner_lease as ol  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--token", required=True)
    ap.add_argument("--generation", type=int, default=0)
    ap.add_argument("--pane-id", default="")
    ap.add_argument("--pane-birth", default="")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)
    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1":
        print("refused:flags_off")
        return 4
    db = os.environ.get("HERDR_OWNER_LEASE_DB", "")

    if not a.apply:
        # R17b: dry-run opens read-only, never migrates.
        try:
            conn = ol.open_ro(db, require_table="owner_projects")
        except ValueError as exc:
            print(f"refused:{exc}")
            return 4
        try:
            cur, target = ol.schema_status(conn)
            if cur < target:
                print(f"schema_pending:{cur}->{target} (owner-lease-migrate.py --db {db} --apply) -- "
                      f"would_unregister cannot be confirmed until migrated")
                return 0
            result = ol.unregister_owner(conn, a.label, a.token, generation=a.generation, pane_id=a.pane_id,
                                         pane_birth=a.pane_birth, now=time.time(), dry_run=True)
        except ol.InvalidOwner as exc:
            print(f"refused:owner_project_unmapped:{exc}")
            return 2
        except ol.Unauthorized as exc:
            print(f"refused:unauthorized:{exc}")
            return 2
        except ol.OpenRequests as exc:
            print(f"refused:open_requests:{exc}")
            return 2
        finally:
            conn.close()
        print(f"dry-run:{result}:{a.label}")
        return 0

    # R17b: --apply never migrates implicitly either.
    try:
        conn = ol.open_rw_checked(db, require_table="owner_projects")
    except ValueError as exc:
        print(f"refused:{exc}")
        return 4
    except ol.SchemaMigrationRequired as exc:
        print(f"refused:schema_migration_required:{exc.cur}->{exc.target}:owner-lease-migrate.py --db {db} --apply")
        return 4
    try:
        result = ol.unregister_owner(conn, a.label, a.token, generation=a.generation, pane_id=a.pane_id,
                                     pane_birth=a.pane_birth, now=time.time(), dry_run=False)
    except ol.InvalidOwner as exc:
        print(f"refused:owner_project_unmapped:{exc}")
        return 2
    except ol.Unauthorized as exc:
        print(f"refused:unauthorized:{exc}")
        return 2
    except ol.OpenRequests as exc:
        print(f"refused:open_requests:{exc}")
        return 2
    finally:
        conn.close()
    print(f"apply:{result}:{a.label}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
