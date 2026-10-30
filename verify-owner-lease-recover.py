#!/usr/bin/env python3
"""verify-owner-lease-recover.py — offline proofs for
lib/owner_lease_recover.py (emergency recovery of a REGISTERED label whose
lifecycle_end_at has already passed with an empty/unknown unregister_token)
and its CLI, owner-lease-recover.py. No live registry, pane, network or
herdr call -- every DB is a fresh mktemp sqlite3 file; every forms-dir read
is under a mktemp HERDR_STATE_ROOT, never ~/.local/state/herdr."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_lease as ol  # noqa: E402
import owner_lease_recover as olrec  # noqa: E402

spec = importlib.util.spec_from_file_location("olrec_cli", HERE / "owner-lease-recover.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

FAILS: list[str] = []
T0 = 1_900_000_000.0
P1, B1 = "w1:p1", "term_aaa"
P2, B2 = "w1:p2", "term_bbb"
PROJ = "tntpgh/stuck-project"


def case(name, cond):
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def scratch() -> str:
    d = os.path.realpath(tempfile.mkdtemp())
    path = os.path.join(d, "owner.sqlite3")
    c = ol.connect(path)
    ol.migrate(c)
    c.close()
    os.chmod(path, 0o600)
    return path


def row(conn, label):
    return conn.execute(
        "SELECT project, unregistered_at, lifecycle_end_at, unregister_token FROM owner_projects WHERE label=?",
        (label,)).fetchone()


def stuck_label(conn, label="stuck", lifecycle_end_at=T0 - 1000, project=PROJ):
    """The exact bug fixture: registered, past its bound, empty token."""
    ol.register_owner(conn, label, project, now=T0 - 100_000, lifecycle_end_at=lifecycle_end_at,
                      unregister_token="")
    return label


def main():
    # --- wrong owner/label ---
    path = scratch()
    c = ol.connect(path)
    stuck_label(c)
    case("wrong label: no such owner_projects row -> InvalidOwner",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "no-such-label", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)), ol.InvalidOwner))
    case("wrong project for a real label -> InvalidOwner",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "stuck", "tntpgh/some-other-project", T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)),
             ol.InvalidOwner))

    # --- excessive TTL ---
    case("new bound > MAX_TTL_S past now -> ValueError, rejected",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "stuck", PROJ, T0 + ol.MAX_TTL_S + 1, P2, B2, "form-1", now=T0, dry_run=True)), ValueError))
    case("new bound in the past -> ValueError, rejected",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "stuck", PROJ, T0 - 1, P2, B2, "form-1", now=T0, dry_run=True)), ValueError))
    case("new bound not past the CURRENT bound -> ValueError, rejected",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "stuck", PROJ, T0 - 500, P2, B2, "form-1", now=T0, dry_run=True)), ValueError))
    case("missing confirmation_ref -> ValueError, rejected",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "stuck", PROJ, T0 + 3600, P2, B2, "", now=T0, dry_run=True)), ValueError))

    # --- "revoked"/disabled state: owner_state.enabled != 1 refuses, in BOTH modes ---
    ol.disable(c, now=T0)
    case("disabled (owner_state.enabled != 1): dry-run refuses too, not a false would_recover",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "stuck", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)), ol.Disabled))
    case("disabled: --apply refuses identically",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "stuck", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=False)), ol.Disabled))
    c.execute("UPDATE owner_state SET enabled=1 WHERE id=1")
    c.execute("COMMIT") if c.in_transaction else None
    c.close()

    # --- unregistered labels: refused, directed at reregister, not this path ---
    c = ol.connect(path)
    ol.register_owner(c, "gone", PROJ + "-gone", now=T0 - 100_000, lifecycle_end_at=T0 - 1000,
                      unregister_token="tok-gone")
    case("fixture: unregister_owner succeeds (token present)",
         ol.unregister_owner(c, "gone", "tok-gone", now=T0 - 500, dry_run=False) == "unregistered")
    case("unregistered label -> InvalidOwner, never recovered here",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "gone", PROJ + "-gone", T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)), ol.InvalidOwner))

    # --- no lifecycle bound at all / bound not yet passed: informational, not errors ---
    ol.register_owner(c, "unbounded", "tntpgh/unbounded", now=T0 - 100_000)
    case("no lifecycle_end_at recorded -> no_lifecycle_bound, not an exception",
         olrec.recover_lifecycle(c, "unbounded", "tntpgh/unbounded", T0 + 3600, P2, B2, "form-1",
                                 now=T0, dry_run=True) == ("no_lifecycle_bound", None))
    ol.register_owner(c, "future", "tntpgh/future", now=T0 - 100_000, lifecycle_end_at=T0 + 100_000,
                      unregister_token="")
    case("bound not yet passed -> not_expired, not an exception",
         olrec.recover_lifecycle(c, "future", "tntpgh/future", T0 + 3600, P2, B2, "form-1",
                                 now=T0, dry_run=True) == ("not_expired", None))

    # --- never self-extension: a label can still have a LIVE lease even
    # after its lifecycle_end_at passed (acquire()/claim never consult the
    # bound; only renew_due does) -- the caller being that exact holder is
    # refused; a DIFFERENT caller is not. ---
    ol.register_owner(c, "held", "tntpgh/held", now=T0 - 100_000, lifecycle_end_at=T0 - 1000,
                      unregister_token="")
    ol.acquire(c, "held", P1, B1, 50_000, now=T0 - 2000, session_digest="a" * 64)  # expires far beyond `now`
    case("fixture: 'held' is past its bound yet still has a live lease",
         ol.holder_tuple(c, "held", T0) == (P1, B1, "a" * 64, 1))
    case("self-extension: the live holder calling for itself is refused",
         isinstance(_raises(lambda: olrec.recover_lifecycle(
             c, "held", "tntpgh/held", T0 + 3600, P1, B1, "form-1", now=T0, dry_run=True)), ol.Unauthorized))
    case("self-extension: a DIFFERENT caller is NOT refused on that ground (still would_recover)",
         olrec.recover_lifecycle(c, "held", "tntpgh/held", T0 + 3600, P2, B2, "form-1",
                                 now=T0, dry_run=True) == ("would_recover", None))
    c.close()

    # --- interrupted recovery: a crash between the UPDATE and the audit
    # event must leave the row completely unchanged (ol._tx's own ROLLBACK,
    # same atomicity guarantee every other writer in this file relies on). ---
    c = ol.connect(path)
    before = row(c, "stuck")
    with mock.patch.object(ol, "_event", side_effect=RuntimeError("simulated crash mid-tx")):
        try:
            olrec.recover_lifecycle(c, "stuck", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=False)
            crashed = False
        except RuntimeError:
            crashed = True
    case("interrupted recovery: the simulated crash actually propagated", crashed)
    case("interrupted recovery: the row is BYTE-IDENTICAL to before the crash (rolled back)",
         row(c, "stuck") == before)
    case("interrupted recovery: no lifecycle_recovered event was written",
         c.execute("SELECT COUNT(*) FROM owner_events WHERE label='stuck' AND kind='lifecycle_recovered'"
                   ).fetchone()[0] == 0)

    # --- happy path ---
    dry = olrec.recover_lifecycle(c, "stuck", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)
    case("happy path: dry-run reports would_recover, no token, row untouched",
         dry == ("would_recover", None) and row(c, "stuck") == before)
    status, token = olrec.recover_lifecycle(c, "stuck", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=False)
    case("happy path: --apply recovers and mints a fresh non-empty token",
         status == "recovered" and isinstance(token, str) and len(token) == 64 and token != "")
    after = row(c, "stuck")
    case("happy path: lifecycle_end_at advanced to exactly the new bound",
         after[2] == ol._iso(T0 + 3600))
    case("happy path: unregister_token is the FRESH one, not empty, not the old value",
         after[3] == token and after[3] != before[3])
    case("happy path: exactly one lifecycle_recovered event, carrying the confirmation ref",
         [r for r in c.execute("SELECT ref FROM owner_events WHERE label='stuck' AND kind='lifecycle_recovered'"
                               ).fetchall()] == [("form-1",)])
    case("happy path: the event's detail never contains the new token (no secret in the audit log)",
         token not in (c.execute("SELECT detail FROM owner_events WHERE label='stuck' AND kind='lifecycle_recovered'"
                                 ).fetchone()[0]))

    # --- replayed confirmation: the SAME confirmation/params, immediately
    # replayed, is refused -- the bound this call already advanced now
    # reads back as not_expired, never a second grant or a second token. ---
    replay = olrec.recover_lifecycle(c, "stuck", PROJ, T0 + 7200, P2, B2, "form-1", now=T0, dry_run=False)
    case("replayed confirmation: refused as not_expired, not a second recovery",
         replay == ("not_expired", None))
    case("replayed confirmation: the row still holds the FIRST recovery's token, untouched by the replay",
         row(c, "stuck")[3] == token)
    c.close()

    # --- race_lost: two concurrent recoveries of the SAME stuck label; the
    # second writer to commit wins, the first (which read a now-stale pair)
    # loses the CAS and reports race_lost, writing nothing (r16/F3 pattern). ---
    path_r = scratch()
    cr = ol.connect(path_r)
    stuck_label(cr, label="race", lifecycle_end_at=T0 - 1000)
    cr2 = ol.connect(path_r)
    real_tx = ol._tx
    spying = {"armed": True}

    def spying_tx(conn, fn, mutation=True):
        if spying["armed"] and conn is cr:
            spying["armed"] = False
            spying["b_result"] = olrec.recover_lifecycle(cr2, "race", PROJ, T0 + 5000, P2, B2, "form-B",
                                                          now=T0, dry_run=False)
        return real_tx(conn, fn, mutation=mutation)

    ol._tx = spying_tx
    try:
        a_result = olrec.recover_lifecycle(cr, "race", PROJ, T0 + 3600, P2, B2, "form-A", now=T0, dry_run=False)
    finally:
        ol._tx = real_tx
    final_row = row(cr, "race")
    case("race: interleaved caller B (landed first) reports recovered",
         spying["b_result"][0] == "recovered")
    case("race: caller A (lost the CAS) reports race_lost, writes nothing",
         a_result == ("race_lost", None))
    case("race: the row holds B's bound and B's token, not A's",
         final_row[2] == ol._iso(T0 + 5000) and final_row[3] == spying["b_result"][1])
    case("race: exactly ONE lifecycle_recovered event, not two",
         cr.execute("SELECT COUNT(*) FROM owner_events WHERE label='race' AND kind='lifecycle_recovered'"
                   ).fetchone()[0] == 1)
    cr.close(); cr2.close()

    # ================= CLI: owner-lease-recover.py =================
    cli_env_cases()

    return 1 if FAILS else 0


def _raises(fn):
    try:
        fn()
    except Exception as exc:  # noqa: BLE001 - we want the exact instance back
        return exc
    return None


def cli_env_cases():
    # --- read_confirmation(): the forms-dir validation, in isolation ---
    state_root = Path(tempfile.mkdtemp())
    forms = state_root / "forms"
    forms.mkdir(parents=True)

    def write_form(fid, **rec):
        (forms / f"{fid}.json").write_text(json.dumps(rec))

    old_env = os.environ.get("HERDR_STATE_ROOT")
    os.environ["HERDR_STATE_ROOT"] = str(state_root)
    try:
        case("read_confirmation: missing file -> form_unreadable",
             cli.read_confirmation("nope", "lab", 123.0, P1, B1) == "form_unreadable")
        case("read_confirmation: path traversal in form id -> invalid_form_id, never opened",
             cli.read_confirmation("../../etc/passwd", "lab", 123.0, P1, B1) == "invalid_form_id")
        write_form("f1", status="open", answers={})
        case("read_confirmation: not yet answered -> form_not_answered",
             cli.read_confirmation("f1", "lab", 123.0, P1, B1) == "form_not_answered")
        write_form("f2", status="answered", answers={"decision": "decline", "label": "lab",
                                                       "new_lifecycle_end_at": 123.0,
                                                       "caller_pane_id": P1, "caller_pane_birth": B1})
        case("read_confirmation: answered but declined -> form_not_approved",
             cli.read_confirmation("f2", "lab", 123.0, P1, B1) == "form_not_approved")
        write_form("f3", status="answered", answers={"decision": "approve", "label": "WRONG",
                                                       "new_lifecycle_end_at": 123.0,
                                                       "caller_pane_id": P1, "caller_pane_birth": B1})
        case("read_confirmation: approved for a different label -> form_label_mismatch",
             cli.read_confirmation("f3", "lab", 123.0, P1, B1) == "form_label_mismatch")
        write_form("f4", status="answered", answers={"decision": "approve", "label": "lab",
                                                       "new_lifecycle_end_at": 999999.0,
                                                       "caller_pane_id": P1, "caller_pane_birth": B1})
        case("read_confirmation: approved for a different bound -> form_bound_mismatch",
             cli.read_confirmation("f4", "lab", 123.0, P1, B1) == "form_bound_mismatch")
        write_form("f5", status="answered", answers={"decision": "approve", "label": "lab",
                                                       "new_lifecycle_end_at": 123.0,
                                                       "caller_pane_id": "someone-else", "caller_pane_birth": B1})
        case("read_confirmation: approved for a different caller -> form_caller_mismatch",
             cli.read_confirmation("f5", "lab", 123.0, P1, B1) == "form_caller_mismatch")
        write_form("f6", status="answered", answers={"decision": "approve", "label": "lab",
                                                       "new_lifecycle_end_at": 123.4,
                                                       "caller_pane_id": P1, "caller_pane_birth": B1})
        case("read_confirmation: exactly bound, approved -> None (valid)",
             cli.read_confirmation("f6", "lab", 123.0, P1, B1) is None)
    finally:
        if old_env is None:
            os.environ.pop("HERDR_STATE_ROOT", None)
        else:
            os.environ["HERDR_STATE_ROOT"] = old_env

    # --- full CLI process: flags_off, unconfirmed, dry-run, --apply ---
    # The CLI calls recover_lifecycle(now=time.time()) -- REAL wall clock,
    # not this file's fictional T0 -- so this fixture's bound and label
    # must be relative to the real clock too.
    real_now = time.time()
    db_path = scratch()
    c = ol.connect(db_path)
    stuck_label(c, label="cli-stuck", lifecycle_end_at=real_now - 1000)
    c.close()
    new_end = real_now + 3600

    def run(apply=False, writer="1", confirm_form="good", db=db_path, extra_env=None):
        env = dict(os.environ)
        env["HERDR_STATE_ROOT"] = str(state_root)
        if writer is not None:
            env["HERDR_OWNER_LEASE_WRITER"] = writer
        else:
            env.pop("HERDR_OWNER_LEASE_WRITER", None)
        env["HERDR_OWNER_LEASE_DB"] = db
        if extra_env:
            env.update(extra_env)
        args = [sys.executable, str(HERE / "owner-lease-recover.py"),
                "--label", "cli-stuck", "--project", PROJ,
                "--new-lifecycle-end", str(new_end), "--pane-id", P2, "--pane-birth", B2,
                "--confirm-form", confirm_form]
        if apply:
            args.append("--apply")
        p = subprocess.run(args, capture_output=True, text=True, timeout=30, env=env)
        return p.returncode, p.stdout.strip()

    write_form("good", status="answered", answers={"decision": "approve", "label": "cli-stuck",
                                                     "new_lifecycle_end_at": new_end,
                                                     "caller_pane_id": P2, "caller_pane_birth": B2})

    rc, out = run(writer=None)
    case("CLI: writer flag off -> refused:flags_off, exit 4", rc == 4 and out == "refused:flags_off")

    rc, out = run(confirm_form="missing-entirely")
    case("CLI: no such confirmation form -> refused:unconfirmed, exit 4",
         rc == 4 and out == "refused:unconfirmed:form_unreadable")

    rc, out = run()
    case("CLI: dry-run with a valid confirmation -> would_recover, exit 0, nothing written",
         rc == 0 and out == "dry-run:would_recover:cli-stuck")
    c = ol.connect(db_path)
    case("CLI: dry-run truly wrote nothing", row(c, "cli-stuck")[3] == "")
    c.close()

    rc, out = run(apply=True)
    case("CLI: --apply with a valid, exactly-bound confirmation -> recovered, exit 0, token printed once",
         rc == 0 and out.startswith("apply:recovered:cli-stuck:") and len(out.split(":")[-1]) == 64)
    c = ol.connect(db_path)
    row_after = row(c, "cli-stuck")
    case("CLI: --apply actually advanced the row", row_after[2] == ol._iso(new_end) and row_after[3] != "")
    c.close()

    rc, out = run(apply=True)
    case("CLI: replaying the SAME confirmation after a successful apply -> not_expired, exit 0, no second token",
         rc == 0 and out == "apply:not_expired:cli-stuck")


def _live_forms_snapshot() -> dict:
    """Name -> mtime_ns for every file under the REAL (never test-overridden)
    ~/.local/state/herdr/forms -- read-only, used only to prove this suite
    (which always passes its own HERDR_STATE_ROOT to every subprocess and
    temporarily rebinds os.environ for in-process calls, restoring it in a
    finally) never reads or writes that directory by accident. Missing dir
    -> empty snapshot, not an error."""
    live = Path.home() / ".local/state/herdr/forms"
    if not live.is_dir():
        return {}
    return {p.name: p.stat().st_mtime_ns for p in live.iterdir()}


if __name__ == "__main__":
    before_live = _live_forms_snapshot()
    rc = main()
    after_live = _live_forms_snapshot()
    if after_live != before_live:
        added = sorted(set(after_live) - set(before_live))
        changed = sorted(n for n in (set(after_live) & set(before_live)) if after_live[n] != before_live[n])
        print(f"FAIL live forms dir changed during this run -- added={added} changed={changed} "
              f"(this suite must only ever touch its own HERDR_STATE_ROOT)")
        rc = 1
    sys.exit(rc)
