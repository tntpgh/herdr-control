#!/usr/bin/env python3
"""verify-owner-lease-migrate.py — offline synthetic proofs for
owner-lease-migrate.py (R17b's one explicit, auditable schema-migration CLI).

Real subprocess, real temp SQLite files under tempfile.mkdtemp() -- no live
hub, registry, panes, or the real lease store.

  python3 verify-owner-lease-migrate.py
"""
from __future__ import annotations

import glob
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_lease as ol  # noqa: E402
import owner_lease_renew as olr  # noqa: E402

CLI = HERE / "owner-lease-migrate.py"
FAILS: list[str] = []


def case(name, cond) -> None:
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def pretracking_db(base: Path) -> Path:
    """The R17 live-defect shape: v1+v2+v3 MIGRATIONS applied directly, no
    owner_schema_version table at all, two pre-existing rows."""
    path = base / "lease.sqlite3"
    d = sqlite3.connect(str(path), isolation_level=None)
    for v in (1, 2, 3):
        for stmt in ol.MIGRATIONS[v]:
            d.execute(stmt)
    d.execute("INSERT INTO owner_projects VALUES ('kb','tntpgh/knowledge-base','2026-10-01T00:00:00.000000Z',5)")
    d.execute("INSERT INTO owner_projects VALUES ('tos','tntpgh/thurber-os','2026-10-01T00:00:00.000000Z',5)")
    d.execute("INSERT INTO owner_leases VALUES "
              "('L1','kb','w1:p1','term_kb',1,'2026-10-01T00:00:00.000000Z','2026-10-01T00:00:00.000000Z',"
              "'2099-01-01T00:00:00.000000Z',NULL,NULL,'')")
    d.close()
    os.chmod(path, 0o600)
    return path


def run(db: Path, apply: bool, env_extra=None) -> tuple[int, str]:
    env = dict(os.environ)
    env.pop("HERDR_OWNER_LEASE_WRITER", None)
    if env_extra:
        env.update(env_extra)
    argv = [sys.executable, str(CLI), "--db", str(db)]
    if apply:
        argv.append("--apply")
    r = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=30)
    return r.returncode, (r.stdout + r.stderr).strip()


def snapshot(db: Path) -> tuple[float, bytes]:
    return os.stat(db).st_mtime, db.read_bytes()


def backup_files(base: Path) -> list[str]:
    return sorted(glob.glob(str(base / "lease.sqlite3.pre-migrate-*")))


def main() -> int:
    # --- plan mode on a pre-tracking v3 store: unchanged, reports the plan ---
    base = Path(os.path.realpath(tempfile.mkdtemp()))
    db = pretracking_db(base)
    before = snapshot(db)
    rc, out = run(db, apply=False)
    after = snapshot(db)
    case("plan: exit 0, reports plan:3->5", rc == 0 and "plan:3->5" in out)
    case("plan: lists v4/v5 pending statement counts", "v4: 1 statement(s)" in out and "v5: 2 statement(s)" in out)
    case("plan: file bytes AND mtime unchanged (truly read-only)", before == after)
    case("plan: no backup file created", backup_files(base) == [])

    # --- writer refusal: --apply with no WRITER flag refuses before any write ---
    before2 = snapshot(db)
    rc, out = run(db, apply=True, env_extra={})  # WRITER flag stripped by run()
    after2 = snapshot(db)
    case("apply without HERDR_OWNER_LEASE_WRITER: refused:flags_off, nothing written",
         rc == 4 and "refused:flags_off" in out and before2 == after2 and backup_files(base) == [])

    # --- the real --apply: backs up first, migrates v3->v5, preserves rows ---
    pre_conn = sqlite3.connect(str(db))
    pre_projects = pre_conn.execute("SELECT label,project,registered_at,max_open FROM owner_projects ORDER BY label").fetchall()
    pre_leases = pre_conn.execute("SELECT lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,"
                                  "expires_at,released_at,release_reason,session_digest FROM owner_leases "
                                  "ORDER BY lease_id").fetchall()
    pre_conn.close()

    rc, out = run(db, apply=True, env_extra={"HERDR_OWNER_LEASE_WRITER": "1"})
    case("apply: exit 0, reports backup/backup_sha256/migrated/rollback",
         rc == 0 and "backup:" in out and "backup_sha256:" in out and "migrated:3->5" in out and "rollback:" in out)
    backups = backup_files(base)
    case("apply: exactly one backup file created", len(backups) == 1)

    post_conn = sqlite3.connect(str(db))
    post_projects = post_conn.execute("SELECT label,project,registered_at,max_open,unregistered_at,"
                                      "lifecycle_end_at,unregister_token FROM owner_projects ORDER BY label").fetchall()
    post_leases = post_conn.execute("SELECT lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,"
                                    "expires_at,released_at,release_reason,session_digest FROM owner_leases "
                                    "ORDER BY lease_id").fetchall()
    version_rows = post_conn.execute("SELECT version FROM owner_schema_version ORDER BY version").fetchall()
    case("apply: rows byte-preserved (project/registered_at/max_open unchanged, new cols NULL)",
         [r[:4] for r in post_projects] == pre_projects
         and all(r[4:] == (None, None, None) for r in post_projects)
         and post_leases == pre_leases)
    case("apply: only v4/v5 newly tracked (v1-v3 were inferred, not re-applied)",
         [r[0] for r in version_rows] == [4, 5])
    case("apply: NULL lifecycle bound stays fail-closed -- renew_due refuses no_lifecycle_bound",
         olr.renew_due(post_conn, "kb", ("w1:p1", "term_kb", ""), now=time.time()) == "no_lifecycle_bound")
    case("apply: NULL unregister_token stays fail-closed -- unregister_owner raises Unauthorized",
         _raises(lambda: ol.unregister_owner(post_conn, "kb", "any-token", now=time.time(), dry_run=False),
                 ol.Unauthorized))
    post_conn.close()

    # --- backup is restorable: content-identical to the pre-migration state ---
    restored = base / "restored.sqlite3"
    shutil.copy(backups[0], restored)
    rconn = sqlite3.connect(str(restored))
    r_projects = rconn.execute("SELECT label,project,registered_at,max_open FROM owner_projects ORDER BY label").fetchall()
    r_leases = rconn.execute("SELECT lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,"
                             "expires_at,released_at,release_reason,session_digest FROM owner_leases "
                             "ORDER BY lease_id").fetchall()
    r_has_v4_cols = {row[1] for row in rconn.execute("PRAGMA table_info(owner_projects)").fetchall()}
    rconn.close()
    case("backup restorable: pre-migration rows recovered exactly, schema still v3-shaped",
         r_projects == pre_projects and r_leases == pre_leases and "unregistered_at" not in r_has_v4_cols)

    # --- idempotent rerun: already-current, no new backup, no error ---
    before3 = snapshot(db)
    rc_plan, out_plan = run(db, apply=False)
    rc_apply, out_apply = run(db, apply=True, env_extra={"HERDR_OWNER_LEASE_WRITER": "1"})
    after3 = snapshot(db)
    case("rerun: plan mode reports current:5", rc_plan == 0 and out_plan == "current:5")
    case("rerun: --apply on an already-current store reports current:5, no new backup, nothing written",
         rc_apply == 0 and out_apply == "current:5" and backup_files(base) == backups and before3 == after3)

    # --- a genuinely fresh (already v5) store: plan/apply both report current ---
    base2 = Path(os.path.realpath(tempfile.mkdtemp()))
    db2 = base2 / "fresh.sqlite3"
    fconn = ol.connect(str(db2))
    ol.migrate(fconn)
    fconn.close()
    os.chmod(db2, 0o600)
    rc, out = run(db2, apply=False)
    case("fresh v5 store: plan mode reports current:5, no backup", rc == 0 and out == "current:5" and backup_files(base2) == [])

    print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing")
    return 1 if FAILS else 0


def _raises(fn, exc) -> bool:
    try:
        fn()
    except exc:
        return True
    return False


if __name__ == "__main__":
    sys.exit(main())
