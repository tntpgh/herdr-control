#!/usr/bin/env python3
"""owner-assignment.py --db PATH <show|assign|replace|revoke|settle> ... —
Plan 018 PR A's permanent CLI around lib/owner_lease.py's durable-assignment
operations (current_assignment/assign_initial/assign_replace/assign_revoke/
assign_settle). Operator CLI only: it never touches delivery/dispatch itself (the
consumers route assignments by authority mode, PR B) and never converts a timed
lease; cutover from timed leases is owner-assignment-activate.py.

Dry-run by default (owner-lease-migrate.py's own convention): every
subcommand opens read-only (ol.open_ro(), sqlite mode=ro) and reports what
it WOULD do; --apply is required to actually write, and additionally
refuses unless HERDR_OWNER_ASSIGNMENT_WRITER=1 -- a narrower gate than the
blanket HERDR_OWNER_LEASE_WRITER every other owner_lease writer CLI uses,
since this script authorizes a DIFFERENT, higher-stakes capability (durable
authority that time never ends) over the SAME physical store. The schema
must already be at SCHEMA_VERSION (owner-lease-migrate.py is the one
explicit, backed-up path that advances it); --apply refuses
schema_migration_required rather than migrating implicitly, same posture
as every other writer CLI here (R17b).

Output is one machine-readable line per subcommand, grep-able by its first
token (`current:`, `plan:`, `assigned:`, `replaced:`, `revoked:`,
`settled:`, `refused:`). Session digests are always truncated to 8 hex
chars in printed output -- never the full value, and never a token/secret
(decision_ref/reason are human-readable approval references, not
credentials).

Exit: 0 success (including a clean dry-run plan); 2 refused (typed
business-rule reason: AssignmentConflict / ReplaceRefused / RevokeRefused /
SettleRefused / InvalidOwner / ValueError / Disabled); 4 refused (config:
writer flag off, DB open/permission, schema migration required).
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import owner_lease as ol  # noqa: E402

WRITER_ENV = "HERDR_OWNER_ASSIGNMENT_WRITER"

BUSINESS_REFUSALS = (ol.AssignmentConflict, ol.ReplaceRefused, ol.RevokeRefused, ol.SettleRefused,
                     ol.InvalidOwner, ol.InvalidTransition, ol.Disabled, ValueError)


def _sd8(s: str) -> str:
    return (s or "")[:8]


def _open(db: str, apply: bool):
    """Returns (conn, refusal_line_or_None, exit_code_or_None)."""
    if apply:
        if os.environ.get(WRITER_ENV) != "1":
            return None, "refused:flags_off", 4
        try:
            return ol.open_rw_checked(db, require_table="owner_leases"), None, None
        except ValueError as exc:
            return None, f"refused:lease_{exc}", 4
        except ol.SchemaMigrationRequired as exc:
            return None, f"refused:schema_migration_required:{exc.cur}->{exc.target}:owner-lease-migrate.py --db {db} --apply", 4
    try:
        conn = ol.open_ro(db, require_table="owner_leases")
    except ValueError as exc:
        return None, f"refused:lease_{exc}", 4
    cur, target = ol.schema_status(conn)
    if cur < target:
        conn.close()
        return None, f"refused:schema_migration_required:{cur}->{target}:owner-lease-migrate.py --db {db} --apply", 4
    return conn, None, None


def _fmt_row(row: dict) -> str:
    return (f"mode={row['authority_mode']} gen={row['generation']} pane={row['pane_id']}@{row['pane_birth']} "
           f"session={_sd8(row['session_digest'])} decision_ref={row['decision_ref']!r} reason={row['reason']!r} "
           f"acquired_at={row['acquired_at']} expires_at={row['expires_at']}")


def cmd_show(a, conn) -> int:
    row = ol.current_assignment(conn, a.label)
    if row is None:
        print(f"current:{a.label}:none")
        return 0
    print(f"current:{a.label}:{_fmt_row(row)}")
    return 0


def cmd_assign(a, conn) -> int:
    try:
        res = ol.assign_initial(conn, a.label, a.pane_id, a.pane_birth, a.session_digest, a.decision_ref, a.reason,
                                dry_run=not a.apply)
    except BUSINESS_REFUSALS as exc:
        print(f"refused:{type(exc).__name__}:{getattr(exc, 'code', exc)}")
        return 2
    if isinstance(res, int):
        print(f"{'assigned' if a.apply else 'current'}:{a.label}:{res}")
        return 0
    print(f"plan:{res}:{a.label} pane={a.pane_id}@{a.pane_birth} session={_sd8(a.session_digest)} decision_ref={a.decision_ref!r}")
    return 0


def cmd_replace(a, conn) -> int:
    try:
        res = ol.assign_replace(conn, a.label, a.expected_generation, a.expected_pane_id, a.expected_pane_birth,
                                a.expected_session_digest, a.pane_id, a.pane_birth, a.session_digest,
                                a.decision_ref, a.reason, dry_run=not a.apply, after_revoke=a.after_revoke)
    except BUSINESS_REFUSALS as exc:
        print(f"refused:{type(exc).__name__}:{getattr(exc, 'code', exc)}")
        return 2
    if isinstance(res, int):
        print(f"{'replaced' if a.apply else 'current'}:{a.label}:{res}")
        return 0
    print(f"plan:{res}:{a.label} expected_gen={a.expected_generation} pane={a.pane_id}@{a.pane_birth} "
         f"decision_ref={a.decision_ref!r}")
    return 0


def cmd_revoke(a, conn) -> int:
    try:
        res = ol.assign_revoke(conn, a.label, a.expected_generation, a.expected_pane_id, a.expected_pane_birth,
                               a.expected_session_digest, a.decision_ref, a.reason, dry_run=not a.apply)
    except BUSINESS_REFUSALS as exc:
        print(f"refused:{type(exc).__name__}:{getattr(exc, 'code', exc)}")
        return 2
    if isinstance(res, dict):
        print(f"revoked:{a.label}:{res['generation']}:cancelled={len(res['cancelled'])}")
        return 0
    print(f"plan:{res}:{a.label} expected_gen={a.expected_generation} decision_ref={a.decision_ref!r}")
    return 0


def cmd_settle(a, conn) -> int:
    try:
        res = ol.assign_settle(conn, a.label, a.request_id, a.expected_generation, a.to, detail=a.detail,
                               dry_run=not a.apply)
    except BUSINESS_REFUSALS as exc:
        print(f"refused:{type(exc).__name__}:{getattr(exc, 'code', exc)}")
        return 2
    if res in ("replied", "timeout"):
        print(f"settled:{a.label}:{a.request_id}:{res}")
        return 0
    print(f"plan:{res}:{a.label}:{a.request_id}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_show = sub.add_parser("show")
    p_show.add_argument("--label", required=True)
    p_show.set_defaults(apply=False, fn=cmd_show)

    p_assign = sub.add_parser("assign")
    p_assign.add_argument("--label", required=True)
    p_assign.add_argument("--pane-id", dest="pane_id", required=True)
    p_assign.add_argument("--pane-birth", dest="pane_birth", required=True)
    p_assign.add_argument("--session-digest", dest="session_digest", required=True)
    p_assign.add_argument("--decision-ref", dest="decision_ref", required=True)
    p_assign.add_argument("--reason", required=True)
    p_assign.add_argument("--apply", action="store_true")
    p_assign.set_defaults(fn=cmd_assign)

    p_replace = sub.add_parser("replace")
    p_replace.add_argument("--label", required=True)
    p_replace.add_argument("--expected-generation", dest="expected_generation", type=int, required=True)
    p_replace.add_argument("--expected-pane-id", dest="expected_pane_id", required=True)
    p_replace.add_argument("--expected-pane-birth", dest="expected_pane_birth", required=True)
    p_replace.add_argument("--expected-session-digest", dest="expected_session_digest", required=True)
    p_replace.add_argument("--pane-id", dest="pane_id", required=True)
    p_replace.add_argument("--pane-birth", dest="pane_birth", required=True)
    p_replace.add_argument("--session-digest", dest="session_digest", required=True)
    p_replace.add_argument("--decision-ref", dest="decision_ref", required=True)
    p_replace.add_argument("--reason", required=True)
    p_replace.add_argument("--after-revoke", dest="after_revoke", action="store_true",
                           help="deliberate re-assignment from the latest REVOKED generation "
                                "(needs a decision-ref never used for this label); without it only an "
                                "ACTIVE assignment can be replaced")
    p_replace.add_argument("--apply", action="store_true")
    p_replace.set_defaults(fn=cmd_replace)

    p_revoke = sub.add_parser("revoke")
    p_revoke.add_argument("--label", required=True)
    p_revoke.add_argument("--expected-generation", dest="expected_generation", type=int, required=True)
    p_revoke.add_argument("--expected-pane-id", dest="expected_pane_id", required=True)
    p_revoke.add_argument("--expected-pane-birth", dest="expected_pane_birth", required=True)
    p_revoke.add_argument("--expected-session-digest", dest="expected_session_digest", required=True)
    p_revoke.add_argument("--decision-ref", dest="decision_ref", required=True)
    p_revoke.add_argument("--reason", required=True)
    p_revoke.add_argument("--apply", action="store_true")
    p_revoke.set_defaults(fn=cmd_revoke)

    p_settle = sub.add_parser("settle")
    p_settle.add_argument("--label", required=True)
    p_settle.add_argument("--request-id", dest="request_id", required=True)
    p_settle.add_argument("--expected-generation", dest="expected_generation", type=int, required=True)
    p_settle.add_argument("--to", required=True, choices=["replied", "timeout"])
    p_settle.add_argument("--detail", default="")
    p_settle.add_argument("--apply", action="store_true")
    p_settle.set_defaults(fn=cmd_settle)

    a = ap.parse_args(argv)
    conn, refusal, code = _open(a.db, a.apply)
    if refusal:
        print(refusal)
        return code
    try:
        return a.fn(a, conn)
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
