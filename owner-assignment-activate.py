#!/usr/bin/env python3
"""owner-assignment-activate.py --db PATH --decision-ref REF --reason TEXT
[--label L ...] [--apply] | --rollback BACKUP [--expect-sha256 SHA] [--apply]

Plan 018 PR B's ONE activation/deployment entrypoint: migrate an owner-lease
store to the current schema (v6) and convert every CURRENTLY AUTHORITATIVE
timed owner lease to a durable assignment -- in place (lib/owner_lease.py
assign_convert: same lease row, same generation, same holder, so open
requests and generation-bound standing grants keep their binding) -- but
only when the owner registry's CURRENT (pane, birth, session digest) for the
label is EXACTLY the lease holder. A holder is never inferred: a label whose
registry tuple is missing or different refuses the WHOLE run (exit 2) before
any backup or write, and nothing is converted.

Dry-run by default: read-only (sqlite mode=ro), prints `plan:` lines and
writes nothing. --apply requires HERDR_OWNER_ASSIGNMENT_WRITER=1 (the narrow
gate for durable authority) and, when the schema must advance, also
HERDR_OWNER_LEASE_WRITER=1 (owner-lease-migrate.py's gate). An unreleased
but EXPIRED timed lease is never converted (no resurrection; it is reported
`skip:...:expired`). An owner_state kill switch (enabled=0) refuses the run.

--apply order: (1) all verification, nothing written; (2) sqlite-API backup
of the store (0600, sha256 printed, exact rollback line printed BEFORE any
change); (3) schema migration (one atomic transaction); (4) per label:
re-resolve the registry then assign_convert (own audited transaction,
'converted' event). Idempotent: a re-run finds every label already an
assignment (`current:`), takes no backup and writes nothing. If a step after
the backup fails (exit 3) the printed rollback line is the way back; a
partial conversion is also safe to simply re-run.

--rollback BACKUP: restores the store's content from an activation backup.
Dry-run by default (prints backup schema version and sha256); --apply first
snapshots the CURRENT store to `<db>.pre-rollback-<ts>.sqlite3`, then
restores through sqlite's backup API. --expect-sha256 pins the backup file.
NOTE: a rollback discards every row written after the backup (including
owner_events and any requests); stop owner consumers first.

Exit: 0 ok (incl. clean dry-run, nothing-to-do); 2 refused (drift /
unresolved registry / kill switch / assign_convert refusal); 4 refused
(config: flag off, DB open, store too old); 3 error after the backup.
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

ASSIGN_WRITER = "HERDR_OWNER_ASSIGNMENT_WRITER"
LEASE_WRITER = "HERDR_OWNER_LEASE_WRITER"
MIN_SCHEMA = 3  # session_digest column: a pre-v3 holder has no digest to match, so it can never convert


def _sd8(s: str) -> str:
    return (s or "")[:8]


def _sha(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _unreleased(conn, cur_version: int) -> list[dict]:
    """Every unreleased lease row, readable on any schema >= MIN_SCHEMA (a pre-v6 row is timed by definition)."""
    mode_col = "authority_mode" if cur_version >= 6 else "'timed'"
    rows = conn.execute(
        f"SELECT label, pane_id, pane_birth, generation, session_digest, expires_at, {mode_col} "
        "FROM owner_leases WHERE released_at IS NULL ORDER BY label").fetchall()
    return [dict(zip(("label", "pane_id", "pane_birth", "generation", "session_digest", "expires_at", "mode"), r))
            for r in rows]


def build_plan(conn, cur_version: int, now: float, resolve, only: set[str]) -> tuple[list[tuple], list[str]]:
    """([(action, label, detail...)], refusals). Actions: convert | current | skip. Pure read."""
    steps: list[tuple] = []
    refusals: list[str] = []
    seen = set()
    for r in _unreleased(conn, cur_version):
        label = r["label"]
        seen.add(label)
        if only and label not in only:
            continue
        if r["mode"] == "assignment":
            reg = resolve(label)
            note = "" if reg and tuple(reg) == (r["pane_id"], r["pane_birth"], r["session_digest"]) else \
                " note=registry_differs_from_assignment_holder"
            steps.append(("current", label, f"gen={r['generation']}{note}"))
            continue
        if not r["expires_at"] or r["expires_at"] <= ol._iso(now):
            steps.append(("skip", label, f"gen={r['generation']} expired"))
            continue
        reg = resolve(label)
        holder = (r["pane_id"], r["pane_birth"], r["session_digest"])
        if reg is None:
            refusals.append(f"{label}:registry_unresolved")
        elif tuple(reg) != holder:
            refusals.append(f"{label}:registry_holder_mismatch")
        else:
            steps.append(("convert", label, r))
    for label in sorted(only - seen):
        refusals.append(f"{label}:no_unreleased_lease")
    return steps, refusals


def _backup(src, db: str, tag: str) -> tuple[str, str]:
    path = f"{db}.{tag}-{int(time.time())}.sqlite3"
    dst = sqlite3.connect(path)
    try:
        src.backup(dst)
    finally:
        dst.close()
    os.chmod(path, 0o600)
    return path, _sha(path)


def _rollback_line(backup: str, db: str) -> str:
    return (f"rollback: python3 {Path(__file__).name} --db {db} --rollback {backup} --apply   # restores the "
            f"pre-activation content (rows written after the backup are discarded); or: cp {backup} {db}")


def cmd_rollback(a) -> int:
    backup = a.rollback
    if not Path(backup).is_file():
        print("refused:backup_missing")
        return 4
    sha = _sha(backup)
    if a.expect_sha256 and a.expect_sha256 != sha:
        print(f"refused:backup_sha256_mismatch:{sha}")
        return 4
    try:
        b = sqlite3.connect(f"file:{backup}?mode=ro", uri=True)
        try:
            bver = ol.current_version(b)
            ok = b.execute("PRAGMA integrity_check").fetchone()[0]
        finally:
            b.close()
    except sqlite3.Error as exc:
        print(f"refused:backup_unreadable:{type(exc).__name__}")
        return 4
    if ok != "ok":
        print("refused:backup_integrity")
        return 4
    print(f"rollback_plan:restore {backup} (schema v{bver}, sha256 {sha}) over {a.db}")
    if not a.apply:
        print("dry-run: nothing written (pass --apply to restore)")
        return 0
    if os.environ.get(ASSIGN_WRITER) != "1":
        print("refused:flags_off")
        return 4
    os.umask(0o077)
    try:
        live = private_sqlite.open_private(a.db, ol.connect, require_table="owner_projects")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    try:
        snap, snap_sha = _backup(live, a.db, "pre-rollback")
        print(f"backup:{snap}")
        print(f"backup_sha256:{snap_sha}")
        src = sqlite3.connect(f"file:{backup}?mode=ro", uri=True)
        try:
            src.backup(live)
        finally:
            src.close()
        chk = live.execute("PRAGMA integrity_check").fetchone()[0]
        print(f"restored:{backup}:schema_v{ol.current_version(live)}:integrity={chk}")
        return 0 if chk == "ok" else 3
    except BaseException as exc:  # noqa: BLE001
        print(f"error:{type(exc).__name__}:{exc}")
        return 3
    finally:
        live.close()


def main(argv=None, resolve=None, clock=time.time) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--decision-ref", dest="decision_ref")
    ap.add_argument("--reason")
    ap.add_argument("--label", action="append", default=[])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--rollback")
    ap.add_argument("--expect-sha256", dest="expect_sha256")
    a = ap.parse_args(argv)
    if a.rollback:
        return cmd_rollback(a)
    if not a.decision_ref or not a.reason:
        print("refused:decision_ref_and_reason_required")
        return 4
    try:
        ol._check_evidence(a.decision_ref, a.reason)
    except ValueError as exc:
        print(f"refused:evidence:{exc}")
        return 4
    if resolve is None:
        sys.path.insert(0, str(HERE / "remote-mcp"))
        import publisher  # noqa: E402  (read-only registry resolver; HERDR_RUN_REGISTRY selects the registry)
        resolve = publisher.registry_resolver

    try:
        probe = ol.open_ro(a.db, require_table="owner_projects")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    try:
        cur, target = ol.schema_status(probe)
        if cur < MIN_SCHEMA:
            print(f"refused:schema_too_old:{cur}:run owner-lease-migrate.py first (no holder digest to match)")
            return 4
        enabled = probe.execute("SELECT enabled FROM owner_state WHERE id=1").fetchone()
        if not enabled or not enabled[0]:
            print("refused:owner_leasing_disabled")
            return 2
        now = clock()
        steps, refusals = build_plan(probe, cur, now, resolve, set(a.label))
    finally:
        probe.close()

    print(f"schema:{cur}->{target}" if cur < target else f"schema:current:{cur}")
    for s in steps:
        if s[0] == "convert":
            r = s[2]
            print(f"plan:convert:{s[1]}:gen={r['generation']} pane={r['pane_id']}@{r['pane_birth']} "
                  f"session={_sd8(r['session_digest'])} expires_at={r['expires_at']}")
        else:
            print(f"{'current' if s[0] == 'current' else 'skip'}:{s[1]}:{s[2]}")
    if refusals:
        for r in refusals:
            print(f"refused:drift:{r}")
        print("refused:no_conversion_applied (never infers a holder; fix the registry or the lease, then re-run)")
        return 2
    converts = [s for s in steps if s[0] == "convert"]
    if cur >= target and not converts:
        print("nothing_to_do")
        return 0
    if not a.apply:
        print("dry-run: nothing written (pass --apply to migrate + convert)")
        return 0

    if os.environ.get(ASSIGN_WRITER) != "1" or (cur < target and os.environ.get(LEASE_WRITER) != "1"):
        print("refused:flags_off")
        return 4
    os.umask(0o077)
    try:
        conn = private_sqlite.open_private(a.db, ol.connect, require_table="owner_projects")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    backup = None
    try:
        backup, sha = _backup(conn, a.db, f"pre-assignment-activate-v{cur}")
        print(f"backup:{backup}")
        print(f"backup_sha256:{sha}")
        print(_rollback_line(backup, a.db))
        if cur < target:
            print(f"migrated:{cur}->{ol.migrate(conn)}")
        for _, label, r in converts:
            reg = resolve(label)  # fresh read immediately before the write; the exact tuple or nothing
            holder = (r["pane_id"], r["pane_birth"], r["session_digest"])
            if reg is None or tuple(reg) != holder:
                print(f"refused:drift:{label}:registry_changed_during_apply")
                print("refused:partial_apply: earlier labels may be converted; re-run or use the rollback line above")
                return 2
            try:
                gen = ol.assign_convert(conn, label, r["generation"], r["pane_id"], r["pane_birth"],
                                        r["session_digest"], a.decision_ref, a.reason, now=clock(), dry_run=False)
            except (ol.ConvertRefused, ol.InvalidOwner, ol.Disabled, ValueError) as exc:
                print(f"refused:{type(exc).__name__}:{getattr(exc, 'code', exc)}:{label}")
                print("refused:partial_apply: earlier labels may be converted; re-run or use the rollback line above")
                return 2
            print(f"converted:{label}:gen={gen}")
        return 0
    except BaseException as exc:  # noqa: BLE001
        print(f"error:{type(exc).__name__}:{exc}")
        if backup:
            print(_rollback_line(backup, a.db))
        return 3
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
