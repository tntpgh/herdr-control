#!/usr/bin/env python3
"""Offline proofs for remote-mcp/ra-sender.py: the split-out RA send agent
(tmp/in/BRIEF-optC.md, Option C). No network, no real herdr, no launchd --
delivery goes to a fake herdr-deliver that records its argv.

These cases used to live in verify-owner-dispatch.py's publisher_tick_cases,
testing remote-mcp/publisher.py's result_availability_tick() directly; that
function is now observe-only (see its own test there, and remote-mcp/
verify-publisher.py), and the actual notify/budget/crash/alert behaviour
moved here, onto ra-sender.send_tick().

    python3 remote-mcp/verify-ra-sender.py
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / "lib"))
sys.path.insert(0, str(HERE))
import owner_dispatch as od  # noqa: E402
import owner_lease as ol  # noqa: E402
import owner_lease_delivery as old  # noqa: E402
import owner_dispatch_auth as oda  # noqa: E402
import result_availability as ra  # noqa: E402

FAILS: list[str] = []
TTL = 3600
KB, COND = "knowledge-base", "conductor"
PANE = {KB: ("w93:p2", "term_kb1"), COND: ("w72:p1", "term_cond")}
SESS_RAW = {KB: b"kb-session-1", COND: b"cond-session-1"}


def case(name, ok):
    print(("OK   " if ok else "FAIL ") + name)
    if not ok:
        FAILS.append(name)


def auto_auth(path):
    """TEST FIXTURE for cases about something else: issues a grant for
    exactly the call's arguments into a disposable store, then consumes it
    through the real oda.consume() -- same helper as verify-owner-dispatch.py."""
    import sqlite3
    import uuid
    conn = sqlite3.connect(str(path), isolation_level=None, timeout=10)
    oda.migrate(conn)

    def authorize(label, project, holder, rid, sha, manifest, now):
        aid = uuid.uuid4().hex
        pane, birth, sess, gen = holder
        conn.execute("INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,"
                     "session_digest,lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,"
                     "status,decided_at,expires_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'granted',"
                     "'2026-10-22T00:00:00Z',?)",
                     (aid, oda.PROTOCOL, label, project, pane, birth, sess, gen, rid, sha,
                      oda.manifest_key(manifest), "fixture-prompt", "fixture-approval", now + 3600))
        return oda.consume(conn, aid, label=label, project=project, holder=holder, request_id=rid,
                           body_sha256=sha, manifest=manifest, now=now)
    return authorize


def load_ra_sender():
    spec = importlib.util.spec_from_file_location("ra_sender_under_test", HERE / "ra-sender.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fixture(base: Path):
    """Shared world: a KB owner that dispatches work, a conductor owner RA
    notifies, both leased and registered. Returns (lc, av, d, auto, typed,
    fake_deliver, env) -- caller installs env and loads ra-sender fresh."""
    root, J = base / "kb_root", base / "journal"
    root.mkdir(); J.mkdir()
    lease_db = str(base / "lease.db")
    lc = ol.connect(lease_db); ol.migrate(lc)
    now = time.time()
    ol.register_owner(lc, KB, "tntpgh/knowledge-base", max_open=10, now=now)
    ol.register_owner(lc, COND, "tntpgh/thurber-os", max_open=10, now=now)
    av = ra.Availability(str(base / "ra.db"), {KB: str(root)}, str(J))
    typed = base / "typed.log"
    fake = base / "fake-deliver.sh"
    fake.write_text(f'#!/bin/sh\nprintf "%s|%s\\n" "$1" "$2" >> {typed}\n')
    fake.chmod(0o700)
    env = {"HERDR_OWNER_LEASE_DELIVERY": "1", "HERDR_OWNER_LEASE_DB": lease_db,
           "HERDR_RESULT_AVAILABILITY_DB": str(base / "ra.db"),
           "HERDR_RESULT_AVAILABILITY_ROOTS": f"{KB}={root}", "HERDR_RESULT_AVAILABILITY_JOURNAL": str(J),
           "HERDR_RESULT_AVAILABILITY": "1", "HERDR_DELIVER": str(fake),
           # 2026-10-29 defect: without this override ra-sender.py's ALERTS
           # falls back to pub.STATE/"remote-mcp" -- pub.STATE reads
           # HERDR_STATE_DIR, which this fixture does NOT set (it has no
           # reason to touch the publisher's state root at all), so alert()
           # wrote 3 real rows into the LIVE
           # ~/.local/state/herdr/remote-mcp/ra-sender-alerts.jsonl. Explicit
           # injection here, plus LIVE_ALERTS snapshot-asserted untouched
           # below, is the regression test for that.
           "HERDR_RA_SENDER_ALERTS": str(base / "ra-sender-alerts.jsonl")}
    return lc, av, lease_db, root, typed, fake, env


def _snapshot(p: Path):
    """stat+content snapshot, or None if the file does not exist -- used to
    PROVE the real, live ra-sender-alerts.jsonl is never touched by this
    offline suite, regardless of what HERDR_STATE_DIR happens to resolve to."""
    try:
        return p.stat().st_mtime_ns, p.read_bytes()
    except FileNotFoundError:
        return None


def main() -> int:
    import tempfile
    live_alerts = Path.home() / ".local/state/herdr/remote-mcp/ra-sender-alerts.jsonl"
    live_before = _snapshot(live_alerts)
    base = Path(os.path.realpath(tempfile.mkdtemp()))
    lc, av, lease_db, root, typed, fake, env = fixture(base)
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        rs = load_ra_sender()
        rows = {KB: {"pane_id": PANE[KB][0], "pane_birth": PANE[KB][1], "agent_session": "kb-sess"},
                COND: {"pane_id": PANE[COND][0], "pane_birth": PANE[COND][1], "agent_session": "cond-sess"}}
        rs.pub.registry_owners = lambda: {k: dict(v, workspace="", registered_at="", updated_at="") for k, v in rows.items()}
        rs.pub.DELIVER = str(fake)
        kb_digest = rs.pub.owner_session_digest(KB, rows[KB])
        cond_digest = rs.pub.owner_session_digest(COND, rows[COND])
        ol.acquire(lc, KB, *PANE[KB], TTL, time.time(), session_digest=kb_digest)
        d = od.Dispatcher(old.DeliveryGate(lease_db), av, lambda l, h, t: True, rs.pub.registry_resolver,
                          authorize=auto_auth(base / "auth.db"))

        # advance pending->observing->staged using the REAL publisher tick
        # (observe-only now, but still the shared state machine): import it
        # fresh so it shares nothing with rs beyond the same env/DB files.
        pub_spec = importlib.util.spec_from_file_location("publisher_for_ra_sender_test", HERE / "publisher.py")
        pub = importlib.util.module_from_spec(pub_spec); pub_spec.loader.exec_module(pub)
        pub.registry_owners = rs.pub.registry_owners

        def stage_rid(rid):
            assert d.dispatch(KB, rid, f"REQ {rid}\n".encode(), ["result.md"]) == "dispatched"
            (root / rid / "result.md").write_text(f"ACK {rid}")
            pub.result_availability_tick(); pub.result_availability_tick()
            row = av.conn.execute("SELECT observed, request_dir FROM ra_requests WHERE rid=?", (rid,)).fetchone()
            return ra.notice_text(rid, row[0], row[1])

        os.environ.pop("HERDR_RESULT_AVAILABILITY")
        case("SEND default off: no flag -> None, nothing typed", rs.send_tick() is None and not typed.exists())
        os.environ["HERDR_RESULT_AVAILABILITY"] = "1"

        gate = old.DeliveryGate(lease_db)
        xid = ra.GatedNotice.exchange_id

        t1 = stage_rid("r_send1")
        case("SEND no conductor lease: held pre-send, row stays staged, nothing typed, no gate row",
             rs.send_tick() == {"r_send1": "held:not_dispatched:conductor_identity_gone"} and av.state("r_send1")[0] == "staged"
             and not typed.exists() and lc.execute("SELECT count(*) FROM owner_requests WHERE label=?", (COND,)).fetchone()[0] == 0)

        ol.acquire(lc, COND, *PANE[COND], TTL, time.time(), session_digest=cond_digest)

        # RACE: ready/prepare saw the conductor, identity gone at the typing boundary.
        real_resolver, calls = rs.pub.registry_resolver, {"n": 0}

        def flaky(label):
            if label == COND:
                calls["n"] += 1
                if calls["n"] > 1:
                    return None
            return real_resolver(label)
        rs.pub.registry_resolver = flaky
        out = rs.send_tick()
        rs.pub.registry_resolver = real_resolver
        case("RACE identity gone at the boundary: pre-send held, row staged (never notifying/ambiguous), nothing typed",
             out == {"r_send1": "held:not_dispatched:identity_changed_pre_send"} and av.state("r_send1")[0] == "staged"
             and not typed.exists() and gate.record(xid(t1))[2:] == ("blocked", "identity_changed_pre_send"))
        case("RACE: the blocked notice is never re-admitted (no resend grant)",
             rs.send_tick()["r_send1"] == "held:not_dispatched:owner_lease_duplicate:blocked" and not typed.exists())

        t2 = stage_rid("r_send2")
        out = rs.send_tick()
        lines = typed.read_text().splitlines() if typed.exists() else []
        case("SEND registered conductor: notified through the gate, exactly one notice, body-bound exchange id delivering",
             out["r_send2"] == "notified" and len(lines) == 1 and lines[0] == f"{PANE[COND][0]}|{t2}"
             and gate.record(xid(t2))[:3] == (COND, gate.record(xid(t2))[1], "delivering")
             and "r_send2" not in rs.send_tick())

        t3 = stage_rid("r_send3")
        bad = base / "fail-deliver.sh"
        bad.write_text("#!/bin/sh\nexit 1\n"); bad.chmod(0o700)
        rs.pub.DELIVER = str(bad)
        out = rs.send_tick()
        rs.pub.DELIVER = str(fake)
        alerts_before = rs.ALERTS.read_text().splitlines() if rs.ALERTS.exists() else []
        case("POST-SEND failure: ambiguous, gate blocked send_not_confirmed (not retryable), ALERT written",
             out["r_send3"] == "ambiguous" and gate.record(xid(t3))[2:] == ("blocked", "send_not_confirmed")
             and len(alerts_before) == 1 and '"outcome":"ambiguous"' in alerts_before[0] and '"r_send3"' in alerts_before[0])

        t4 = stage_rid("r_send4")

        class Crash(BaseException):
            pass
        real_prepare = ra.GatedNotice.prepare

        def crash_after_prepare(self, rid, text, **kw):
            r = real_prepare(self, rid, text, **kw)
            if rid != "r_send4":
                return r
            raise Crash()  # killed after begin_notice, before the notifying CAS
        ra.GatedNotice.prepare = crash_after_prepare
        try:
            rs.send_tick()
        except Crash:
            pass
        finally:
            ra.GatedNotice.prepare = real_prepare
        out = rs.send_tick()
        case("CRASH mid-send after begin_notice: row stays staged, gate delivering, next run holds duplicate, never typed twice",
             out["r_send4"] == "held:not_dispatched:owner_lease_duplicate:delivering" and av.state("r_send4")[0] == "staged"
             and gate.record(xid(t4))[2] == "delivering" and len(typed.read_text().splitlines()) == 1)

        # BUDGET: two requests both ready in the same run -> exactly one send.
        assert d.dispatch(KB, "r_budget_a", b"REQ budget a\n", ["result.md"]) == "dispatched"
        assert d.dispatch(KB, "r_budget_b", b"REQ budget b\n", ["result.md"]) == "dispatched"
        (root / "r_budget_a" / "result.md").write_text("ACK budget a")
        (root / "r_budget_b" / "result.md").write_text("ACK budget b")
        pub.result_availability_tick(); pub.result_availability_tick()
        case("BUDGET: both requests reach staged before the shared run",
             av.state("r_budget_a")[0] == "staged" and av.state("r_budget_b")[0] == "staged")
        before = len(typed.read_text().splitlines())
        out = rs.send_tick()
        case("BUDGET: one run with two ready rows notifies exactly ONE, exactly one new typed line",
             out["r_budget_a"] == "notified" and out["r_budget_b"] == "held:not_dispatched:rate_limited_one_notice_per_tick"
             and len(typed.read_text().splitlines()) == before + 1 and av.state("r_budget_b")[0] == "staged")
        out2 = rs.send_tick()
        case("BUDGET: the deferred row is sent on the very next run, nothing lost",
             out2["r_budget_b"] == "notified" and len(typed.read_text().splitlines()) == before + 2)

        live_after = _snapshot(live_alerts)
        case("LIVE STATE: the real ~/.local/state/herdr/remote-mcp/ra-sender-alerts.jsonl is byte-for-byte untouched "
             "(this suite forced HERDR_RA_SENDER_ALERTS to a disposable tmp path and generated real ALERT rows)",
             live_after == live_before and rs.ALERTS != live_alerts)
        gate.close()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        lc.close()
        av.close()

    print(f"PASS: {len(FAILS)} failing")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
