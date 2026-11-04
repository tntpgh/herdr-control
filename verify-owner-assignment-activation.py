#!/usr/bin/env python3
"""verify-owner-assignment-activation.py — Plan 018 PR B proofs: durable owner
assignments are operational end to end.

Part 1  owner-assignment-activate.py (REAL subprocess) against a temporary copy
        of a live-like v5 store: dry-run, flag gates, drift refusal, backup +
        migration + exact in-place conversion, idempotence, rollback.
Part 2  one live-like lifecycle through every owner consumer: migrate -> exact
        assignment -> reopen -> dispatch / result submit / accept -> time far
        beyond the TTL -> still works -> revoke fences every path -> audited
        replacement restores ONLY the new holder.
Part 3  per-consumer assignment behaviour + timed-mode compatibility.

Disposable temp state only; no live store, registry, pane or network.

  python3 verify-owner-assignment-activation.py
"""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_dispatch as od  # noqa: E402
import owner_dispatch_auth as oda  # noqa: E402
import owner_lease as ol  # noqa: E402
import owner_lease_delivery as old  # noqa: E402


def load(name: str, rel: str):
    spec = importlib.util.spec_from_file_location(name, HERE / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


vod = load("vod_fixtures", "verify-owner-dispatch.py")   # env(), acquire(), insert_grant(), Sender, PANE, SESS ...
KB, T0, TTL, PANE, SESS = vod.KB, vod.T0, vod.TTL, vod.PANE, vod.SESS
CLI = HERE / "owner-assignment-activate.py"
FAILS: list[str] = []


def case(name, cond) -> None:
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def raises(fn, exc) -> bool:
    try:
        fn()
    except exc:
        return True
    return False


def tmpdir() -> Path:
    return Path(os.path.realpath(tempfile.mkdtemp()))


# ---------------------------------------------------------------- Part 1: activation CLI

def digest(label: str, session: str) -> str:
    return hashlib.sha256(f"{label}:{session}".encode()).hexdigest()


def make_registry(path: Path, rows: dict) -> None:
    c = sqlite3.connect(str(path))
    c.execute("DROP TABLE IF EXISTS owners")
    c.execute("CREATE TABLE owners (label TEXT PRIMARY KEY, pane_id TEXT, pane_birth TEXT, agent_session TEXT,"
              " workspace TEXT, registered_at TEXT, updated_at TEXT)")
    for label, (pane, birth, sess) in rows.items():
        c.execute("INSERT INTO owners VALUES (?,?,?,?,?,?,?)", (label, pane, birth, sess, "ws", "t", "t"))
    c.commit()
    c.close()


def live_like_v5(base: Path, now: float) -> Path:
    """A v5 store shaped like the live one: kb + tos hold live timed leases, `old` an unreleased
    EXPIRED one, kb has an open request. Built from the real MIGRATIONS 1..5."""
    path = base / "lease.sqlite3"
    d = sqlite3.connect(str(path), isolation_level=None)
    for v in (1, 2, 3, 4, 5):
        for stmt in ol.MIGRATIONS[v]:
            d.execute(stmt)
    d.execute("CREATE TABLE owner_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
    for v in (1, 2, 3, 4, 5):
        d.execute("INSERT INTO owner_schema_version VALUES (?, '2026-11-01T00:00:00.000000Z')", (v,))
    reg_at = ol._iso(now - 86400)
    live_exp, dead_exp = ol._iso(now + 3600), ol._iso(now - 600)
    for label, proj in (("kb", "tntpgh/knowledge-base"), ("tos", "tntpgh/thurber-os"), ("old", "tntpgh/old-project")):
        d.execute("INSERT INTO owner_projects VALUES (?,?,?,5,NULL,NULL,NULL)", (label, proj, reg_at))
    for lid, label, pane, birth, exp in (("Lkb", "kb", "w1:p1", "term_kb", live_exp), ("Ltos", "tos", "w2:p1", "term_tos", live_exp),
                                          ("Lold", "old", "w3:p1", "term_old", dead_exp)):
        d.execute("INSERT INTO owner_leases VALUES (?,?,?,?,1,?,?,?,NULL,NULL,?)",
                  (lid, label, pane, birth, reg_at, reg_at, exp, digest(label, "sess-" + label)))
    d.execute("INSERT INTO owner_requests VALUES ('r5','kb',1,'queued',?,?,'')", (reg_at, reg_at))
    d.close()
    os.chmod(path, 0o600)
    return path


def reg_rows(**over) -> dict:
    rows = {"kb": ("w1:p1", "term_kb", "sess-kb"), "tos": ("w2:p1", "term_tos", "sess-tos"),
            "old": ("w3:p1", "term_old", "sess-old")}
    rows.update(over)
    return rows


def run_cli(base: Path, db: Path, *extra, flags: tuple = (), registry: Path | None = None):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(base), "HERDR_RUN_REGISTRY": str(registry)}
    for f in flags:
        env[f] = "1"
    r = subprocess.run([sys.executable, str(CLI), "--db", str(db), *extra], capture_output=True, text=True,
                       env=env, timeout=60, cwd=str(base))
    return r.returncode, (r.stdout + r.stderr).strip()


def backups(db: Path, tag: str) -> list[Path]:
    return sorted(db.parent.glob(f"{db.name}.{tag}-*"))


def rows_of(db: Path, sql: str):
    c = sqlite3.connect(str(db))
    try:
        return c.execute(sql).fetchall()
    finally:
        c.close()


def part1():
    base = tmpdir()
    now = time.time()
    db = live_like_v5(base, now)
    registry = base / "registry.sqlite3"
    make_registry(registry, reg_rows())
    W = ("HERDR_OWNER_ASSIGNMENT_WRITER", "HERDR_OWNER_LEASE_WRITER")
    EV = ("--decision-ref", "dec-activate-1", "--reason", "plan 018 activation")
    pre_bytes = db.read_bytes()

    rc, out = run_cli(base, db, *EV, registry=registry)
    case("CLI dry-run: plan for kb+tos, expired `old` skipped, schema 5->6, nothing written",
         rc == 0 and "schema:5->6" in out and "plan:convert:kb:gen=1" in out and "plan:convert:tos:gen=1" in out
         and "skip:old:gen=1 expired" in out and "dry-run" in out and db.read_bytes() == pre_bytes
         and not backups(db, "pre-assignment-activate-v5"))
    case("CLI dry-run never prints a full session digest", digest("kb", "sess-kb") not in out)
    rc, out = run_cli(base, db, *EV, "--apply", registry=registry)
    case("CLI --apply without the writer flags: refused:flags_off, exit 4, nothing written",
         rc == 4 and out.endswith("refused:flags_off") and db.read_bytes() == pre_bytes)
    rc, out = run_cli(base, db, *EV, "--apply", flags=("HERDR_OWNER_ASSIGNMENT_WRITER",), registry=registry)
    case("CLI --apply needs the lease-migration writer flag too while the schema is behind",
         rc == 4 and out.endswith("refused:flags_off") and db.read_bytes() == pre_bytes)
    rc, out = run_cli(base, db, "--apply", flags=W, registry=registry)
    case("CLI refuses without decision evidence", rc == 4 and "decision_ref_and_reason_required" in out)

    # drift: registry names a different session for tos -> whole run refused, nothing converted/backed up
    make_registry(registry, reg_rows(tos=("w2:p1", "term_tos", "sess-OTHER")))
    rc, out = run_cli(base, db, *EV, "--apply", flags=W, registry=registry)
    case("CLI drift (registry session != lease holder): refused, exit 2, NOTHING written, no backup",
         rc == 2 and "refused:drift:tos:registry_holder_mismatch" in out and "no_conversion_applied" in out
         and db.read_bytes() == pre_bytes and not backups(db, "pre-assignment-activate-v5"))
    make_registry(registry, {k: v for k, v in reg_rows().items() if k != "kb"})
    rc, out = run_cli(base, db, *EV, "--apply", flags=W, registry=registry)
    case("CLI unresolved registry label: refused, never inferred", rc == 2 and "refused:drift:kb:registry_unresolved" in out
         and db.read_bytes() == pre_bytes)
    make_registry(registry, reg_rows())
    rc, out = run_cli(base, db, *EV, "--label", "nope", "--apply", flags=W, registry=registry)
    case("CLI --label naming a label with no unreleased lease is refused", rc == 2 and "nope:no_unreleased_lease" in out
         and db.read_bytes() == pre_bytes)

    # the real apply
    rc, out = run_cli(base, db, *EV, "--apply", flags=W, registry=registry)
    bk = backups(db, "pre-assignment-activate-v5")
    case("CLI apply: exit 0, backup + sha256 + rollback line printed, migrated 5->6, kb and tos converted",
         rc == 0 and len(bk) == 1 and f"backup:{bk[0]}" in out and "backup_sha256:" in out and "rollback:" in out
         and "migrated:5->6" in out and "converted:kb:gen=1" in out and "converted:tos:gen=1" in out)
    case("backup is private (0600) and is the untouched v5 content",
         bk and (bk[0].stat().st_mode & 0o777) == 0o600
         and rows_of(bk[0], "SELECT lease_id, expires_at FROM owner_leases ORDER BY lease_id")
         == [("Lkb", ol._iso(now + 3600)), ("Lold", ol._iso(now - 600)), ("Ltos", ol._iso(now + 3600))]
         and rows_of(bk[0], "SELECT MAX(version) FROM owner_schema_version") == [(5,)])
    rows = rows_of(db, "SELECT label, generation, authority_mode, expires_at, released_at, decision_ref, reason, pane_id,"
                       " pane_birth FROM owner_leases ORDER BY label")
    case("rows: kb/tos are assignments, SAME generation + holder, no expiry, decision evidence recorded",
         rows[0] == ("kb", 1, "assignment", None, None, "dec-activate-1", "plan 018 activation", "w1:p1", "term_kb")
         and rows[2] == ("tos", 1, "assignment", None, None, "dec-activate-1", "plan 018 activation", "w2:p1", "term_tos"))
    case("expired `old` lease is NOT converted or resurrected: still timed, unreleased, expired",
         rows[1][:3] == ("old", 1, "timed") and rows[1][3] == ol._iso(now - 600) and rows[1][4] is None)
    case("the open kb request survived under the same generation (no restale)",
         rows_of(db, "SELECT request_id, generation, state FROM owner_requests") == [("r5", 1, "queued")])
    case("audit: one 'converted' event per converted label",
         rows_of(db, "SELECT label, kind, generation FROM owner_events WHERE kind='converted' ORDER BY label")
         == [("kb", "converted", 1), ("tos", "converted", 1)])

    after = db.read_bytes()
    rc, out = run_cli(base, db, *EV, "--apply", flags=W, registry=registry)
    case("IDEMPOTENT: re-apply writes nothing, takes no new backup, says nothing_to_do",
         rc == 0 and "nothing_to_do" in out and db.read_bytes() == after and len(backups(db, "pre-assignment-activate-v5")) == 1
         and "current:kb" in out)
    rc, out = run_cli(base, db, "--decision-ref", "dec-other", "--reason", "x", "--apply", flags=W, registry=registry)
    case("re-run with DIFFERENT evidence never rewrites an existing assignment",
         rc == 0 and "nothing_to_do" in out and db.read_bytes() == after)

    # rollback: bound to THIS store's backup (M1), refuses to erase post-backup revocations (H2), never re-enables (H2b)
    bsha = hashlib.sha256(bk[0].read_bytes()).hexdigest()
    rc, out = run_cli(base, db, "--rollback", str(bk[0]), registry=registry)
    case("ROLLBACK dry-run names the backup (schema v5 + sha256), warns the kill switch stays engaged, writes nothing",
         rc == 0 and "schema v5" in out and "dry-run" in out and "enabled=0" in out and db.read_bytes() == after)
    rc, out = run_cli(base, db, "--rollback", str(bk[0]), "--expect-sha256", "0" * 64, "--apply", flags=W, registry=registry)
    case("ROLLBACK with a wrong --expect-sha256 is refused", rc == 4 and "backup_sha256_mismatch" in out and db.read_bytes() == after)
    rc, out = run_cli(base, db, "--rollback", str(bk[0]), "--apply", flags=W, registry=registry)
    case("M1: ROLLBACK --apply WITHOUT --expect-sha256 is refused (digest binding required)",
         rc == 4 and "expect_sha256_required" in out and db.read_bytes() == after)
    rc, out = run_cli(base, db, "--rollback", str(bk[0]), "--expect-sha256", bsha, "--apply", registry=registry)
    case("ROLLBACK --apply without the writer flag: refused:flags_off", rc == 4 and out.endswith("refused:flags_off"))
    junk = db.parent / f"{db.name}.pre-rollback-1.sqlite3"
    jc = sqlite3.connect(str(junk))
    jc.execute("CREATE TABLE keep (x)")
    jc.commit(); jc.close()
    rc, out = run_cli(base, db, "--rollback", str(junk), "--expect-sha256", hashlib.sha256(junk.read_bytes()).hexdigest(),
                      "--apply", flags=W, registry=registry)
    case("M1: an arbitrary sqlite file that is not an owner-lease store is refused, live store untouched",
         rc == 4 and "backup_not_an_owner_lease_store" in out and db.read_bytes() == after)
    junk.unlink()
    stray = base / "stray.sqlite3"
    stray.write_bytes(bk[0].read_bytes())
    rc, out = run_cli(base, db, "--rollback", str(stray), "--expect-sha256", bsha, "--apply", flags=W, registry=registry)
    case("M1: a genuine backup under a foreign name is refused (not this store's backup)",
         rc == 4 and "backup_not_from_this_store" in out and db.read_bytes() == after)
    other = tmpdir()
    foreign = other / bk[0].name
    foreign.write_bytes(bk[0].read_bytes())
    rc, out = run_cli(base, db, "--rollback", str(foreign), "--expect-sha256", bsha, "--apply", flags=W, registry=registry)
    case("M1: a same-named backup from another directory (another store) is refused",
         rc == 4 and "backup_not_from_this_store" in out and db.read_bytes() == after)
    # L1: the snapshot name is pre-planted as a symlink -> O_EXCL refuses, victim untouched, store not restored
    victim = base / "victim.txt"
    victim.write_text("keep me")
    plant = Path(f"{db}.pre-rollback-{int(time.time())}.sqlite3")
    plant2 = Path(f"{db}.pre-rollback-{int(time.time()) + 1}.sqlite3")
    for p in (plant, plant2):
        p.symlink_to(victim)
    rc, out = run_cli(base, db, "--rollback", str(bk[0]), "--expect-sha256", bsha, "--apply", flags=W, registry=registry)
    case("L1: a pre-planted symlink at the snapshot name is never followed/overwritten (O_EXCL); store NOT restored",
         rc == 3 and "FileExistsError" in out and victim.read_text() == "keep me" and db.read_bytes() == after)
    plant.unlink(); plant2.unlink()

    # H2: a revocation made AFTER the backup must not be silently erased
    base_r = tmpdir()
    db_r = base_r / db.name
    db_r.write_bytes(after)
    os.chmod(db_r, 0o600)
    bk_r = base_r / bk[0].name
    bk_r.write_bytes(bk[0].read_bytes())
    rcn = ol.connect(str(db_r))
    ol.assign_revoke(rcn, "kb", 1, "w1:p1", "term_kb", digest("kb", "sess-kb"), "dec-rev-1", "compromised pane",
                     now + 5, dry_run=False)
    rcn.close()
    revoked_bytes = db_r.read_bytes()
    rc, out = run_cli(base_r, db_r, "--rollback", str(bk_r), registry=registry)
    case("H2: ROLLBACK dry-run lists the post-backup revocation and refuses (exit 2)",
         rc == 2 and "post_backup_authority_event:" in out and "label=kb kind=revoked" in out
         and "refused:post_backup_authority_events" in out and db_r.read_bytes() == revoked_bytes)
    rc, out = run_cli(base_r, db_r, "--rollback", str(bk_r), "--expect-sha256", bsha, "--apply", flags=W, registry=registry)
    case("H2: ROLLBACK --apply is refused too; the revoked holder is NOT re-authorized, nothing written, no snapshot",
         rc == 2 and "refused:post_backup_authority_events" in out and db_r.read_bytes() == revoked_bytes
         and not backups(db_r, "pre-rollback")
         and rows_of(db_r, "SELECT release_reason FROM owner_leases WHERE label='kb'") == [("revoked",)])
    rc, out = run_cli(base_r, db_r, "--rollback", str(bk_r), "--expect-sha256", bsha, "--ack-discard-post-backup-events",
                      "--apply", flags=W, registry=registry)
    case("H2: only with the explicit --ack-discard-post-backup-events does it restore (and the discard is reported)",
         rc == 0 and "post_backup_authority_event:" in out and "restored:" in out and len(backups(db_r, "pre-rollback")) == 1)
    case("H2b: even after an acknowledged restore the kill switch is ENGAGED (enabled=0), schema is the backup's v5",
         rows_of(db_r, "SELECT enabled FROM owner_state") == [(0,)]
         and rows_of(db_r, "SELECT MAX(version) FROM owner_schema_version") == [(5,)])

    # H2c (review D1): an owner UNREGISTERED after the backup must not be silently restored as registered/live
    base_u = tmpdir()
    db_u = base_u / db.name
    db_u.write_bytes(after)
    os.chmod(db_u, 0o600)
    bk_u = base_u / bk[0].name
    bk_u.write_bytes(bk[0].read_bytes())
    uc = ol.connect(str(db_u))
    uc.execute("UPDATE owner_projects SET unregister_token='tok-old' WHERE label='old'")
    got = ol.unregister_owner(uc, "old", "tok-old", 1, "w3:p1", "term_old", now=now + 5, dry_run=False)
    uc.close()
    unreg_bytes = db_u.read_bytes()
    case("H2c fixture: the post-backup unregistration really happened", got == "unregistered"
         and rows_of(db_u, "SELECT COUNT(*) FROM owner_events WHERE kind='unregistered'") == [(1,)]
         and rows_of(db_u, "SELECT unregistered_at IS NOT NULL FROM owner_projects WHERE label='old'") == [(1,)])
    rc, out = run_cli(base_u, db_u, "--rollback", str(bk_u), "--expect-sha256", bsha, "--apply", flags=W, registry=registry)
    case("H2c: ROLLBACK refuses a post-backup UNREGISTERED owner (would be restored registered), nothing written",
         rc == 2 and "label=old kind=unregistered" in out and "refused:post_backup_authority_events" in out
         and db_u.read_bytes() == unreg_bytes and not backups(db_u, "pre-rollback"))
    rc, out = run_cli(base_u, db_u, "--rollback", str(bk_u), "--expect-sha256", bsha, "--ack-discard-post-backup-events",
                      "--apply", flags=W, registry=registry)
    case("H2c: only with the explicit acknowledgement does it restore, kill switch still engaged",
         rc == 0 and rows_of(db_u, "SELECT enabled FROM owner_state") == [(0,)]
         and rows_of(db_u, "SELECT unregistered_at IS NULL FROM owner_projects WHERE label='old'") == [(1,)])

    # H2b: an engaged kill switch is not re-enabled by a rollback (the backup itself has enabled=1)
    live_c = sqlite3.connect(str(db))
    live_c.execute("UPDATE owner_state SET enabled=0")
    live_c.commit(); live_c.close()
    rc, out = run_cli(base, db, "--rollback", str(bk[0]), "--expect-sha256", bsha, "--apply", flags=W, registry=registry)
    snaps = backups(db, "pre-rollback")
    case("ROLLBACK --apply: pre-rollback snapshot taken, store restored to the v5 content, kill switch stays engaged",
         rc == 0 and len(snaps) == 1 and "restored:" in out and "integrity=ok" in out and "owner_state.enabled=0" in out
         and rows_of(db, "SELECT MAX(version) FROM owner_schema_version") == [(5,)]
         and rows_of(db, "SELECT enabled FROM owner_state") == [(0,)]
         and rows_of(db, "SELECT lease_id, expires_at FROM owner_leases ORDER BY lease_id")
         == [("Lkb", ol._iso(now + 3600)), ("Lold", ol._iso(now - 600)), ("Ltos", ol._iso(now + 3600))]
         and rows_of(snaps[0], "SELECT authority_mode FROM owner_leases WHERE label='kb'") == [("assignment",)]
         and (snaps[0].stat().st_mode & 0o777) == 0o600)
    rc, out = run_cli(base, db, *EV, "--apply", flags=W, registry=registry)
    case("after a rollback leasing stays OFF: activation refuses until the operator re-enables on purpose",
         rc == 2 and "owner_leasing_disabled" in out)
    en = sqlite3.connect(str(db))
    en.execute("UPDATE owner_state SET enabled=1")
    en.commit(); en.close()
    time.sleep(1.1)  # backup names carry epoch seconds and are O_EXCL: never reuse the first activation's name
    rc, out = run_cli(base, db, *EV, "--apply", flags=W, registry=registry)
    case("after the deliberate re-enable the activation can be applied again", rc == 0 and "converted:kb:gen=1" in out)

    # --label restriction + kill switch
    base2 = tmpdir()
    db2 = live_like_v5(base2, now)
    registry2 = base2 / "registry.sqlite3"
    make_registry(registry2, reg_rows())
    rc, out = run_cli(base2, db2, *EV, "--label", "kb", "--apply", flags=W, registry=registry2)
    case("--label kb converts only kb; tos stays timed",
         rc == 0 and rows_of(db2, "SELECT label, authority_mode FROM owner_leases ORDER BY label")
         == [("kb", "assignment"), ("old", "timed"), ("tos", "timed")])
    base3 = tmpdir()
    db3 = live_like_v5(base3, now)
    registry3 = base3 / "registry.sqlite3"
    make_registry(registry3, reg_rows())
    c = sqlite3.connect(str(db3))
    c.execute("UPDATE owner_state SET enabled=0")
    c.commit(); c.close()
    pre3 = db3.read_bytes()
    rc, out = run_cli(base3, db3, *EV, "--apply", flags=W, registry=registry3)
    case("kill switch (owner_state.enabled=0): refused before any backup/write, exit 2",
         rc == 2 and "owner_leasing_disabled" in out and db3.read_bytes() == pre3 and not backups(db3, "pre-assignment-activate-v5"))
    # converting an already-current v6 store with a live timed lease needs only the assignment flag
    base4 = tmpdir()
    lc, av, roots, ldb = vod.env(base4)
    now4 = time.time()
    ol.acquire(lc, KB, *PANE[KB], 3600, now4, session_digest=SESS[KB])
    lc.close(); av.close()
    os.chmod(ldb, 0o600)
    reg4 = base4 / "registry.sqlite3"
    make_registry(reg4, {})
    # registry rows carry agent_session; the digest is sha256(label:session) so craft a matching pair
    c = sqlite3.connect(str(reg4))
    c.execute("INSERT INTO owners VALUES (?,?,?,?,?,?,?)", (KB, PANE[KB][0], PANE[KB][1], "s-kb", "ws", "t", "t"))
    c.commit(); c.close()
    rc, out = run_cli(base4, Path(ldb), *EV, "--apply", flags=("HERDR_OWNER_ASSIGNMENT_WRITER",), registry=reg4)
    case("v6 store whose registry session digest differs from the lease: drift refusal (digest compared exactly)",
         rc == 2 and "registry_holder_mismatch" in out)


# ---------------------------------------------------------------- Part 2: lifecycle through every consumer

def capture(fn, *a, **k):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn(*a, **k)
    return rc, buf.getvalue().strip()


def part2():
    base = tmpdir()
    lc, av, roots, lease_db = vod.env(base)
    os.chmod(lease_db, 0o600)
    PANE2, SESS2 = ("w93:p9", "term_kb2"), hashlib.sha256(b"kb-session-2").hexdigest()
    HOLDER1 = (*PANE[KB], SESS[KB])
    HOLDER2 = (*PANE2, SESS2)
    vod.acquire(lc, KB, T0)                                                # timed gen 1, expires T0+TTL
    EXP = T0 + TTL

    # migrate -> exact assignment (assign_convert is the activation primitive)
    case("convert dry-run default writes nothing",
         ol.assign_convert(lc, KB, 1, *HOLDER1, "dec-c1", "cutover", T0 + 10) == "would_convert"
         and ol.current_assignment(lc, KB)["authority_mode"] == "timed")
    stale = [("generation", dict(expected_generation=2)), ("pane", dict(pane_id="w9:p9")),
             ("birth", dict(pane_birth="term_zz")), ("session", dict(session_digest="a" * 64))]
    ok = True
    for what, over in stale:
        args = dict(expected_generation=1, pane_id=PANE[KB][0], pane_birth=PANE[KB][1], session_digest=SESS[KB])
        args.update(over)
        ok &= raises(lambda: ol.assign_convert(lc, KB, args["expected_generation"], args["pane_id"], args["pane_birth"],
                                               args["session_digest"], "dec-c1", "cutover", T0 + 10, dry_run=False),
                     ol.ConvertRefused)
    case("convert: stale generation / pane / birth / session each refused (ConvertRefused), nothing written",
         ok and ol.current_assignment(lc, KB)["authority_mode"] == "timed")
    case("convert refuses an EXPIRED timed lease (no resurrection)",
         raises(lambda: ol.assign_convert(lc, KB, 1, *HOLDER1, "dec-c1", "cutover", EXP + 1, dry_run=False), ol.ConvertRefused))
    case("convert needs decision evidence", raises(lambda: ol.assign_convert(lc, KB, 1, *HOLDER1, "", "r", T0, dry_run=False), ValueError))
    case("convert: exact holder -> same generation 1",
         ol.assign_convert(lc, KB, 1, *HOLDER1, "dec-c1", "cutover", T0 + 10, dry_run=False) == 1)
    row = ol.current_assignment(lc, KB)
    case("converted row: assignment, NULL expiry, same lease_id/generation, evidence stored, 'converted' event",
         (row["authority_mode"], row["expires_at"], row["generation"], row["decision_ref"]) == ("assignment", None, 1, "dec-c1")
         and lc.execute("SELECT kind, generation FROM owner_events WHERE kind='converted'").fetchall() == [("converted", 1)])
    case("convert is idempotent for the same evidence and refuses different evidence",
         ol.assign_convert(lc, KB, 1, *HOLDER1, "dec-c1", "cutover", T0 + 11, dry_run=False) == 1
         and raises(lambda: ol.assign_convert(lc, KB, 1, *HOLDER1, "dec-c2", "other", T0 + 11, dry_run=False), ol.ConvertRefused))
    case("legacy acquire cannot take over the converted label", raises(
        lambda: ol.acquire(lc, KB, *PANE2, TTL, T0 + 20, session_digest=SESS2), ol.LeaseConflict))

    # restart: drop every connection and reopen from the file
    lc.close(); av.close()
    lc = ol.connect(lease_db)
    av = vod.ra.Availability(str(base / "ra.db"), {k: str(v) for k, v in roots.items()}, str(base / "journal"))
    gate = old.DeliveryGate(lease_db)
    store = sqlite3.connect(str(base / "auth.db"), isolation_level=None)
    oda.migrate(store)
    proj = lc.execute("SELECT project FROM owner_projects WHERE label=?", (KB,)).fetchone()[0]
    sent = []
    seq = [0]

    def dispatch(rid, holder, resolve_to, now):
        """one real Dispatcher pass with its own one-time grant bound to `holder`"""
        seq[0] += 1
        aid = f"a{seq[0]}"
        body = f"REQ {rid}\n".encode()
        vod.insert_grant(store, aid, label=KB, project=proj, holder=holder, rid=rid, sha=hashlib.sha256(body).hexdigest(),
                         manifest=["result.md"], expires=now + 3600)
        authorize = lambda l, pj, hd, r, h, m, n: oda.consume(store, aid, label=l, project=pj, holder=hd, request_id=r,  # noqa: E731
                                                              body_sha256=h, manifest=m, now=n)
        d = od.Dispatcher(gate, av, lambda l, h, t: sent.append((rid, h)) or True, {KB: resolve_to}.get,
                          lambda: now, authorize=authorize)
        res = d.dispatch(KB, rid, body, ["result.md"], now)
        status = store.execute("SELECT status FROM owner_dispatch_auth WHERE auth_id=?", (aid,)).fetchone()[0]
        return res, status

    T1 = T0 + 5 * 86400                                                   # 5 days past a 1h TTL
    res, status = dispatch("r1", (*HOLDER1, 1), HOLDER1, T1)
    case("DISPATCH after reopen, 5 days past the original TTL: dispatched, grant consumed, request delivering under gen 1",
         res == "dispatched" and status == "consumed" and gate.state("r1") == "delivering" and sent[-1][0] == "r1")

    # result submit / accept through the real CLI mains (wall-clock now: an assignment has no clock)
    sub, acc = load("submit_cli", "submit-owner-result.py"), load("accept_cli", "accept-owner-result.py")
    cfg = {"HERDR_RESULT_AVAILABILITY": "1", "HERDR_RESULT_AVAILABILITY_DB": str(base / "ra.db"),
           "HERDR_RESULT_AVAILABILITY_JOURNAL": str(base / "journal"),
           "HERDR_RESULT_AVAILABILITY_ROOTS": f"{KB}={roots[KB]}", "HERDR_OWNER_LEASE_DB": lease_db}
    (roots[KB] / "r1" / "result.md").write_text("done r1\n")
    sha1 = hashlib.sha256(b"done r1\n").hexdigest()

    reg = {KB: HOLDER1}

    def submit(rid, pane):
        return capture(sub.main, ["--rid", rid], caller_pane_resolver=lambda: pane, waker=lambda *a: "wake:skipped",
                       environ=cfg, resolve=reg.get)

    def accept(receipt, sha):
        return capture(acc.main, ["--receipt-id", receipt, "--by", "reviewer", "--pin", f"result.md={sha}"], environ=cfg,
                       resolve=reg.get)

    rc, out = submit("r1", PANE[KB][0])
    receipt1 = out.split(":")[1] if out.startswith("submitted:") else ""
    case("RESULT SUBMIT by the assigned holder pane -> receipt", rc == 0 and receipt1.startswith("recv_"))
    rc, out = submit("r1", "w1:pZ")
    case("RESULT SUBMIT from a pane that is not the holder -> refused", rc == 2 and "bindings_did_not_match" in out)

    # H1: the registry's session for the label changes (same pane id + birth, agent restarted) -> an assignment
    # holder must stop being honoured by EVERY consumer, even though the assignment itself never lapses.
    drift = (*PANE[KB], hashlib.sha256(b"restarted-agent-session").hexdigest())
    reg[KB] = drift
    rc, out = submit("r1", PANE[KB][0])
    case("H1 RESULT SUBMIT with registry session drift (same pane+birth) -> refused", rc == 2 and "bindings_did_not_match" in out)
    rc, out = accept(receipt1, sha1)
    case("H1 RESULT ACCEPT with registry session drift -> refused", rc == 2 and "bindings_did_not_match" in out)
    rc, out = capture(acc.main, ["--receipt-id", receipt1, "--by", "reviewer", "--pin", f"result.md={sha1}"], environ=cfg,
                      resolve=lambda label: None)
    case("H1 RESULT ACCEPT with an UNRESOLVED registry label -> refused (fail closed)", rc == 2 and "bindings_did_not_match" in out)
    dg = old.DeliveryGate(lease_db, resolve=reg.get)
    case("H1 DELIVERY admit with registry session drift: blocked owner_session_mismatch, nothing queued",
         dg.admit(KB, *PANE[KB], "r_drift", T1 + 1).reason == "owner_session_mismatch" and dg.state("r_drift") is None)
    case("H1 DELIVERY begin_notice with drift: owner_session_mismatch (not delivering)",
         dg.begin_notice(KB, *PANE[KB], 1, "r1", T1 + 1) == "owner_session_mismatch")
    case("H1 DELIVERY reply crediting with drift: session_mismatch, the delivering request is NOT credited",
         dg.on_reply(KB, "r1", now=T1 + 1) == "session_mismatch" and dg.state("r1") == "delivering")
    case("H1 DELIVERY record_evidence with drift: FencedOut",
         raises(lambda: dg.record_evidence(KB, "r1", "ev-x", now=T1 + 1), ol.FencedOut))
    reg[KB] = None
    case("H1 DELIVERY with an unresolved registry: admit blocked owner_session_mismatch (fail closed)",
         dg.admit(KB, *PANE[KB], "r_unres", T1 + 1).reason == "owner_session_mismatch")
    reg[KB] = HOLDER1
    case("H1 control: registry restored to the exact holder -> admit ok again",
         dg.admit(KB, *PANE[KB], "r_ok", T1 + 1).ok and dg.state("r_ok") == "queued")
    dg.close()
    rc, out = accept(receipt1, sha1)
    case("RESULT ACCEPT by an independent reviewer -> accepted", rc == 0 and out == "accepted" and "accepted" in av.stages("r1"))

    # delivery gate reply path
    case("DELIVERY on_reply at a far-future clock: replied (no NULL-expiry dereference)",
         gate.on_reply(KB, "r1", now=T0 + 400 * 86400) == "replied")
    case("DELIVERY record_evidence at a far-future clock: evidence",
         gate.record_evidence(KB, "r1", "ev-1", now=T0 + 400 * 86400) == "evidence")

    # time far beyond TTL: second dispatch + submit still work
    T2 = T0 + 400 * 86400
    res, status = dispatch("r2", (*HOLDER1, 1), HOLDER1, T2)
    (roots[KB] / "r2" / "result.md").write_text("done r2\n")
    rc, out = submit("r2", PANE[KB][0])
    receipt2 = out.split(":")[1] if out.startswith("submitted:") else ""
    case("400 days past the TTL: dispatch + result submit still work (assignment authority is not clock-bound)",
         res == "dispatched" and rc == 0 and receipt2.startswith("recv_") and gate.state("r2") == "delivering")
    case("holder_tuple/live_mode at 400 days: assignment is still the live holder",
         ol.holder_tuple(lc, KB, T2, modes=ol.AUTHORITY_MODES) == (*HOLDER1, 1) and ol.live_mode(lc, KB, T2) == "assignment"
         and ol.holder_tuple(lc, KB, T2) is None)

    fs = load("fs_status", "factory-status.py")
    view, blockers = fs.lease_view(lease_db, KB, T2)
    case("FACTORY STATUS: live, authority_mode assignment, no expiry, no blockers",
         view == {"state": "live", "generation": 1, "authority_mode": "assignment", "expires_at": None} and blockers == [])

    # grant issuance (bind-live) against the assignment, 400 days on
    issued = issue_bind_live(T2, converted=True)
    case("GRANT ISSUANCE bind-live against an assignment 400 days on: issued, grant window not capped by a lease expiry",
         issued[0] == (0, issued[1]))
    case("GRANT ISSUANCE bind-live against an EXPIRED timed lease at the same clock is still refused (timed unchanged)",
         issue_bind_live(T2, converted=False)[0][0] != 0)

    # ---- revoke: every path fenced immediately
    nres = ol.assign_revoke(lc, KB, 1, *HOLDER1, "dec-rev", "operator revoked", T2 + 5, dry_run=False)
    case("REVOKE: audited, nothing cancelled (r2 is delivering and is left to settle)", nres["generation"] == 1)
    before = len(sent)
    res, status = dispatch("r3", (*HOLDER1, 1), HOLDER1, T2 + 6)
    case("DISPATCH after revoke: held, nothing sent, one-time grant NOT consumed",
         res.startswith("held:not_dispatched") and len(sent) == before and status == "granted" and gate.state("r3") is None)
    case("DELIVERY gate after revoke: admit refuses owner_no_lease; on_reply no_lease",
         gate.admit(KB, *PANE[KB], "x-new", T2 + 6).reason == "owner_no_lease" and gate.on_reply(KB, "r2", now=T2 + 6) == "no_lease")
    case("fence: the old holder is FencedOut", raises(lambda: ol.check_fence(lc, KB, 1, *PANE[KB], now=T2 + 6), ol.FencedOut))
    rc, out = accept(receipt2, hashlib.sha256(b"done r2\n").hexdigest())
    case("RESULT ACCEPT of a receipt issued under the revoked assignment -> refused", rc == 2 and "bindings_did_not_match" in out)
    rc, out = submit("r2", PANE[KB][0])
    case("RESULT SUBMIT after revoke -> refused", rc == 2 and "bindings_did_not_match" in out)
    view, blockers = fs.lease_view(lease_db, KB, T2 + 6)
    case("FACTORY STATUS after revoke: ended/revoked with an assignment_ended blocker",
         view["state"] == "ended" and view["release_reason"] == "revoked" and blockers == ["assignment_ended:gen1:revoked"])
    case("issuance bind-live after revoke -> refused", issue_bind_live(T2 + 6, converted=True, revoke=True)[0][0] != 0)
    case("legacy resurrection paths refused after revoke: assign_initial and acquire",
         raises(lambda: ol.assign_initial(lc, KB, *HOLDER1, "dec-again", "x", T2 + 7, False), ol.AssignmentConflict)
         and raises(lambda: ol.acquire(lc, KB, *PANE[KB], TTL, T2 + 7, session_digest=SESS[KB]), ol.LeaseConflict))

    # ---- audited replacement restores ONLY the new holder
    case("replace --after-revoke refused while a delivering request is unsettled",
         raises(lambda: ol.assign_replace(lc, KB, 1, *HOLDER1, *HOLDER2, "dec-new", "new owner", T2 + 8, False, True), ol.ReplaceRefused))
    ol.assign_settle(lc, KB, "r2", 1, "replied", "settled by operator", T2 + 9, dry_run=False)
    gen2 = ol.assign_replace(lc, KB, 1, *HOLDER1, *HOLDER2, "dec-new", "new owner", T2 + 10, False, True)
    case("audited replacement -> generation 2 for the NEW holder only",
         gen2 == 2 and ol.holder_tuple(lc, KB, T2 + 11, modes=ol.AUTHORITY_MODES) == (*HOLDER2, 2))
    reg[KB] = HOLDER2                                                     # the registry follows the audited replacement
    res_old, st_old = dispatch("r4", (*HOLDER1, 1), HOLDER1, T2 + 11)
    res_old2, st_old2 = dispatch("r5", (*HOLDER1, 2), HOLDER1, T2 + 11)
    case("old holder still gets nothing: dispatch held, grants not consumed (gen 1 and gen 2 bindings alike)",
         res_old.startswith("held:") and st_old == "granted" and res_old2.startswith("held:") and st_old2 == "granted")
    res_new, st_new = dispatch("r6", (*HOLDER2, 2), HOLDER2, T2 + 12)
    case("new holder dispatches under generation 2", res_new == "dispatched" and st_new == "consumed" and gate.state("r6") == "delivering")
    rc, out = submit("r6", PANE[KB][0])
    case("result submit from the OLD holder pane still refused after replacement", rc == 2)
    store.close(); gate.close(); av.close(); lc.close()


def issue_bind_live(t: float, converted: bool, revoke: bool = False):
    """owner-dispatch-issue.py --bind-live-generation in a fresh store: the lease is a timed gen 1 (acquired at T0)
    that is converted to an assignment, or left timed (control); optionally revoked. Returns ((rc, out), expected)."""
    odi = load("odi_bl", "owner-dispatch-issue.py")
    d = tmpdir()
    lc, av, roots, lease_db = vod.env(d)
    av.close()
    lc.execute("UPDATE owner_projects SET max_open=1 WHERE label=?", (KB,))
    vod.acquire(lc, KB, T0)
    if converted:
        ol.assign_convert(lc, KB, 1, *PANE[KB], SESS[KB], "dec-c", "cutover", T0 + 5, dry_run=False)
    if revoke:
        ol.assign_revoke(lc, KB, 1, *PANE[KB], SESS[KB], "dec-r", "revoked", t - 1, dry_run=False)
    os.chmod(lease_db, 0o600)
    adb = d / "auth.db"
    c = sqlite3.connect(str(adb), isolation_level=None)
    oda.migrate(c)
    c.close()
    os.chmod(adb, 0o600)
    body = b"READ-ONLY: list the newest result file name. Write nothing.\n"
    rq = d / "req"
    rq.mkdir()
    (rq / "req.txt").write_bytes(body)
    (d / "state" / "forms").mkdir(parents=True)
    proj = lc.execute("SELECT project FROM owner_projects WHERE label=?", (KB,)).fetchone()[0]
    rec = {"protocol": odi.PROTOCOL, "owner_label": KB, "project": proj, "max_open": 1,
           "expected_holder": {"pane_id": PANE[KB][0], "pane_birth": PANE[KB][1], "session_digest": SESS[KB]},
           "expected_generation": 1, "lease_ttl_s": TTL, "request_id": "bl-assign", "request_name": "req.txt",
           "request_sha256": hashlib.sha256(body).hexdigest(), "manifest": ["result.md"], "auth_id": "auth-bl-assign",
           "grant_window_s": 1800, "bind_live_generation": 1}
    emb = odi.approval_bytes(rec)
    fid = "20261104T120000-9999"
    (d / "state" / "forms" / f"{fid}.html").write_bytes(odi.render_form(rec))
    (d / "state" / "forms" / f"{fid}.json").write_text(json.dumps(
        {"id": fid, "status": "answered", "answers": {"decision": "approve", "approval_sha256": hashlib.sha256(emb).hexdigest()},
         "answered_at": int((t - 60) * 1000)}))
    keys = ("HERDR_OWNER_DISPATCH_ISSUE", "HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DELIVERY",
            "HERDR_OWNER_LEASE_DB", "HERDR_OWNER_DISPATCH_AUTH_DB")
    saved = {k: os.environ.get(k) for k in keys}
    real_root = odi.STATE_ROOT
    os.environ.update({"HERDR_OWNER_DISPATCH_ISSUE": "1", "HERDR_OWNER_LEASE_WRITER": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
                       "HERDR_OWNER_LEASE_DB": lease_db, "HERDR_OWNER_DISPATCH_AUTH_DB": str(adb)})
    odi.STATE_ROOT = os.path.realpath(d / "state")
    try:
        rc, out = capture(odi.main, ["--form-id", fid, "--request-dir", str(rq)],
                          resolve={KB: (*PANE[KB], SESS[KB])}.get, now=t)
    finally:
        odi.STATE_ROOT = real_root
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        lc.close()
    return (rc, out), f"issued:{rec['auth_id']}:gen1"


# ---------------------------------------------------------------- Part 3: timed compat + remaining consumers

def part3():
    base = tmpdir()
    lc, av, roots, lease_db = vod.env(base)
    os.chmod(lease_db, 0o600)
    vod.acquire(lc, KB, T0)
    gate = old.DeliveryGate(lease_db)
    case("TIMED compat: begin_notice still refuses lease_too_short inside the delivery margin",
         gate.admit(KB, *PANE[KB], "t1", T0).ok and gate.begin_notice(KB, *PANE[KB], 1, "t1", T0 + TTL - 10) == "lease_too_short")
    case("TIMED compat: the lease still expires at its TTL for every consumer",
         ol.holder_tuple(lc, KB, T0 + TTL - 1, modes=ol.AUTHORITY_MODES) is not None
         and ol.holder_tuple(lc, KB, T0 + TTL + 1, modes=ol.AUTHORITY_MODES) is None)
    case("TIMED compat: delivery begin_notice with plenty of lease left -> delivering",
         gate.begin_notice(KB, *PANE[KB], 1, "t1", T0 + 60) == "delivering")
    fs = load("fs_status3", "factory-status.py")
    case("TIMED compat: factory-status reports an expired timed lease as before",
         fs.lease_view(lease_db, KB, T0 + TTL + 5) == ({"state": "expired", "generation": 1, "expires_at": ol._iso(T0 + TTL)},
                                                       ["lease_expired:gen1"]))
    # kill switch keeps working in assignment mode
    ol.assign_convert(lc, KB, 1, *PANE[KB], SESS[KB], "dec-k", "cutover", T0 + 70, dry_run=False)
    ol.disable(lc)
    case("KILL SWITCH: disabled store -> delivery admit refuses owner_lease_disabled even for an assignment",
         gate.admit(KB, *PANE[KB], "t2", T0 + 80).reason == "owner_lease_disabled")
    gate.close()

    # resume refuses an assignment predecessor (NULL expiry must never reach a comparison)
    resume = load("resume_cli", "owner-lease-resume.py")
    keys = ("HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DELIVERY", "HERDR_OWNER_LEASE_DB")
    saved = {k: os.environ.get(k) for k in keys}
    os.environ.update({"HERDR_OWNER_LEASE_WRITER": "1", "HERDR_OWNER_LEASE_DELIVERY": "1", "HERDR_OWNER_LEASE_DB": lease_db})
    try:
        rc, out = capture(resume.main, ["--label", KB, "--ttl", "3600", "--expect-prev-generation", "1", "--apply"],
                          resolve={KB: (*PANE[KB], SESS[KB])}.get, now=T0 + 90)
    finally:
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    case("RESUME: an assignment predecessor is refused (typed), never a TypeError", rc == 2 and out == "refused:predecessor_is_assignment")

    # recovery / lifecycle: an assignment is never ended by lifecycle bookkeeping or the reaper
    import owner_lease_renew as olr
    case("RENEW never touches an assignment", olr.renew_due(lc, KB, (*PANE[KB], SESS[KB]), T0 + 100) == "not_timed")
    case("REAP never lists an assignment, even with its pane gone and 400 days elapsed",
         ol.observe_stale(lc, set(), now=T0 + 400 * 86400) == [])
    lc.close()


def part4():
    """remote-mcp/publisher.py: the result-availability bound() and the owner-notice deliver path, with an
    assignment whose original timed window ended 10 days of WALL-CLOCK ago (publisher reads the real clock)."""
    base = tmpdir()
    lc, av, roots, lease_db = vod.env(base)
    os.chmod(lease_db, 0o600)
    now = time.time()
    cfg = {"HERDR_OWNER_LEASE_DELIVERY": "1", "HERDR_OWNER_LEASE_DB": lease_db,
           "HERDR_RESULT_AVAILABILITY_DB": str(base / "ra.db"), "HERDR_RESULT_AVAILABILITY_ROOTS": f"{KB}={roots[KB]}",
           "HERDR_RESULT_AVAILABILITY_JOURNAL": str(base / "journal"), "HERDR_RESULT_AVAILABILITY": "1"}
    saved = {k: os.environ.get(k) for k in cfg}
    os.environ.update(cfg)
    try:
        sys.path.insert(0, str(HERE / "remote-mcp"))
        pub = load("pub_assign", "remote-mcp/publisher.py")
        rows = {KB: {"pane_id": PANE[KB][0], "pane_birth": PANE[KB][1], "agent_session": "kb-sess"}}
        pub.registry_owners = lambda: {k: dict(v, workspace="", registered_at="", updated_at="") for k, v in rows.items()}
        digest_kb = pub.owner_session_digest(KB, rows[KB])
        t_old = now - 10 * 86400
        ol.acquire(lc, KB, *PANE[KB], 3600, t_old, session_digest=digest_kb)          # expired in wall time
        ol.assign_convert(lc, KB, 1, *PANE[KB], digest_kb, "dec-pub", "cutover", t_old + 60, dry_run=False)
        d = od.Dispatcher(old.DeliveryGate(lease_db), av, lambda l, h, t: True, pub.registry_resolver,
                          authorize=vod.auto_auth(base / "auth.db"))
        case("PUBLISHER fixture: dispatch through the publisher's registry resolver under an assignment",
             d.dispatch(KB, "r_pub", b"REQ pub\n", ["result.md"]) == "dispatched")
        (roots[KB] / "r_pub" / "result.md").write_text("ACK r_pub")
        pub.result_availability_tick()
        pub.result_availability_tick()
        case("PUBLISHER result_availability_tick bound(): observing -> staged for an assignment holder",
             av.state("r_pub")[0] == "staged")

        pub.hub_get = lambda path: {"panes": [{"pane_id": PANE[KB][0], "agent": "omp"}]}
        pub.owner_pane_status = lambda label, owners, panes: "ok"
        pub._resolve_inbox_leaf = lambda label, kind, eid: None
        pub.write_inbox_message = lambda label, eid, sender, body: True
        pub.persisted_payload_matches = lambda label, eid, sender, body: True
        pub._send_owner_notice = lambda item, label, pane, write=True: {"exchange_id": item["exchange_id"], "outcome": "delivered"}
        local = {"owners": {KB: {"pane_id": PANE[KB][0], "pane_birth": PANE[KB][1]}}}
        res = pub.deliver_owner({"exchange_id": "ex_pub", "owner_label": KB, "body": "hello", "sender": "a@b.c"}, local)
        gate = pub.owner_lease_gate()
        case("PUBLISHER deliver_owner: assignment holder admitted, begin_notice has no TTL fence, delivered, gate delivering gen 1",
             res == {"exchange_id": "ex_pub", "outcome": "delivered"} and gate.record("ex_pub")[:3] == (KB, 1, "delivering"))
        # H1: same pane id + birth, the agent restarted (new session) -> notice delivery and reply credit both stop
        typed = []
        real_send = pub._send_owner_notice
        pub._send_owner_notice = lambda item, label, pane, write=True: typed.append(item["exchange_id"]) or real_send(item, label, pane, write)
        rows[KB]["agent_session"] = "kb-sess-RESTARTED"
        res_d = pub.deliver_owner({"exchange_id": "ex_drift", "owner_label": KB, "body": "hello", "sender": "a@b.c"}, local)
        case("H1 PUBLISHER deliver_owner with same-pane session drift: blocked owner_session_mismatch, nothing typed, nothing queued",
             res_d == {"exchange_id": "ex_drift", "outcome": "blocked", "reason": "owner_session_mismatch"}
             and typed == [] and gate.record("ex_drift") is None)
        case("H1 PUBLISHER credit_owner_reply with session drift: NOT credited, the delivering request stays delivering",
             pub.credit_owner_reply(gate, KB, "ex_pub", True) is False and gate.state("ex_pub") == "delivering")
        rows[KB]["agent_session"] = "kb-sess"
        case("H1 control: registry back to the exact holder -> reply credited",
             pub.credit_owner_reply(gate, KB, "ex_pub", True) is True and gate.state("ex_pub") == "replied")
        pub._send_owner_notice = real_send
        ol.assign_revoke(lc, KB, 1, *PANE[KB], digest_kb, "dec-pub-rev", "revoked", now, dry_run=False)
        res2 = pub.deliver_owner({"exchange_id": "ex_pub2", "owner_label": KB, "body": "hello", "sender": "a@b.c"}, local)
        case("PUBLISHER deliver_owner after revoke: blocked owner_no_lease, nothing delivered",
             res2 == {"exchange_id": "ex_pub2", "outcome": "blocked", "reason": "owner_no_lease"})
        gate.close()
    finally:
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        av.close()
        lc.close()


def main() -> int:
    part1()
    part2()
    part3()
    part4()
    print(f"{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failing")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
