#!/usr/bin/env python3
"""Offline scratch proofs for lib/result_availability.py. No live registry,
pane, network or herdr call: the lease holder and the notice sender are fakes."""
from __future__ import annotations

import os
import sqlite3
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import result_availability as ra  # noqa: E402

FAILS: list[str] = []
T0 = 1_800_000_000.0
OWNER = ("pane-1", "birth-1", "sess-1", 3)


def case(name, ok):
    print(("OK   " if ok else "FAIL ") + name)
    if not ok:
        FAILS.append(name)


def raises_db(fn):
    try:
        fn()
    except sqlite3.DatabaseError:
        return True
    return False


def raises(fn):
    try:
        fn()
    except ra.Refused:
        return True
    return False


class Notices:
    def __init__(self, result=True):
        self.sent, self.result = [], result

    def __call__(self, text):
        self.sent.append(text)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def setup(root: Path, rid: str, req=b"REQ do the thing\n"):
    d = root / rid
    d.mkdir()
    (d / "request.txt").write_bytes(req)
    return d, req


def reg(av, rid, d, req, label, pane, birth, sess, gen, manifest, now):
    """A settled dispatch for exactly this binding (first write wins), then register."""
    j = Path(av.journal_root) / label / rid
    j.mkdir(parents=True, exist_ok=True)
    if not (j / ra.SETTLED_FILE).exists():
        (j / ra.SETTLED_FILE).write_bytes(ra.settled_record(rid, ra._sha(req), label, pane, birth, sess, gen, manifest))
    return av.register(rid, str(d), req, label, pane, birth, sess, gen, manifest, now)


def main() -> int:
    base = Path(os.path.realpath(tempfile.mkdtemp()))
    root = base / "rt"
    root.mkdir()
    JR = base / "journal"
    JR.mkdir()
    JR = str(JR)
    holder = lambda label: OWNER if label == "kb" else None  # noqa: E731

    # --- default off ---
    case("flag unset: from_env is None (no scan, no DB)",
         ra.from_env({"HERDR_RESULT_AVAILABILITY_DB": str(root / "x.db")}) is None and not (root / "x.db").exists())
    case("flag on without DB: refuses", raises(lambda: ra.from_env({"HERDR_RESULT_AVAILABILITY": "1"})))
    case("flag on without allowed roots: refuses", raises(lambda: ra.from_env(
        {"HERDR_RESULT_AVAILABILITY": "1", "HERDR_RESULT_AVAILABILITY_DB": str(base / "y.db")})))
    (base / "rootlink").symlink_to(root)
    case("symlinked allowed root: refused", raises(lambda: ra.Availability(str(base / "z.db"), {"kb": str(base / "rootlink")}, JR)))
    DB = str(base / "ra.db")
    a = ra.Availability(DB, {"kb": str(root)}, JR)

    # --- binding ---
    d, req = setup(root, "kbreq_ok")
    case("register binds request digest + owner + manifest",
         reg(a, "kbreq_ok", str(d), req, "kb", *OWNER, ["result.md", "run.out"], T0) == "registered")
    case("same binding again is idempotent",
         reg(a, "kbreq_ok", str(d), req, "kb", *OWNER, ["run.out", "result.md"], T0) == "already_registered")
    case("same id, changed request text: refused (no inherited binding)",
         raises(lambda: reg(a, "kbreq_ok", str(d), b"other", "kb", *OWNER, ["result.md"], T0)))
    case("same id, different owner generation: refused",
         raises(lambda: reg(a, "kbreq_ok", str(d), req, "kb", "pane-1", "birth-1", "sess-1", 4, ["result.md", "run.out"], T0)))
    case("same id, different session_id: refused",
         raises(lambda: reg(a, "kbreq_ok", str(d), req, "kb", "pane-1", "birth-1", "sess-2", 3, ["result.md", "run.out"], T0)))
    d2, req2 = setup(root, "kbreq_mm")
    case("dispatched text != request.txt on disk: refused",
         raises(lambda: reg(a, "kbreq_mm", str(d2), b"something else", "kb", *OWNER, ["result.md"], T0)))
    case("missing owner identity: refused",
         raises(lambda: reg(a, "kbreq_mm", str(d2), req2, "kb", "", "birth-1", "sess-1", 3, ["result.md"], T0)))
    case("missing session_id: refused",
         raises(lambda: reg(a, "kbreq_mm", str(d2), req2, "kb", "pane-1", "birth-1", "", 3, ["result.md"], T0)))
    other = base / "other"
    other.mkdir()
    (other / "kbreq_out").mkdir()
    (other / "kbreq_out" / "request.txt").write_bytes(req2)
    case("canonical dir OUTSIDE the allowed roots: refused",
         raises(lambda: reg(a, "kbreq_out", str(other / "kbreq_out"), req2, "kb", *OWNER, ["result.md"], T0)))
    (root / "nest").mkdir()
    (root / "nest" / "kbreq_deep").mkdir()
    (root / "nest" / "kbreq_deep" / "request.txt").write_bytes(req2)
    case("nested dir (not a direct child of a root): refused",
         raises(lambda: reg(a, "kbreq_deep", str(root / "nest" / "kbreq_deep"), req2, "kb", *OWNER, ["result.md"], T0)))
    case("non-normalized path (..) : refused",
         raises(lambda: reg(a, "kbreq_mm", str(root / "nest" / ".." / "kbreq_mm"), req2, "kb", *OWNER, ["result.md"], T0)))
    case("dir not named after rid: refused",
         raises(lambda: reg(a, "kbreq_zz", str(d2), req2, "kb", *OWNER, ["result.md"], T0)))
    for bad in (["../x"], ["a/b"], [".hidden"], ["request.txt"], [], [f"f{i}" for i in range(9)], ["a", "a"]):
        case(f"manifest {bad[:2]}…: refused", raises(lambda b=bad: reg(a, "kbreq_mm", str(d2), req2, "kb", *OWNER, b, T0)))
    link = root / "kbreq_ln"
    link.symlink_to(d2)
    case("symlinked request dir: refused",
         raises(lambda: reg(a, "kbreq_ln", str(link), req2, "kb", *OWNER, ["result.md"], T0)))
    # --- settled-dispatch binding, label roots, journal ---
    dn, rqn = setup(root, "kbreq_nojournal")
    case("no settled dispatch in the journal: refused",
         raises(lambda: a.register("kbreq_nojournal", str(dn), rqn, "kb", *OWNER, ["result.md"], T0)))
    jn = Path(JR) / "kb" / "kbreq_nojournal"
    jn.mkdir(parents=True)
    (jn / ra.SETTLED_FILE).write_bytes(ra.settled_record("kbreq_nojournal", ra._sha(rqn), "kb", *OWNER, ["other.md"]))
    case("settled dispatch for a different manifest: refused",
         raises(lambda: a.register("kbreq_nojournal", str(dn), rqn, "kb", *OWNER, ["result.md"], T0)))
    (jn / ra.SETTLED_FILE).unlink()
    (jn / ra.SETTLED_FILE).symlink_to(base / "x.json")
    (base / "x.json").write_bytes(ra.settled_record("kbreq_nojournal", ra._sha(rqn), "kb", *OWNER, ["result.md"]))
    case("symlinked settled journal file: refused",
         raises(lambda: a.register("kbreq_nojournal", str(dn), rqn, "kb", *OWNER, ["result.md"], T0)))
    dots = base / "dots_root"
    dots.mkdir()
    case("two labels sharing one root: refused",
         raises(lambda: ra.Availability(str(base / "s.db"), {"kb": str(root), "dots": str(root)}, JR)))
    case("journal root inside an owner root: refused",
         raises(lambda: ra.Availability(str(base / "s.db"), {"kb": str(base)}, JR)))
    a2 = ra.Availability(str(base / "two.db"), {"kb": str(root), "dots": str(dots)}, JR)
    dx, rqx = setup(root, "kbreq_cross")
    case("CROSS-LABEL: kb's dir registered for label dots: refused",
         raises(lambda: reg(a2, "kbreq_cross", dx, rqx, "dots", *OWNER, ["result.md"], T0)))
    a2.close()
    case("from_env: roots must be label=/abs/root pairs and a journal is required",
         raises(lambda: ra.from_env({"HERDR_RESULT_AVAILABILITY": "1", "HERDR_RESULT_AVAILABILITY_DB": DB,
                                     "HERDR_RESULT_AVAILABILITY_ROOTS": f"kb={root}"}))
         and raises(lambda: ra.from_env({"HERDR_RESULT_AVAILABILITY": "1", "HERDR_RESULT_AVAILABILITY_DB": DB,
                                         "HERDR_RESULT_AVAILABILITY_ROOTS": str(root),
                                         "HERDR_RESULT_AVAILABILITY_JOURNAL": JR})))
    case("unregistered (legacy) dir is unverified_held, never scanned",
         a.state("kbreq_legacy")[0] == "unverified_held" and ra.classify_unregistered(root) == "unverified_held")

    # --- happy path with stability, staging, notice ---
    n = Notices()
    case("nothing written yet: pending, no notice", a.tick(holder, n, T0 + 1)["kbreq_ok"] == "pending" and not n.sent)
    (d / "result.md").write_text("ACK kbreq_ok\nbody")
    case("partial manifest: still pending", a.tick(holder, n, T0 + 2)["kbreq_ok"] == "pending")
    (d / "run.out").write_text("log")
    case("first full observation: observing", a.tick(holder, n, T0 + 3)["kbreq_ok"] == "observing")
    (d / "run.out").write_text("log more")
    case("changed before stable: observing again (not staged)", a.tick(holder, n, T0 + 4)["kbreq_ok"] == "observing")
    case("stable across two ticks: staged", a.tick(holder, n, T0 + 5)["kbreq_ok"] == "staged" and not n.sent)
    case("staged -> notified with fixed text, once",
         a.tick(holder, n, T0 + 6)["kbreq_ok"] == "notified" and len(n.sent) == 1
         and n.sent[0].startswith("RESULT AVAILABLE (UNVERIFIED") and "body" not in n.sent[0] and "log" not in n.sent[0])
    case("duplicate tick after notice: no second notice", "kbreq_ok" not in a.tick(holder, n, T0 + 7) and len(n.sent) == 1)

    def staged(rid, req=b"REQ x\n", owner=OWNER):
        dd, rq = setup(root, rid, req)
        reg(a, rid, str(dd), rq, "kb", *owner, ["result.md"], T0)
        (dd / "result.md").write_text("r")
        a.tick(holder, Notices(), T0)
        a.tick(holder, Notices(), T0)
        assert a.state(rid)[0] == "staged", a.state(rid)
        return dd

    # --- changed content after staging ---
    dc = staged("kbreq_chg")
    (dc / "result.md").write_text("r2")
    n = Notices()
    case("CHANGED after staging: held:changed, no notice (no inherited observation)",
         a.tick(holder, n, T0 + 10)["kbreq_chg"] == "held:changed" and not n.sent)
    (dc / "result.md").write_text("r")
    case("held:changed is terminal even if reverted", "kbreq_chg" not in a.tick(holder, n, T0 + 11) and not n.sent)

    # --- request text changed after registration ---
    dq = staged("kbreq_req")
    (dq / "request.txt").write_text("tampered")
    case("request.txt changed: held:request_changed, no notice",
         a.tick(holder, n, T0 + 12)["kbreq_req"] == "held:request_changed" and not n.sent)

    # --- stale generation ---
    staged("kbreq_gen")
    newer = lambda label: ("pane-1", "birth-1", "sess-1", 4)  # noqa: E731
    case("lease moved to a new generation: held:stale_generation, no notice",
         a.tick(newer, n, T0 + 13)["kbreq_gen"] == "held:stale_generation" and not n.sent)
    staged("kbreq_sess")
    case("same generation, different session: held:stale_generation",
         a.tick(lambda label: ("pane-1", "birth-1", "sess-9", 3), n, T0 + 13.5)["kbreq_sess"] == "held:stale_generation"
         and not n.sent)
    staged("kbreq_gone")
    case("no lease holder: held:stale_generation",
         a.tick(lambda label: None, n, T0 + 14)["kbreq_gone"] == "held:stale_generation" and not n.sent)

    # --- settled journal changed after registration ---
    staged("kbreq_jchg")
    (Path(JR) / "kb" / "kbreq_jchg" / ra.SETTLED_FILE).write_bytes(b"{}\n")
    case("settled journal changed after registration: held:dispatch_changed, no notice",
         a.tick(holder, n, T0 + 14.5)["kbreq_jchg"] == "held:dispatch_changed" and not n.sent)

    # --- separate durable stages ---
    staged("kbreq_stage")
    case("staged records ONLY the observed stage", set(a.stages("kbreq_stage")) == {"observed"})
    pin = {"result.md": ra._sha(b"r")}
    case("accept before verify/authentication: refused", not a.accept("kbreq_stage", "conductor", T0))
    case("verify with a wrong pin: refused, nothing recorded",
         not a.verify_pinned("kbreq_stage", {"result.md": "0" * 64}, T0) and "verified" not in a.stages("kbreq_stage"))
    case("verify with pins not covering the manifest exactly: refused",
         not a.verify_pinned("kbreq_stage", {**pin, "extra.md": "0" * 64}, T0))
    case("verify with the caller's correct pins: verified", a.verify_pinned("kbreq_stage", pin, T0))
    case("verified alone does not allow accept (no authenticated reply)", not a.accept("kbreq_stage", "conductor", T0))
    case("authenticated reply needs a reference", not a.record_reply_authenticated("kbreq_stage", "", T0)
         and a.record_reply_authenticated("kbreq_stage", "oex_auth_ref", T0))
    a.tick(holder, Notices(), T0 + 14.6)
    case("notice is its own stage; accept is a separate conductor act",
         set(a.stages("kbreq_stage")) == {"observed", "noticed", "reply_authenticated", "verified"}
         and a.accept("kbreq_stage", "conductor", T0) and "accepted" in a.stages("kbreq_stage"))
    case("stages are append-only", raises_db(lambda: a.conn.execute("DELETE FROM ra_stages"))
         and raises_db(lambda: a.conn.execute("UPDATE ra_stages SET evidence='x'")))

    # --- symlinked artifact ---
    ds, rq = setup(root, "kbreq_sym")
    reg(a, "kbreq_sym", str(ds), rq, "kb", *OWNER, ["result.md"], T0)
    (base / "outside.md").write_text("secret")
    (ds / "result.md").symlink_to(base / "outside.md")
    a.tick(holder, n, T0 + 15)
    case("symlinked artifact never observed (stays pending)",
         a.tick(holder, n, T0 + 16)["kbreq_sym"] == "pending" and not n.sent)

    # --- crash boundaries ---
    staged("kbreq_pre")
    a.close()
    a = ra.Availability(DB, {"kb": str(root)}, JR)
    n = Notices()
    case("CRASH before notice boundary: staged survives restart and notifies once",
         a.tick(holder, n, T0 + 20)["kbreq_pre"] == "notified" and len(n.sent) == 1)
    staged("kbreq_mid")
    a.conn.execute("UPDATE ra_requests SET state='notifying' WHERE rid='kbreq_mid'")  # crash after the commit
    a.close()
    a = ra.Availability(DB, {"kb": str(root)}, JR)
    n = Notices()
    case("notifying younger than NOTIFY_TIMEOUT_S: left alone as in-flight (no notice, no verdict)",
         a.tick(holder, n, T0 + 21)["kbreq_mid"] == "in_flight" and not n.sent)
    case("CRASH after notifying commit (stale): ambiguous, never retried",
         a.tick(holder, n, T0 + ra.NOTIFY_TIMEOUT_S + 1)["kbreq_mid"] == "ambiguous" and not n.sent
         and "kbreq_mid" not in a.tick(holder, n, T0 + ra.NOTIFY_TIMEOUT_S + 2) and not n.sent)
    staged("kbreq_err")
    n = Notices(RuntimeError("deliver timed out"))
    case("notice raises: ambiguous, not retried",
         a.tick(holder, n, T0 + 23)["kbreq_err"] == "ambiguous" and len(n.sent) == 1
         and "kbreq_err" not in a.tick(holder, n, T0 + 24) and len(n.sent) == 1)
    staged("kbreq_ord")
    order = []
    def watch(text):
        order.append(a.conn.execute("SELECT state FROM ra_requests WHERE rid='kbreq_ord'").fetchone()[0])
        return True
    a.tick(holder, watch, T0 + 25)
    case("notifying is committed BEFORE the external call", order == ["notifying"]
         and sqlite3.connect(DB).execute(
             "SELECT state FROM ra_requests WHERE rid='kbreq_ord'").fetchone()[0] == "notified")

    # --- interruption clears the observation (non-consecutive must not stage) ---
    di, rq = setup(root, "kbreq_int")
    reg(a, "kbreq_int", str(di), rq, "kb", *OWNER, ["result.md"], T0)
    (di / "result.md").write_text("r")
    a.tick(holder, Notices(), T0 + 30)                 # observing
    (di / "result.md").unlink()
    a.tick(holder, Notices(), T0 + 31)                 # missing -> pending, observation cleared
    (di / "result.md").write_text("r")
    case("INTERRUPTED: same content after a missing tick is observing again, not staged",
         a.tick(holder, Notices(), T0 + 32)["kbreq_int"] == "observing" and a.state("kbreq_int")[0] == "observing")

    # --- ancestor symlink swap after registration ---
    dw, rq = setup(root, "kbreq_swap")
    reg(a, "kbreq_swap", str(dw), rq, "kb", *OWNER, ["result.md"], T0)
    evil = base / "evil" / "kbreq_swap"
    evil.mkdir(parents=True)
    (evil / "request.txt").write_bytes(rq)
    (evil / "result.md").write_text("forged")
    os.rename(dw, base / "moved_swap")
    os.symlink(evil, dw)
    case("REQUEST DIR swapped for a symlink after registration: never observed",
         a.tick(holder, Notices(), T0 + 33)["kbreq_swap"] == "held:request_changed")
    a.close()

    # --- multiprocess CAS race: one staged row, many concurrent tickers ---
    rr = base / "race"
    rr.mkdir()
    RDB = str(base / "race.db")
    b = ra.Availability(RDB, {"kb": str(rr)}, JR)
    dr, rq = setup(rr, "kbreq_race")
    reg(b, "kbreq_race", str(dr), rq, "kb", *OWNER, ["result.md"], T0)
    (dr / "result.md").write_text("r")
    b.tick(holder, Notices(), T0)
    b.tick(holder, Notices(), T0)
    b.close()
    log = base / "calls.log"
    import subprocess
    child = (
        "import sys,time,os;sys.path.insert(0,sys.argv[1]);import result_availability as ra\n"
        "a=ra.Availability(sys.argv[2],{'kb':sys.argv[3]},sys.argv[6])\n"
        "def n(t):\n open(sys.argv[4],'a').write('x\\n');time.sleep(0.2);return True\n"
        "while time.time()<float(sys.argv[5]):pass\n"
        "print(a.tick(lambda l:('pane-1','birth-1','sess-1',3),n,1.8e9+1).get('kbreq_race'))\n"
    )
    go = str(__import__("time").time() + 1.0)
    procs = [subprocess.Popen([sys.executable, "-c", child, str(HERE / "lib"), RDB, str(rr), str(log), go, JR],
                              stdout=subprocess.PIPE, text=True) for _ in range(8)]
    outs = [p.communicate()[0].strip() for p in procs]
    calls = log.read_text().count("x") if log.exists() else 0
    case(f"RACE: 8 concurrent tickers -> exactly one callback ({calls}; {sorted(set(outs))})",
         calls == 1 and outs.count("notified") == 1)

    print(f"{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failing")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
