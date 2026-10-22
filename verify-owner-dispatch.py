#!/usr/bin/env python3
"""Offline proofs for lib/owner_dispatch.py + owner_lease v3 + result_availability.

Disposable temp state only: temp sqlite DBs, temp roots, an injected fake
sender. No herdr, no pane, no network, no live registry. The two identities are
the labels of two EXISTING registered owners (knowledge-base, herdr-control-dots)
with fixture pane/session values; nothing is registered anywhere real."""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_dispatch as od  # noqa: E402
import owner_lease_delivery as old  # noqa: E402
import json  # noqa: E402
import owner_lease as ol  # noqa: E402
import result_availability as ra  # noqa: E402

FAILS: list[str] = []
T0 = 1_800_000_000.0
TTL = 3600
KB, DOTS = "knowledge-base", "herdr-control-dots"
SESS = {KB: hashlib.sha256(b"kb-session-1").hexdigest(), DOTS: hashlib.sha256(b"dots-session-1").hexdigest()}
PANE = {KB: ("w93:p2", "term_kb1"), DOTS: ("w4P:pE", "term_dots1")}


def case(name, ok):
    print(("OK   " if ok else "FAIL ") + name)
    if not ok:
        FAILS.append(name)


class Sender:
    def __init__(self, result=True):
        self.calls, self.result = [], result

    def __call__(self, label, holder, text):
        self.calls.append((label, holder, text))
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def env(base: Path):
    roots = {KB: base / "kb_root", DOTS: base / "dots_root"}
    for r in roots.values():
        r.mkdir()
    (base / "journal").mkdir()
    lease_db = str(base / "lease.db")
    lc = ol.connect(lease_db)
    ol.migrate(lc)
    ol.register_owner(lc, KB, "tntpgh/knowledge-base", now=T0)
    ol.register_owner(lc, DOTS, "tntpgh/dotfiles", now=T0)
    av = ra.Availability(str(base / "ra.db"), {k: str(v) for k, v in roots.items()}, str(base / "journal"))
    return lc, av, roots, lease_db


def acquire(lc, label, now=T0, session=None, pane=None):
    p, b = pane or PANE[label]
    return ol.acquire(lc, label, p, b, TTL, now, session_digest=SESS[label] if session is None else session)


def files(d: Path):
    return sorted(p.name for p in d.iterdir()) if d.exists() else None


def main() -> int:
    base = Path(os.path.realpath(tempfile.mkdtemp()))
    lc, av, roots, lease_db = env(base)
    J = base / "journal"
    REG = {KB: (*PANE[KB], SESS[KB]), DOTS: (*PANE[DOTS], SESS[DOTS])}
    G = {"gate": old.DeliveryGate(lease_db)}

    def mk(snd, reg=None, clock=None):
        return od.Dispatcher(G["gate"], av, snd, reg or REG.get, clock or (lambda: T0))

    # --- pre-send refusal is typed, writes nothing, sends nothing ---
    s = Sender()
    d = mk(s)
    case("no live lease: held:not_dispatched, nothing written, nothing sent",
         d.dispatch(KB, "r_nolease", b"REQ\n", ["result.md"], T0) == "held:not_dispatched:registry_lease_mismatch"
         and not s.calls and files(J / KB / "r_nolease") is None and files(roots[KB] / "r_nolease") is None)
    ol.acquire(lc, KB, *PANE[KB], TTL, T0)  # pre-v3 style lease: no session digest
    case("live lease WITHOUT a session digest: held:not_dispatched",
         d.dispatch(KB, "r_nosess", b"REQ\n", ["result.md"], T0) == "held:not_dispatched:registry_lease_mismatch"
         and not s.calls)
    case("unknown label (no own root): held:not_dispatched",
         d.dispatch("tourguide", "r_x", b"REQ\n", ["result.md"], T0) == "held:not_dispatched:label_has_no_root")

    # --- session digest is lease authority ---
    lc2_path = str(base / "lease2.db")
    lc2 = ol.connect(lc2_path)
    ol.migrate(lc2)
    ol.register_owner(lc2, KB, "tntpgh/knowledge-base", now=T0)
    acquire(lc2, KB)
    renew_other = False
    try:
        acquire(lc2, KB, T0 + 1, session=hashlib.sha256(b"other").hexdigest())
    except ol.LeaseConflict:
        renew_other = True
    case("SESSION CHANGE: same pane/birth, different session cannot renew (LeaseConflict)", renew_other)
    case("bad session digest rejected",
         isinstance(_raises(lambda: acquire(lc2, KB, T0 + 1, session="abc")), ValueError))
    case("holder_tuple carries the full session digest",
         ol.holder_tuple(lc2, KB, T0 + 2) == (*PANE[KB], SESS[KB], 1))
    lc2.close()

    # --- happy path, both identities ---
    lc.close()
    os.unlink(lease_db)
    lc = ol.connect(lease_db)
    ol.migrate(lc)
    G["gate"] = old.DeliveryGate(lease_db)
    # blocked requests stay OPEN in the real queue; room for this file's refusal cases
    ol.register_owner(lc, KB, "tntpgh/knowledge-base", max_open=20, now=T0)
    ol.register_owner(lc, DOTS, "tntpgh/dotfiles", now=T0)
    gk, gd = acquire(lc, KB), acquire(lc, DOTS)
    s = Sender()
    d = mk(s)
    case("dispatch KB: dispatched (settled journal, registered)",
         d.dispatch(KB, "r_kb1", b"REQ kb\n", ["result.md"], T0) == "dispatched"
         and files(J / KB / "r_kb1") == ["intent.json", "settled.json"]
         and av.state("r_kb1")[0] == "pending")
    case("journal files are 0600", all((os.stat(J / KB / "r_kb1" / f).st_mode & 0o777) == 0o600
                                       for f in ("intent.json", "settled.json")))
    case("dispatch DOTS into its own root: dispatched",
         d.dispatch(DOTS, "r_dots1", b"REQ dots\n", ["result.md"], T0) == "dispatched"
         and (roots[DOTS] / "r_dots1" / "request.txt").read_bytes() == b"REQ dots\n")
    case("sender got the exact holder tuple per label",
         [c[1] for c in s.calls] == [(*PANE[KB], SESS[KB], gk), (*PANE[DOTS], SESS[DOTS], gd)])

    case("bad manifest: refused before anything is written",
         d.dispatch(KB, "r_badman", b"REQ\n", ["../x"], T0) == "held:not_dispatched:bad_manifest"
         and files(J / KB / "r_badman") is None)

    # --- duplicate ---
    case("DUPLICATE rid: refused, sender not called again, journal unchanged",
         d.dispatch(KB, "r_kb1", b"REQ kb\n", ["result.md"], T0).startswith("held:not_dispatched:owner_lease_duplicate")
         and len(s.calls) == 2 and files(J / KB / "r_kb1") == ["intent.json", "settled.json"])
    (roots[KB] / "r_pre").mkdir()
    case("handoff dir already exists: refused with an immutable refused.json, no send",
         d.dispatch(KB, "r_pre", b"REQ\n", ["result.md"], T0) == "held:not_dispatched:handoff_dir_exists"
         and files(J / KB / "r_pre") == ["intent.json", "refused.json"] and len(s.calls) == 2)

    # --- cross-label ---
    case("CROSS-LABEL: a DOTS request never lands in KB's root",
         not (roots[KB] / "r_dots1").exists() and av.roots[DOTS] != av.roots[KB])
    case("CROSS-LABEL: registering KB's dir under DOTS is refused",
         isinstance(_raises(lambda: av.register("r_kb1", str(roots[KB] / "r_kb1"), b"REQ kb\n", DOTS,
                                                *PANE[DOTS], SESS[DOTS], gd, ["result.md"], T0)), ra.Refused))

    # --- uncertain send, crash ---
    d_err = mk(Sender(RuntimeError("deliver timed out")))
    case("send raises: ambiguous, uncertain.json, never registered",
         d_err.dispatch(KB, "r_err", b"REQ\n", ["result.md"], T0) == "ambiguous"
         and files(J / KB / "r_err") == ["intent.json", "uncertain.json"] and av.state("r_err")[0] == "unverified_held")
    case("send returns non-True: ambiguous", mk(Sender("yes")).dispatch(
        KB, "r_truthy", b"REQ\n", ["result.md"], T0) == "ambiguous")
    crash = J / KB / "r_crash"
    crash.mkdir()
    (crash / "intent.json").write_text("{}\n")
    s2 = Sender()
    out = mk(s2).recover(T0)
    case("CRASH (intent, no outcome): recover marks uncertain, no resend, no registration",
         out == {f"{KB}/r_crash": "ambiguous"} and files(crash) == ["intent.json", "uncertain.json"]
         and not s2.calls and av.state("r_crash")[0] == "unverified_held")
    case("recover is idempotent and never rewrites an outcome", mk(s2).recover(T0 + 1) == {})

    # --- fence moved between preflight and send ---
    calls = {"n": 0}
    real = ol.holder_tuple

    def flaky(conn, label, now=None):
        calls["n"] += 1
        return real(conn, label, now) if calls["n"] == 1 else None
    od.ol.holder_tuple = flaky
    try:
        s3 = Sender()
        r = mk(s3).dispatch(KB, "r_fence", b"REQ\n", ["result.md"], T0)
    finally:
        od.ol.holder_tuple = real
    case("lease lost between preflight and send: refused.json, NOT sent, not ambiguous",
         r == "held:not_dispatched:fenced_before_send" and not s3.calls
         and files(J / KB / "r_fence") == ["intent.json", "refused.json"])

    # --- (1) registry resolver must equal the lease tuple ---
    s4 = Sender()
    case("REGISTRY names a different session than the lease: held, nothing written or sent",
         mk(s4, reg=lambda l: (*PANE[KB], hashlib.sha256(b"x").hexdigest())).dispatch(KB, "r_reg", b"REQ\n", ["result.md"], T0)
         == "held:not_dispatched:registry_lease_mismatch" and not s4.calls and files(J / KB / "r_reg") is None)
    case("REGISTRY lookup missing/raising: held", mk(s4, reg=lambda l: 1 / 0).dispatch(
        KB, "r_reg2", b"REQ\n", ["result.md"], T0) == "held:not_dispatched:registry_lease_mismatch" and not s4.calls)
    seq = iter([REG[KB], None])
    case("REGISTRY changed between journal and send: refused.json, NOT sent",
         mk(s4, reg=lambda l: next(seq)).dispatch(KB, "r_reg3", b"REQ\n", ["result.md"], T0)
         == "held:not_dispatched:fenced_before_send" and not s4.calls
         and files(J / KB / "r_reg3") == ["intent.json", "refused.json"])
    # --- (3) fresh clock: too little lease left at the moment of sending ---
    ticks = iter([T0, T0 + TTL - 100])
    case("FRESH CLOCK: lease window below the delivery margin at send time: lease_too_short, NOT sent",
         mk(s4, clock=lambda: next(ticks)).dispatch(KB, "r_clock", b"REQ\n", ["result.md"])
         == "held:not_dispatched:lease_too_short" and not s4.calls
         and files(J / KB / "r_clock") == ["intent.json", "refused.json"])
    # --- (2) actual owner_lease queue: request state tracks the gate ---
    case("GATE: settled dispatch leaves the request `delivering` in owner_lease; refused ones `blocked`",
         G["gate"].state("r_kb1") == "delivering" and G["gate"].state("r_clock") == "blocked")
    G["gate"].conn.execute("UPDATE owner_state SET enabled=0")
    case("GATE disabled: held:not_dispatched:owner_lease_disabled, no send",
         mk(s4).dispatch(KB, "r_off", b"REQ\n", ["result.md"], T0) == "held:not_dispatched:owner_lease_disabled"
         and not s4.calls)
    G["gate"].conn.execute("UPDATE owner_state SET enabled=1")
    # --- (4) recover registers an exact settled dispatch, never resends ---
    s5 = Sender()
    case("dispatch r_rec", mk(s5).dispatch(KB, "r_rec", b"REQ rec\n", ["result.md"], T0) == "dispatched")
    av.conn.execute("DELETE FROM ra_requests WHERE rid='r_rec'")  # crash between settled.json and register
    case("RECOVER: settled-but-unregistered is registered exactly once, no resend",
         mk(s5).recover(T0) == {f"{KB}/r_rec": "dispatched"} and av.state("r_rec")[0] == "pending"
         and len(s5.calls) == 1 and mk(s5).recover(T0 + 1) == {})
    av.conn.execute("DELETE FROM ra_requests WHERE rid='r_rec'")
    sp = J / KB / "r_rec" / "settled.json"
    raw = json.loads(sp.read_text()); raw["generation"] = 99
    sp.unlink(); sp.write_text(json.dumps(raw))
    case("RECOVER: a settled.json not matching its intent is never registered",
         mk(s5).recover(T0) == {f"{KB}/r_rec": "dispatched:unregistered"} and av.state("r_rec")[0] == "unverified_held"
         and len(s5.calls) == 1)

    # --- availability bound to the settled dispatch; lease change after dispatch ---
    (roots[KB] / "r_kb1" / "result.md").write_text("ACK r_kb1")
    holder = lambda label: ol.holder_tuple(lc, label, T0 + 5)  # noqa: E731
    n = Sender()
    notify = lambda text: n(None, None, text.encode())  # noqa: E731
    av.tick(holder, notify, T0 + 5)
    av.tick(holder, notify, T0 + 6)
    case("settled KB dispatch -> observed -> one notice", av.tick(holder, notify, T0 + 7).get("r_kb1") == "notified"
         and len(n.calls) == 1 and set(av.stages("r_kb1")) == {"observed", "noticed"})
    later = T0 + TTL + 10
    acquire(lc, DOTS, later, session=hashlib.sha256(b"dots-session-2").hexdigest(), pane=("w4P:pF", "term_dots2"))
    (roots[DOTS] / "r_dots1" / "result.md").write_text("ACK")
    case("DOTS owner replaced by a NEW session after dispatch: held:stale_generation, no notice",
         av.tick(lambda l: ol.holder_tuple(lc, l, later), notify, later).get("r_dots1") == "held:stale_generation"
         and len(n.calls) == 1)
    case("separate acceptance: notice alone is not verified or accepted",
         "verified" not in av.stages("r_kb1") and not av.accept("r_kb1", "conductor", later))

    # --- two existing identities, concurrent independent queues (processes) ---
    lc.close()
    av.close()
    child = (
        "import sys;sys.path.insert(0,sys.argv[1]);import owner_lease as ol,result_availability as ra,owner_dispatch as od\n"
        "lc=ol.connect(sys.argv[2]);label=sys.argv[6]\n"
        "av=ra.Availability(sys.argv[3],{'knowledge-base':sys.argv[4],'herdr-control-dots':sys.argv[7]},sys.argv[5])\n"
        "sent=[]\n"
        "import owner_lease_delivery as old,json\n"
        "now=float(sys.argv[8]);reg=json.loads(sys.argv[9])\n"
        "d=od.Dispatcher(old.DeliveryGate(sys.argv[2]),av,lambda l,h,t:sent.append(l) or True,lambda l:tuple(reg[l]),lambda:now)\n"
        "res=[d.dispatch(label,f'{label}_q{i}',f'REQ {i}'.encode(),['result.md'],now) for i in range(12)]\n"
        "res.append(d.dispatch(label,f'{label}_q0',b'REQ 0',['result.md'],now))\n"
        "print(label,res.count('dispatched'),res[-1],len(sent),set(sent)=={label})\n"
    )
    lc = ol.connect(lease_db)
    acquire(lc, KB, later)  # KB lease expired at T0+TTL; re-acquire (gen 2) inside disposable state
    open_before = {lab: lc.execute("SELECT COUNT(*) FROM owner_requests WHERE label=? AND state IN (%s)"
                                   % ",".join("?" * len(ol.OPEN)), (lab, *ol.OPEN)).fetchone()[0] for lab in (KB, DOTS)}
    bound = {lab: lc.execute("SELECT max_open FROM owner_projects WHERE label=?", (lab,)).fetchone()[0] for lab in (KB, DOTS)}
    lc.close()
    reg_now = json.dumps({KB: [*PANE[KB], SESS[KB]], DOTS: ["w4P:pF", "term_dots2", hashlib.sha256(b"dots-session-2").hexdigest()]})
    args = [str(HERE / "lib"), lease_db, str(base / "ra.db"), str(roots[KB]), str(J)]
    procs = [subprocess.Popen([sys.executable, "-c", child, *args, lab, str(roots[DOTS]), str(later + 1), reg_now],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for lab in (KB, DOTS, KB, DOTS)]
    outs = [p.communicate() for p in procs]
    lines = sorted(o[0].strip() for o in outs)
    total = {KB: 0, DOTS: 0}
    for line in lines:
        parts = line.split()
        if len(parts) == 5 and parts[4] == "True":
            total[parts[0]] += int(parts[1])
    want = {lab: min(12, max(0, bound[lab] - open_before[lab])) for lab in (KB, DOTS)}  # 12 distinct rids
    case(f"CONCURRENT via the real queue: exactly max_open - open dispatched per label ({total} == {want})",
         total == want and all(not o[1] for o in outs))
    case("CONCURRENT: every racing duplicate refused by the queue; each process sent only its own label",
         all(line.split()[2].startswith("held:not_dispatched:owner_") for line in lines) and len(lines) == 4)
    av = ra.Availability(str(base / "ra.db"), {k: str(v) for k, v in roots.items()}, str(J))
    settled = sum(1 for lab in (KB, DOTS) for r in (J / lab).iterdir()
                  if r.name.startswith(lab + "_q") and (r / "settled.json").exists())
    case("CONCURRENT: settled journals == registered rows == dispatched, none crossed roots",
         settled == sum(want.values())
         and av.conn.execute("SELECT COUNT(*) FROM ra_requests WHERE rid LIKE '%_q%'").fetchone()[0] == settled
         and not any(p.name.startswith(DOTS) for p in roots[KB].iterdir())
         and not any(p.name.startswith(KB) for p in roots[DOTS].iterdir()))
    av.close()

    print(f"{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failing")
    return 1 if FAILS else 0


def _raises(fn):
    try:
        fn()
    except Exception as exc:  # noqa: BLE001
        return exc
    return None


if __name__ == "__main__":
    sys.exit(main())
