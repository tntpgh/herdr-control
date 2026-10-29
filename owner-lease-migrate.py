#!/usr/bin/env python3
"""owner-lease-migrate.py --db PATH [--apply] — R17b's explicit migration
CLI: the ONLY way an owner_lease store's schema now advances. No writer CLI
in this tree (owner-register.py, owner-dispatch-issue.py, owner-dispatch.py,
owner-lease-claim.py, owner-lease-reregister.py, owner-lease-resume.py,
owner-lease-unregister.py, queue-supervisor.py) migrates implicitly anymore
-- each refuses `schema_migration_required:<cur>-><target>` and names this
command instead (lib/owner_lease.py's open_rw_checked()). R17's
open_and_migrate(), which migrated on EVERY open including a --dry-run
call, was rejected on review (REVIEW-r17): "zero business-row writes" is
not the same promise as read-only.

Schema version = owner_schema_version MAX(version) (lib/owner_lease.py's
current_version(), which also infers the right starting point for a store
whose tables predate that tracking table entirely -- R17's own live
defect). Never PRAGMA user_version; this codebase never touches it.

Default (no --apply): READ-ONLY plan. Opens via sqlite mode=ro (same as
owner-lease-reap.py), reports current/target version and which versions are
pending with their statement counts. Exit 0 always -- an already-current
store reports `current:<v>`, not an error. NEVER writes.

--apply: requires HERDR_OWNER_LEASE_WRITER=1 (same posture as every other
writer CLI in this tree). If already current: prints `current:<v>`, exits 0,
takes no backup (nothing to roll back, nothing to migrate) -- idempotent.
Otherwise backs up the live file FIRST via sqlite3's own backup API (never
a plain file copy, which can race a WAL checkpoint mid-copy and capture a
torn file); prints the backup path and its sha256; then runs
owner_lease.migrate() on the real connection, in the one atomic transaction
migrate() already provides (FK/integrity-checked, rolls back whole on any
failure). Prints the exact rollback command (restore the backup over the
live path) whether or not anything errors, so an operator always has the
instruction in hand before trusting the result.

Exit: 0 plan/current/migrated; 4 refused (typed reason); 3 error_<Type>
during --apply (backup may or may not have completed -- see the printed
rollback line and backup_sha256 before trusting anything).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sqlite3
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import owner_lease as ol  # noqa: E402
import private_sqlite  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)

    try:
        probe = ol.open_ro(a.db, require_table="owner_projects")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    try:
        cur, target = ol.schema_status(probe)
    finally:
        probe.close()

    if cur >= target:
        print(f"current:{cur}")
        return 0

    print(f"plan:{cur}->{target}")
    for v in sorted(ol.MIGRATIONS):
        if v > cur:
            print(f"  v{v}: {len(ol.MIGRATIONS[v])} statement(s)")

    if not a.apply:
        print("dry-run: nothing written (pass --apply to migrate)")
        return 0

    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1":
        print("refused:flags_off")
        return 4

    os.umask(0o077)
    backup_path = f"{a.db}.pre-migrate-{cur}to{target}-{int(time.time())}.sqlite3"
    try:
        src = private_sqlite.open_private(a.db, ol.connect, require_table="owner_projects")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    try:
        # sqlite3's own backup API: a consistent snapshot even against a live
        # WAL-mode writer, unlike a plain file copy (which can capture a
        # torn file mid-checkpoint).
        dst = sqlite3.connect(backup_path)
        try:
            src.backup(dst)
        finally:
            dst.close()
        os.chmod(backup_path, 0o600)
        backup_sha = hashlib.sha256(Path(backup_path).read_bytes()).hexdigest()
        print(f"backup:{backup_path}")
        print(f"backup_sha256:{backup_sha}")

        new_version = ol.migrate(src)
        print(f"migrated:{cur}->{new_version}")
        print(f"rollback: cp {backup_path} {a.db}   # restores the pre-migration database (same rows/schema; "
              "the sqlite backup API rewrites pages through the engine, so this is content-identical to the "
              "original, not necessarily a byte-for-byte file copy)")
        return 0
    except BaseException as exc:
        print(f"error:{type(exc).__name__}:{exc}")
        print(f"rollback: cp {backup_path} {a.db}   # restores the pre-migration database if the backup line "
              "above printed (content-identical to the original; see the --apply success path's own note)")
        return 3
    finally:
        src.close()


if __name__ == "__main__":
    sys.exit(main())
