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
    case("plan: exit 0, reports plan:3->6", rc == 0 and "plan:3->6" in out)
    case("plan: lists v4/v5/v6 pending statement counts",
         "v4: 1 statement(s)" in out and "v5: 2 statement(s)" in out and "v6: 5 statement(s)" in out)
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
         rc == 0 and "backup:" in out and "backup_sha256:" in out and "migrated:3->6" in out and "rollback:" in out)
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
    case("apply: only v4/v5/v6 newly tracked (v1-v3 were inferred, not re-applied)",
         [r[0] for r in version_rows] == [4, 5, 6])
    case("apply: v6 backfills project/authority_mode/decision_ref/reason for the pre-existing lease",
         post_conn.execute("SELECT project, authority_mode, decision_ref, reason, expires_at FROM owner_leases "
                           "WHERE lease_id='L1'").fetchone() == ("tntpgh/knowledge-base", "timed", "", "", pre_leases[0][7]))
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
    case("rerun: plan mode reports current:6", rc_plan == 0 and out_plan == "current:6")
    case("rerun: --apply on an already-current store reports current:6, no new backup, nothing written",
         rc_apply == 0 and out_apply == "current:6" and backup_files(base) == backups and before3 == after3)

    # --- a genuinely fresh (already v6) store: plan/apply both report current ---
    base2 = Path(os.path.realpath(tempfile.mkdtemp()))
    db2 = base2 / "fresh.sqlite3"
    fconn = ol.connect(str(db2))
    ol.migrate(fconn)
    fconn.close()
    os.chmod(db2, 0o600)
    rc, out = run(db2, apply=False)
    case("fresh v6 store: plan mode reports current:6, no backup", rc == 0 and out == "current:6" and backup_files(base2) == [])

    # --- v5 -> v6 preservation: every project/lease/request/event row and FK survive ---
    base3 = Path(os.path.realpath(tempfile.mkdtemp()))
    db3 = base3 / "v5.sqlite3"
    v5 = sqlite3.connect(str(db3), isolation_level=None)
    for v in (1, 2, 3, 4, 5):
        for stmt in ol.MIGRATIONS[v]:
            v5.execute(stmt)
    v5.execute("CREATE TABLE owner_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
    for v in (1, 2, 3, 4, 5):
        v5.execute("INSERT INTO owner_schema_version VALUES (?, '2026-11-01T00:00:00.000000Z')", (v,))
    v5.execute("INSERT INTO owner_projects VALUES ('kb','tntpgh/knowledge-base','2026-11-01T00:00:00.000000Z',5,NULL,NULL,NULL)")
    v5.execute("INSERT INTO owner_leases VALUES ('L5','kb','w1:p1','term_1',1,'2026-11-01T00:00:00.000000Z',"
              "'2026-11-01T00:00:00.000000Z','2099-01-01T00:00:00.000000Z',NULL,NULL,?)", ("a" * 64,))
    v5.execute("INSERT INTO owner_requests VALUES ('r5','kb',1,'queued','2026-11-01T00:00:00.000000Z','2026-11-01T00:00:00.000000Z','')")
    v5.execute("INSERT INTO owner_events (at,label,kind,ref,generation) VALUES ('2026-11-01T00:00:00.000000Z','kb','acquired','L5',1)")
    v5.close()
    os.chmod(db3, 0o600)
    pre3 = sqlite3.connect(str(db3))
    pre_proj3 = pre3.execute("SELECT * FROM owner_projects ORDER BY label").fetchall()
    pre_req3 = pre3.execute("SELECT * FROM owner_requests ORDER BY request_id").fetchall()
    pre_ev3 = pre3.execute("SELECT * FROM owner_events ORDER BY seq").fetchall()
    pre_lease_cols3 = pre3.execute("SELECT lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,"
                                   "expires_at,released_at,release_reason,session_digest FROM owner_leases").fetchall()
    pre3.close()
    rc3, out3 = run(db3, apply=True, env_extra={"HERDR_OWNER_LEASE_WRITER": "1"})
    case("v5->v6: apply migrates and reports it", rc3 == 0 and "migrated:5->6" in out3)
    post3 = sqlite3.connect(str(db3))
    case("v5->v6: every project/request/event row preserved verbatim",
         post3.execute("SELECT * FROM owner_projects ORDER BY label").fetchall() == pre_proj3
         and post3.execute("SELECT * FROM owner_requests ORDER BY request_id").fetchall() == pre_req3
         and post3.execute("SELECT * FROM owner_events ORDER BY seq").fetchall() == pre_ev3)
    case("v5->v6: every pre-existing lease column preserved verbatim",
         post3.execute("SELECT lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,expires_at,"
                       "released_at,release_reason,session_digest FROM owner_leases").fetchall() == pre_lease_cols3)
    case("v5->v6: project backfilled from owner_projects, new row carries authority_mode='timed'",
         post3.execute("SELECT project, authority_mode, decision_ref, reason FROM owner_leases "
                       "WHERE lease_id='L5'").fetchone() == ("tntpgh/knowledge-base", "timed", "", ""))
    post3.execute("PRAGMA foreign_keys=ON")
    case("v5->v6: the owner_requests (label,generation) FK onto owner_leases still holds and is clean",
         post3.execute("PRAGMA foreign_key_check").fetchall() == []
         and _raises(lambda: post3.execute("INSERT INTO owner_requests VALUES ('rx','kb',99,'queued','t','t','')"),
                     sqlite3.IntegrityError))
    post3.close()

    # --- L1: a lease whose label has no owner_projects row must never be silently dropped ---
    base4 = Path(os.path.realpath(tempfile.mkdtemp()))
    db4 = base4 / "orphan.sqlite3"
    v5o = sqlite3.connect(str(db4), isolation_level=None)
    for v in (1, 2, 3, 4, 5):
        for stmt in ol.MIGRATIONS[v]:
            v5o.execute(stmt)
    v5o.execute("CREATE TABLE owner_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
    for v in (1, 2, 3, 4, 5):
        v5o.execute("INSERT INTO owner_schema_version VALUES (?, '2026-11-01T00:00:00.000000Z')", (v,))
    v5o.execute("INSERT INTO owner_projects VALUES ('kb','tntpgh/knowledge-base','2026-11-01T00:00:00.000000Z',5,NULL,NULL,NULL)")
    for lid, lab in (("L1", "kb"), ("LG", "ghost")):   # FKs are off on this connection: 'ghost' has no project row
        v5o.execute("INSERT INTO owner_leases VALUES (?,?,'w1:p1','term_1',1,'2026-11-01T00:00:00.000000Z',"
                    "'2026-11-01T00:00:00.000000Z','2099-01-01T00:00:00.000000Z',NULL,NULL,?)", (lid, lab, "a" * 64))
    v5o.close()
    os.chmod(db4, 0o600)
    rc4, out4 = run(db4, apply=True, env_extra={"HERDR_OWNER_LEASE_WRITER": "1"})
    chk = sqlite3.connect(str(db4))
    case("L1: v5->v6 with an orphan-label lease fails loudly instead of silently dropping it",
         rc4 != 0 and "migrated:5->6" not in out4)
    case("L1: the failed migration rolled back fully: both leases kept, still v5, no half-built v6 table",
         chk.execute("SELECT COUNT(*) FROM owner_leases").fetchone()[0] == 2
         and chk.execute("SELECT MAX(version) FROM owner_schema_version").fetchone()[0] == 5
         and chk.execute("SELECT 1 FROM sqlite_master WHERE name='owner_leases_v6'").fetchone() is None)
    chk.close()

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
