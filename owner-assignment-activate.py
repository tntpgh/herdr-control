#!/usr/bin/env python3
"""owner-assignment-activate.py --db PATH --decision-ref REF --reason TEXT
[--label L ...] [--apply] | --rollback BACKUP --expect-sha256 SHA [--ack-discard-post-backup-events] [--apply]

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
The backup must be one this tool made for --db (<db>.pre-assignment-activate-
v<N>-<epoch>.sqlite3 or <db>.pre-rollback-<epoch>.sqlite3 beside it), an
owner-lease store (owner_projects/owner_leases/owner_events/owner_state), and
--expect-sha256 is REQUIRED with --apply. Dry-run by default (prints schema,
sha256 and any post-backup authority events). It REFUSES (exit 2) when the live
store holds `revoked`/`assigned` events newer than the backup -- a restore would
erase audited revocations and re-authorize revoked holders -- unless
--ack-discard-post-backup-events is given. --apply first snapshots the CURRENT
store to `<db>.pre-rollback-<ts>.sqlite3` (O_EXCL, 0600), restores through
sqlite's backup API, then ENGAGES the kill switch (owner_state.enabled=0): a
rollback never re-enables leasing; the operator does that on purpose. The
restored store has the BACKUP's schema (v5 after an activation rollback), so v6
code fails until owner-lease-migrate.py runs. Rows written after the backup are
discarded; stop owner consumers first.

Exit: 0 ok (incl. clean dry-run, nothing-to-do); 2 refused (drift /
unresolved registry / kill switch / assign_convert refusal); 4 refused
(config: flag off, DB open, store too old); 3 error after the backup.
"""
from __future__ import annotations

import argparse
import re
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
    """ol.export_backup: O_CREAT|O_EXCL 0600 -- never overwrites or follows a pre-planted file/symlink."""
    path = f"{db}.{tag}-{int(time.time())}.sqlite3"
    ol.export_backup(src, path)
    return path, _sha(path)


def _rollback_line(backup: str, db: str, sha: str) -> str:
    return (f"rollback: python3 {Path(__file__).name} --db {db} --rollback {backup} --expect-sha256 {sha} --apply"
            "   # restores pre-activation content, leaves the kill switch ENGAGED; refuses if revocations/"
            "assignments were made since (see --ack-discard-post-backup-events)")


REQUIRED_TABLES = ("owner_projects", "owner_leases", "owner_events", "owner_state")
# Events that are audited authority decisions made AFTER a backup: a restore would silently erase them.
AUTHORITY_EVENT_KINDS = ("revoked", "assigned")


def _backup_name_ok(backup: str, db: str) -> bool:
    """Bound to THIS store by name: only what _backup() itself produced for --db (activation backup or
    a pre-rollback snapshot), never an arbitrary file."""
    pat = re.escape(Path(db).name) + r"\.(pre-assignment-activate-v\d+|pre-rollback)-\d+\.sqlite3"
    return re.fullmatch(pat, Path(backup).name) is not None and Path(backup).parent.resolve() == Path(db).resolve().parent


def _post_backup_events(live, backup_conn) -> tuple[list[tuple], str | None]:
    """([(seq, label, kind, generation)], refusal). Authority events in `live` newer than anything the backup
    holds. A backup whose newest event is AHEAD of the live store is not a backup of it (refusal)."""
    bmax = backup_conn.execute("SELECT COALESCE(MAX(seq),0) FROM owner_events").fetchone()[0]
    lmax = live.execute("SELECT COALESCE(MAX(seq),0) FROM owner_events").fetchone()[0]
    if bmax > lmax:
        return [], "backup_newer_than_store"
    marks = ",".join("?" * len(AUTHORITY_EVENT_KINDS))
    rows = live.execute(f"SELECT seq, label, kind, generation FROM owner_events WHERE seq>? AND kind IN ({marks}) "
                        "ORDER BY seq", (bmax, *AUTHORITY_EVENT_KINDS)).fetchall()
    return [tuple(r) for r in rows], None


def cmd_rollback(a) -> int:
    backup = a.rollback
    if not Path(backup).is_file():
        print("refused:backup_missing")
        return 4
    if not _backup_name_ok(backup, a.db):
        print("refused:backup_not_from_this_store (expected <db>.pre-assignment-activate-v<N>-<epoch>.sqlite3 "
              "or <db>.pre-rollback-<epoch>.sqlite3 beside --db)")
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
            have = {r[0] for r in b.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        finally:
            b.close()
    except sqlite3.Error as exc:
        print(f"refused:backup_unreadable:{type(exc).__name__}")
        return 4
    if ok != "ok":
        print("refused:backup_integrity")
        return 4
    if not set(REQUIRED_TABLES) <= have:
        print("refused:backup_not_an_owner_lease_store")
        return 4
    try:
        probe = ol.open_ro(a.db, require_table="owner_projects")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    try:
        b = sqlite3.connect(f"file:{backup}?mode=ro", uri=True)
        try:
            events, why = _post_backup_events(probe, b)
        finally:
            b.close()
    except sqlite3.Error as exc:
        print(f"refused:live_events_unreadable:{type(exc).__name__}")
        return 4
    finally:
        probe.close()
    if why:
        print(f"refused:{why}")
        return 4
    print(f"rollback_plan:restore {backup} (schema v{bver}, sha256 {sha}) over {a.db}")
    for seq, label, kind, gen in events:
        print(f"post_backup_authority_event:seq={seq} label={label} kind={kind} gen={gen} (a restore ERASES this decision)")
    if events and not a.ack_discard:
        print("refused:post_backup_authority_events (revocations/assignments made after the backup would be undone, "
              "re-authorizing revoked holders; re-run with --ack-discard-post-backup-events only if that is intended)")
        return 2
    print("note:the restored store is left owner_state.enabled=0 (kill switch ENGAGED); re-enable it deliberately")
    if not a.apply:
        print("dry-run: nothing written (pass --apply with --expect-sha256 to restore)")
        return 0
    if not a.expect_sha256:
        print(f"refused:expect_sha256_required (pass --expect-sha256 {sha})")
        return 4
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
        ol.disable(live)  # a rollback never re-enables leasing: the operator does that on purpose
        chk = live.execute("PRAGMA integrity_check").fetchone()[0]
        en = live.execute("SELECT enabled FROM owner_state WHERE id=1").fetchone()[0]
        print(f"restored:{backup}:schema_v{ol.current_version(live)}:integrity={chk}:owner_state.enabled={en}")
        return 0 if chk == "ok" and en == 0 else 3
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
    ap.add_argument("--ack-discard-post-backup-events", dest="ack_discard", action="store_true")
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
        print(_rollback_line(backup, a.db, sha))
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
            print(_rollback_line(backup, a.db, sha))
        return 3
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
