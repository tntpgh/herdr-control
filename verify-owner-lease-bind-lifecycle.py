#!/usr/bin/env python3
"""verify-owner-lease-bind-lifecycle.py — offline proofs for
lib/owner_lease_recover.bind_missing_lifecycle() and its CLI,
owner-lease-bind-lifecycle.py: the companion recovery path for a REGISTERED
label whose lifecycle_end_at was never set at all (the exact knowledge-base
incident -- owner-register.py reported "registered" but the bound stayed
NULL, so neither owner_lease_renew.renew_due() nor owner-lease-recover.py
("no_lifecycle_bound", refused on purpose) nor owner-lease-reregister.py
("not_unregistered", refused on purpose) could ever move the row).

Every fixture DB is under a mktemp dir, every forms dir is under a mktemp
HERDR_STATE_ROOT, never ~/.local/state/herdr."""
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

spec = importlib.util.spec_from_file_location("olbind_cli", HERE / "owner-lease-bind-lifecycle.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

FAILS: list[str] = []
T0 = 1_900_000_000.0
P1, B1 = "w1:p1", "term_aaa"
P2, B2 = "w1:p2", "term_bbb"
PROJ = "tntpgh/unbound-project"


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


def unbound_label(conn, label="unbound", project=PROJ, now=T0 - 100_000):
    """The exact bug fixture: registered, NULL lifecycle_end_at, empty token --
    owner-register.py reported "registered" and nothing else ever bound it."""
    ol.register_owner(conn, label, project, now=now)
    return label


def _raises(fn):
    try:
        fn()
    except Exception as exc:  # noqa: BLE001
        return exc
    return None


def main():
    # --- wrong owner/label ---
    path = scratch()
    c = ol.connect(path)
    unbound_label(c)
    case("wrong label: no such owner_projects row -> InvalidOwner",
         isinstance(_raises(lambda: olrec.bind_missing_lifecycle(
             c, "no-such-label", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)), ol.InvalidOwner))
    case("wrong project for a real label -> InvalidOwner",
         isinstance(_raises(lambda: olrec.bind_missing_lifecycle(
             c, "unbound", "tntpgh/some-other-project", T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)),
             ol.InvalidOwner))

    # --- excessive TTL / invalid bound ---
    case("new bound > MAX_TTL_S past now -> ValueError, rejected",
         isinstance(_raises(lambda: olrec.bind_missing_lifecycle(
             c, "unbound", PROJ, T0 + ol.MAX_TTL_S + 1, P2, B2, "form-1", now=T0, dry_run=True)), ValueError))
    case("new bound in the past -> ValueError, rejected",
         isinstance(_raises(lambda: olrec.bind_missing_lifecycle(
             c, "unbound", PROJ, T0 - 1, P2, B2, "form-1", now=T0, dry_run=True)), ValueError))
    case("missing confirmation_ref -> ValueError, rejected",
         isinstance(_raises(lambda: olrec.bind_missing_lifecycle(
             c, "unbound", PROJ, T0 + 3600, P2, B2, "", now=T0, dry_run=True)), ValueError))

    # --- disabled state: owner_state.enabled != 1 refuses, in BOTH modes ---
    ol.disable(c, now=T0)
    case("disabled (owner_state.enabled != 1): dry-run refuses too, not a false would_bind",
         isinstance(_raises(lambda: olrec.bind_missing_lifecycle(
             c, "unbound", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)), ol.Disabled))
    case("disabled: --apply refuses identically",
         isinstance(_raises(lambda: olrec.bind_missing_lifecycle(
             c, "unbound", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=False)), ol.Disabled))
    c.execute("UPDATE owner_state SET enabled=1 WHERE id=1")
    c.execute("COMMIT") if c.in_transaction else None
    c.close()

    # --- unregistered labels: refused, directed at reregister, not this path ---
    c = ol.connect(path)
    ol.register_owner(c, "gone", PROJ + "-gone", now=T0 - 100_000, lifecycle_end_at=T0 - 1000,
                      unregister_token="tok-gone")
    case("fixture: unregister_owner succeeds (token present)",
         ol.unregister_owner(c, "gone", "tok-gone", now=T0 - 500, dry_run=False) == "unregistered")
    case("unregistered label -> InvalidOwner, never bound here",
         isinstance(_raises(lambda: olrec.bind_missing_lifecycle(
             c, "gone", PROJ + "-gone", T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)), ol.InvalidOwner))

    # --- already-bound label: mutual exclusivity with recover_lifecycle() --
    # this path is NEVER a second way to move an existing bound, expired or not.
    ol.register_owner(c, "already", "tntpgh/already", now=T0 - 100_000, lifecycle_end_at=T0 + 100_000,
                      unregister_token="")
    case("already has a (future) bound -> already_bound, not an exception",
         olrec.bind_missing_lifecycle(c, "already", "tntpgh/already", T0 + 3600, P2, B2, "form-1",
                                      now=T0, dry_run=True) == ("already_bound", None))
    ol.register_owner(c, "already-expired", "tntpgh/already-expired", now=T0 - 100_000,
                      lifecycle_end_at=T0 - 1000, unregister_token="")
    case("already has a (PASSED) bound -> still already_bound here, that is recover_lifecycle's job",
         olrec.bind_missing_lifecycle(c, "already-expired", "tntpgh/already-expired", T0 + 3600, P2, B2,
                                      "form-1", now=T0, dry_run=True) == ("already_bound", None))

    # --- never self-extension: a label with NULL lifecycle can still have a
    # LIVE lease (acquire()/claim never consult the bound) -- the caller
    # being that exact holder is refused; a DIFFERENT caller is not. ---
    ol.register_owner(c, "held", "tntpgh/held", now=T0 - 100_000)
    ol.acquire(c, "held", P1, B1, 50_000, now=T0 - 2000, session_digest="a" * 64)
    case("fixture: 'held' has NULL lifecycle yet still has a live lease",
         ol.holder_tuple(c, "held", T0) == (P1, B1, "a" * 64, 1))
    case("self-extension: the live holder calling for itself is refused",
         isinstance(_raises(lambda: olrec.bind_missing_lifecycle(
             c, "held", "tntpgh/held", T0 + 3600, P1, B1, "form-1", now=T0, dry_run=True)), ol.Unauthorized))
    case("self-extension: a DIFFERENT caller is NOT refused on that ground (still would_bind)",
         olrec.bind_missing_lifecycle(c, "held", "tntpgh/held", T0 + 3600, P2, B2, "form-1",
                                      now=T0, dry_run=True) == ("would_bind", None))
    c.close()

    # --- interrupted bind: a crash between the UPDATE and the audit event
    # must leave the row completely unchanged. ---
    c = ol.connect(path)
    before = row(c, "unbound")
    with mock.patch.object(ol, "_event", side_effect=RuntimeError("simulated crash mid-tx")):
        try:
            olrec.bind_missing_lifecycle(c, "unbound", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=False)
            crashed = False
        except RuntimeError:
            crashed = True
    case("interrupted bind: the simulated crash actually propagated", crashed)
    case("interrupted bind: the row is BYTE-IDENTICAL to before the crash (rolled back)",
         row(c, "unbound") == before)
    case("interrupted bind: no lifecycle_bound event was written",
         c.execute("SELECT COUNT(*) FROM owner_events WHERE label='unbound' AND kind='lifecycle_bound'"
                   ).fetchone()[0] == 0)

    # --- happy path ---
    dry = olrec.bind_missing_lifecycle(c, "unbound", PROJ, T0 + 3600, P2, B2, "form-1", now=T0, dry_run=True)
    case("happy path: dry-run reports would_bind, no token, row untouched",
         dry == ("would_bind", None) and row(c, "unbound") == before)
    status, token = olrec.bind_missing_lifecycle(c, "unbound", PROJ, T0 + 3600, P2, B2, "form-1", now=T0,
                                                  dry_run=False)
    case("happy path: --apply binds and mints NO token (narrower than recover_lifecycle)",
         status == "bound" and token is None)
    after = row(c, "unbound")
    case("happy path: lifecycle_end_at is now set to exactly the new bound",
         after[2] == ol._iso(T0 + 3600))
    case("happy path: unregister_token is UNTOUCHED (still NULL, exactly as before)",
         after[3] == before[3] is None)
    case("happy path: exactly one lifecycle_bound event, carrying the confirmation ref",
         [r for r in c.execute("SELECT ref FROM owner_events WHERE label='unbound' AND kind='lifecycle_bound'"
                               ).fetchall()] == [("form-1",)])

    # --- replayed confirmation: the SAME confirmation/params, immediately
    # replayed, is refused -- the row this call already bound now reads back
    # as already_bound, never a second grant. ---
    replay = olrec.bind_missing_lifecycle(c, "unbound", PROJ, T0 + 7200, P2, B2, "form-1", now=T0, dry_run=False)
    case("replayed confirmation: refused as already_bound, not a second bind",
         replay == ("already_bound", None))
    case("replayed confirmation: the row still holds the FIRST bind's value, untouched by the replay",
         row(c, "unbound")[2] == ol._iso(T0 + 3600))
    c.close()

    # --- race_lost: two concurrent binds of the SAME unbound label; the
    # second writer to commit wins, the first (which read a now-stale pair)
    # loses the CAS and reports race_lost, writing nothing. ---
    path_r = scratch()
    cr = ol.connect(path_r)
    unbound_label(cr, label="race")
    cr2 = ol.connect(path_r)
    real_tx = ol._tx
    spying = {"armed": True}

    def spying_tx(conn, fn, mutation=True):
        if spying["armed"] and conn is cr:
            spying["armed"] = False
            spying["b_result"] = olrec.bind_missing_lifecycle(cr2, "race", PROJ, T0 + 5000, P2, B2, "form-B",
                                                               now=T0, dry_run=False)
        return real_tx(conn, fn, mutation=mutation)

    ol._tx = spying_tx
    try:
        a_result = olrec.bind_missing_lifecycle(cr, "race", PROJ, T0 + 3600, P2, B2, "form-A", now=T0, dry_run=False)
    finally:
        ol._tx = real_tx
    final_row = row(cr, "race")
    case("race: interleaved caller B (landed first) reports bound",
         spying["b_result"] == ("bound", None))
    case("race: caller A (lost the CAS) reports race_lost, writes nothing",
         a_result == ("race_lost", None))
    case("race: the row holds B's bound, not A's",
         final_row[2] == ol._iso(T0 + 5000))
    case("race: exactly ONE lifecycle_bound event, not two",
         cr.execute("SELECT COUNT(*) FROM owner_events WHERE label='race' AND kind='lifecycle_bound'"
                   ).fetchone()[0] == 1)
    cr.close(); cr2.close()

    # ================= CLI: owner-lease-bind-lifecycle.py =================
    cli_env_cases()

    return 1 if FAILS else 0


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
             cli.read_confirmation("nope", "lab", "tntpgh/lab", 123.0) == "form_unreadable")
        case("read_confirmation: path traversal in form id -> invalid_form_id, never opened",
             cli.read_confirmation("../../etc/passwd", "lab", "tntpgh/lab", 123.0) == "invalid_form_id")
        write_form("f1", status="open", answers={})
        case("read_confirmation: not yet answered -> form_not_answered",
             cli.read_confirmation("f1", "lab", "tntpgh/lab", 123.0) == "form_not_answered")
        write_form("f2", status="answered", answers={"decision": "hold", "label": "lab",
                                                       "project": "tntpgh/lab", "lifecycle_end_at": 123.0})
        case("read_confirmation: answered but held -> form_not_approved",
             cli.read_confirmation("f2", "lab", "tntpgh/lab", 123.0) == "form_not_approved")
        write_form("f3", status="answered", answers={"decision": "approve", "label": "WRONG",
                                                       "project": "tntpgh/lab", "lifecycle_end_at": 123.0})
        case("read_confirmation: approved for a different label -> form_label_mismatch",
             cli.read_confirmation("f3", "lab", "tntpgh/lab", 123.0) == "form_label_mismatch")
        write_form("f4", status="answered", answers={"decision": "approve", "label": "lab",
                                                       "project": "tntpgh/OTHER", "lifecycle_end_at": 123.0})
        case("read_confirmation: approved for a different project -> form_project_mismatch",
             cli.read_confirmation("f4", "lab", "tntpgh/lab", 123.0) == "form_project_mismatch")
        write_form("f5", status="answered", answers={"decision": "approve", "label": "lab",
                                                       "project": "tntpgh/lab", "lifecycle_end_at": 999999.0})
        case("read_confirmation: approved for a different bound -> form_bound_mismatch",
             cli.read_confirmation("f5", "lab", "tntpgh/lab", 123.0) == "form_bound_mismatch")
        write_form("f6", status="answered", answers={"decision": "approve", "label": "lab",
                                                       "project": "tntpgh/lab", "lifecycle_end_at": 123.4})
        case("read_confirmation: exactly bound, approved -> None (valid)",
             cli.read_confirmation("f6", "lab", "tntpgh/lab", 123.0) is None)
    finally:
        if old_env is None:
            os.environ.pop("HERDR_STATE_ROOT", None)
        else:
            os.environ["HERDR_STATE_ROOT"] = old_env

    # --- full CLI process: flags_off, unconfirmed, dry-run, --apply ---
    # The CLI calls bind_missing_lifecycle(now=time.time()) -- REAL wall
    # clock, not this file's fictional T0.
    real_now = time.time()
    db_path = scratch()
    c = ol.connect(db_path)
    unbound_label(c, label="cli-unbound", project="tntpgh/cli-unbound", now=real_now - 100_000)
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
        args = [sys.executable, str(HERE / "owner-lease-bind-lifecycle.py"),
                "--label", "cli-unbound", "--project", "tntpgh/cli-unbound",
                "--lifecycle-end", str(new_end), "--pane-id", P2, "--pane-birth", B2,
                "--confirm-form", confirm_form]
        if apply:
            args.append("--apply")
        p = subprocess.run(args, capture_output=True, text=True, timeout=30, env=env)
        return p.returncode, p.stdout.strip()

    write_form("good", status="answered", answers={"decision": "approve", "label": "cli-unbound",
                                                     "project": "tntpgh/cli-unbound",
                                                     "lifecycle_end_at": new_end})

    rc, out = run(writer=None)
    case("CLI: writer flag off -> refused:flags_off, exit 4", rc == 4 and out == "refused:flags_off")

    rc, out = run(confirm_form="missing-entirely")
    case("CLI: no such confirmation form -> refused:unconfirmed, exit 4",
         rc == 4 and out == "refused:unconfirmed:form_unreadable")

    rc, out = run()
    case("CLI: dry-run with a valid confirmation -> would_bind, exit 0, nothing written",
         rc == 0 and out == "dry-run:would_bind:cli-unbound")
    c = ol.connect(db_path)
    case("CLI: dry-run truly wrote nothing", row(c, "cli-unbound")[2] is None)
    c.close()

    rc, out = run(apply=True)
    case("CLI: --apply with a valid, exactly-bound confirmation -> bound, exit 0",
         rc == 0 and out == "apply:bound:cli-unbound")
    c = ol.connect(db_path)
    row_after = row(c, "cli-unbound")
    case("CLI: --apply actually bound the row, token still untouched (empty)",
         row_after[2] == ol._iso(new_end) and row_after[3] is None)
    c.close()

    rc, out = run(apply=True)
    case("CLI: replaying the SAME confirmation after a successful apply -> already_bound, exit 0, no second write",
         rc == 0 and out == "apply:already_bound:cli-unbound")


def _live_forms_snapshot() -> dict:
    """Name -> mtime_ns for every file under the REAL (never test-overridden)
    ~/.local/state/herdr/forms -- read-only, used only to prove this suite
    never reads or writes that directory by accident. Missing dir -> empty
    snapshot, not an error."""
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
