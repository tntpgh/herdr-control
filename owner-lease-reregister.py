#!/usr/bin/env python3
"""owner-lease-reregister.py --label L --project P --token OLD_TOKEN
--new-token NEW_TOKEN --lifecycle-end END [--apply] — r15/F2's explicit,
authorized recovery path for a label owner-lease-unregister.py has already
turned off.

register_owner() (owner-register.py) REFUSES (AlreadyUnregistered) on a
label that is already registered-but-unregistered, rather than silently
clearing unregistered_at and resuming as if nothing had happened — this is
the ONLY way to clear it. There is no implicit/automatic path: every
restore here is deliberate and carries fresh authorization.

Authorization: --token must exactly match (hmac.compare_digest) the row's
CURRENT unregister_token — unregister_owner() never clears it, only
unregistered_at, so the original approval credential is exactly what
proves the caller may restore the label. --project must match the row's
canonical project exactly; this restores the existing label, it never
re-points it at a different project.

--new-token and --lifecycle-end are REQUIRED and NEVER inherit the old
values: the restored row gets a brand-new unregister_token (the old one is
discarded the instant this succeeds — anyone who only knew the old token
can no longer unregister it again) and a brand-new absolute
lifecycle_end_at, both supplied at THIS approval, same posture as a first
registration. Never creates or revives a lease: this is a owner_projects-
row-only update; leases still come only from the normal acquire()/
claim_*() path.

Dry-run by default; --apply required to act. Refuses (exit 2) if the
label isn't registered at all, if the project doesn't match, if the token
doesn't match, or if the label isn't currently unregistered (nothing to
restore — not an error, just nothing to do, reported as such).

Exit: 0 reregistered (or would, or not_unregistered -- nothing to do);
2 refused (typed reason, or race_lost -- r16/F3: a concurrent
reregister_owner() already committed a DIFFERENT token/bound in the
window between this call's authorization read and its own write; this
call's own UPDATE is conditional on the EXACT pair it read, so it writes
nothing and never silently overwrites the winner); 4 config.
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
    ap.add_argument("--project", required=True)
    ap.add_argument("--token", required=True, help="the label's CURRENT unregister_token (the old one)")
    ap.add_argument("--new-token", required=True, dest="new_token")
    ap.add_argument("--lifecycle-end", required=True, type=float, dest="lifecycle_end",
                    help="ABSOLUTE epoch seconds; must be in the future")
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
                      f"would_reregister cannot be confirmed until migrated")
                return 0
            result = ol.reregister_owner(conn, a.label, a.project, a.token, a.new_token, a.lifecycle_end,
                                         now=time.time(), dry_run=True)
        except ol.InvalidOwner as exc:
            print(f"refused:owner_project_mismatch:{exc}")
            return 2
        except ol.Unauthorized as exc:
            print(f"refused:unauthorized:{exc}")
            return 2
        except ValueError as exc:
            print(f"refused:invalid_input:{exc}")
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
        result = ol.reregister_owner(conn, a.label, a.project, a.token, a.new_token, a.lifecycle_end,
                                     now=time.time(), dry_run=False)
    except ol.InvalidOwner as exc:
        print(f"refused:owner_project_mismatch:{exc}")
        return 2
    except ol.Unauthorized as exc:
        print(f"refused:unauthorized:{exc}")
        return 2
    except ValueError as exc:
        print(f"refused:invalid_input:{exc}")
        return 2
    finally:
        conn.close()
    print(f"apply:{result}:{a.label}")
    if result == "race_lost":
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
