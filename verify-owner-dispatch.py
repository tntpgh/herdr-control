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
import owner_dispatch_auth as oda  # noqa: E402
import sqlite3  # noqa: E402
import uuid  # noqa: E402


def insert_grant(conn, aid, *, label, project, holder, rid, sha, manifest, status="granted",
                 prompt="fixture-prompt", approval="fixture-approval", expires=None, proto=None):
    """TEST-ONLY issuer into a disposable store (production has none)."""
    pane, birth, sess, gen = holder
    conn.execute("INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,session_digest,"
                 "lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,decided_at,expires_at)"
                 " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,'2026-10-22T00:00:00Z',?)",
                 (aid, proto or oda.PROTOCOL, label, project, pane, birth, sess, gen, rid, sha,
                  oda.manifest_key(manifest), prompt, approval, status, T0 + 3600 if expires is None else expires))


def auto_auth(path):
    """TEST FIXTURE for cases about something else: issues a grant for exactly
    the call's arguments into a disposable store, then consumes it through the
    REAL oda.consume()."""
    conn = sqlite3.connect(str(path), isolation_level=None, timeout=10)
    oda.migrate(conn)

    def authorize(label, project, holder, rid, sha, manifest, now):
        aid = uuid.uuid4().hex
        insert_grant(conn, aid, label=label, project=project, holder=holder, rid=rid, sha=sha, manifest=manifest,
                     expires=now + 3600)
        return oda.consume(conn, aid, label=label, project=project, holder=holder, request_id=rid,
                           body_sha256=sha, manifest=manifest, now=now)
    return authorize

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
    AUTH = auto_auth(base / "auth-fixture.db")

    def mk(snd, reg=None, clock=None):
        return od.Dispatcher(G["gate"], av, snd, reg or REG.get, clock or (lambda: T0), authorize=AUTH)

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
    # --- (A) crash fixtures through the REAL gate: a BaseException escapes dispatch
    # exactly where a process kill would, leaving intent.json with no outcome ---
    class Crash(BaseException):
        pass

    def crash_sender(label, holder, text):
        raise Crash()  # killed mid-send: may or may not have been typed

    try:
        mk(crash_sender).dispatch(KB, "r_crash_post", b"REQ\n", ["result.md"], T0)
    except Crash:
        pass

    class CrashBeforeNotice:
        def __init__(self, gate):
            self.g = gate

        def __getattr__(self, n):
            return getattr(self.g, n)

        def begin_notice(self, *a, **k):
            raise Crash()  # killed after admit + journal, before anything could be typed
    s2 = Sender()
    try:
        od.Dispatcher(CrashBeforeNotice(G["gate"]), av, s2, REG.get, lambda: T0, authorize=AUTH).dispatch(
            KB, "r_crash_pre", b"REQ\n", ["result.md"], T0)
    except Crash:
        pass
    case("CRASH fixtures: both left intent.json and no outcome; gate delivering vs queued",
         files(J / KB / "r_crash_post") == ["intent.json"] and files(J / KB / "r_crash_pre") == ["intent.json"]
         and G["gate"].state("r_crash_post") == "delivering" and G["gate"].state("r_crash_pre") == "queued")
    out = mk(s2).recover(T0)
    case("RECOVER post-send crash: ambiguous (uncertain.json), gate untouched, never resent or registered",
         out[f"{KB}/r_crash_post"] == "ambiguous" and files(J / KB / "r_crash_post") == ["intent.json", "uncertain.json"]
         and G["gate"].state("r_crash_post") == "delivering" and not s2.calls and av.state("r_crash_post")[0] == "unverified_held")
    case("RECOVER pre-send crash: gate settled queued->blocked, refused.json, never sent",
         out[f"{KB}/r_crash_pre"] == "refused_recovered" and files(J / KB / "r_crash_pre") == ["intent.json", "refused.json"]
         and G["gate"].record("r_crash_pre")[2:] == ("blocked", "crash_recovered_pre_send") and not s2.calls)
    case("RECOVER pre-send crash: the blocked request is never re-admitted (no resend grant)",
         mk(s2).dispatch(KB, "r_crash_pre", b"REQ\n", ["result.md"], T0).startswith("held:not_dispatched:owner_lease_duplicate")
         and not s2.calls)
    case("RECOVER reconciles every durable outcome: refused / ambiguous entries report as such",
         out[f"{KB}/r_pre"] == "refused" and out[f"{KB}/r_err"] == "ambiguous" and out[f"{KB}/r_kb1"] == "dispatched")
    again = mk(s2).recover(T0 + 1)
    case("recover is idempotent: no outcome rewritten, crash entries now steady-state",
         again[f"{KB}/r_crash_post"] == "ambiguous" and again[f"{KB}/r_crash_pre"] == "refused"
         and files(J / KB / "r_crash_post") == ["intent.json", "uncertain.json"] and not s2.calls)
    G["gate"].conn.execute("UPDATE owner_requests SET state='replied' WHERE request_id='r_pre'")
    G["gate"].conn.execute("DELETE FROM owner_requests WHERE request_id='r_err'")
    out = mk(s2).recover(T0 + 2)
    case("RECOVER surfaces journal/gate MISMATCH and UNRECORDED explicitly, writes nothing",
         out[f"{KB}/r_pre"] == "mismatch:refused:replied" and out[f"{KB}/r_err"] == "unrecorded:uncertain.json"
         and files(J / KB / "r_err") == ["intent.json", "uncertain.json"] and not s2.calls)
    G["gate"].conn.execute("UPDATE owner_requests SET state='blocked' WHERE request_id='r_pre'")

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
         mk(s5).recover(T0)[f"{KB}/r_rec"] == "registered" and av.state("r_rec")[0] == "pending"
         and len(s5.calls) == 1 and mk(s5).recover(T0 + 1)[f"{KB}/r_rec"] == "dispatched")
    av.conn.execute("DELETE FROM ra_requests WHERE rid='r_rec'")
    sp = J / KB / "r_rec" / "settled.json"
    raw = json.loads(sp.read_text()); raw["generation"] = 99
    sp.unlink(); sp.write_text(json.dumps(raw))
    case("RECOVER: a settled.json not matching its intent is never registered",
         mk(s5).recover(T0)[f"{KB}/r_rec"] == "dispatched:unregistered" and av.state("r_rec")[0] == "unverified_held"
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
        "import sqlite3,uuid,owner_dispatch_auth as oda\n"
        "ac=sqlite3.connect(sys.argv[3]+'.auth',isolation_level=None,timeout=30);oda.migrate(ac)\n"
        "def auth(l,pj,hd,r,h,m,n):\n"
        " a=uuid.uuid4().hex;ac.execute(\"INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,session_digest,lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,decided_at,expires_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,'p','a','granted','t',?)\",(a,oda.PROTOCOL,l,pj,*hd,r,h,oda.manifest_key(m),n+3600))\n"
        " return oda.consume(ac,a,label=l,project=pj,holder=hd,request_id=r,body_sha256=h,manifest=m,now=n)\n"
        "d=od.Dispatcher(old.DeliveryGate(sys.argv[2]),av,lambda l,h,t:sent.append(l) or True,lambda l:tuple(reg[l]),lambda:now,authorize=auth)\n"
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

    auth_contract_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    lease_writer_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    cli_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    publisher_tick_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    print(f"{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failing")
    return 1 if FAILS else 0


def auth_contract_cases(base: Path) -> None:
    """owner-dispatch-auth/2 through the REAL store and Dispatcher: every hold
    happens before admission and before any journal/handoff write."""
    lc, av, roots, lease_db = env(base)
    J = base / "journal"
    acquire(lc, KB, T0, session=SESS[KB])
    gate = old.DeliveryGate(lease_db)
    reg = {KB: (*PANE[KB], SESS[KB])}.get
    HOLDER = ol.holder_tuple(lc, KB, T0)
    PROJ = lc.execute("SELECT project FROM owner_projects WHERE label=?", (KB,)).fetchone()[0]
    store = sqlite3.connect(str(base / "auth.db"), isolation_level=None)
    oda.migrate(store)
    body, man = b"REQ auth\n", ["result.md"]
    sha = hashlib.sha256(body).hexdigest()

    def grant(aid, rid="r_a", label=KB, project=None, holder=None, s=sha, m=man, **kw):
        insert_grant(store, aid, label=label, project=PROJ if project is None else project,
                     holder=HOLDER if holder is None else holder, rid=rid, sha=s, manifest=m, **kw)

    def consumer(aid, conn=None):
        c = conn or store
        return lambda l, pj, hd, r, h, m, n: oda.consume(c, aid, label=l, project=pj, holder=hd, request_id=r,
                                                         body_sha256=h, manifest=m, now=n)

    def mkd(aid, clock=T0):
        return od.Dispatcher(gate, av, lambda l, h, t: sent.append(t) or True, reg, lambda: clock, authorize=consumer(aid))

    def nothing(rid):
        return files(J / KB / rid) is None and files(roots[KB] / rid) is None and gate.state(rid) is None

    def status(aid):
        return store.execute("SELECT status FROM owner_dispatch_auth WHERE auth_id=?", (aid,)).fetchone()[0]

    sent = []
    nod = od.Dispatcher(gate, av, lambda l, h, t: sent.append(t) or True, reg, lambda: T0)
    case("AUTH: no authorizer configured -> held auth_missing, nothing admitted/written/sent",
         nod.dispatch(KB, "r_a", body, man, T0) == "held:not_dispatched:auth_missing" and nothing("r_a") and not sent)
    case("AUTH: absent grant -> held auth_missing", mkd("nope").dispatch(KB, "r_a", body, man, T0)
         == "held:not_dispatched:auth_missing" and nothing("r_a"))
    grant("a_den", status="denied")
    case("AUTH: denied grant -> held auth_denied", mkd("a_den").dispatch(KB, "r_a", body, man, T0)
         == "held:not_dispatched:auth_denied" and nothing("r_a"))
    p, b_, sd, g = HOLDER
    for aid, kw, what in [("a_body", {"s": "0" * 64}, "body sha"), ("a_rid", {"rid": "r_other"}, "request id"),
                          ("a_lab", {"label": DOTS}, "owner label"), ("a_man", {"m": ["other.md"]}, "manifest"),
                          ("a_proto", {"proto": "owner-dispatch-auth/1"}, "protocol"), ("a_noprompt", {"prompt": ""}, "prompt identity"),
                          ("a_proj", {"project": "tntpgh/other"}, "project"),
                          ("a_pane", {"holder": ("w9:p9", b_, sd, g)}, "pane"),
                          ("a_birth", {"holder": (p, "term_other", sd, g)}, "pane birth"),
                          ("a_sess", {"holder": (p, b_, "f" * 64, g)}, "session digest"),
                          ("a_gen", {"holder": (p, b_, sd, g + 1)}, "lease generation")]:
        grant(aid, **kw)
        case(f"AUTH: grant bound to a different {what} -> held auth_mismatch, still granted",
             mkd(aid).dispatch(KB, "r_a", body, man, T0) == "held:not_dispatched:auth_mismatch" and nothing("r_a")
             and status(aid) == "granted")
    grant("a_exp", expires=T0)
    case("AUTH: grant at/after expires_at -> held auth_expired, still granted, nothing written",
         mkd("a_exp").dispatch(KB, "r_a", body, man, T0) == "held:not_dispatched:auth_expired" and nothing("r_a")
         and status("a_exp") == "granted")
    grant("a_ok")
    case("AUTH: exact grant -> dispatched with the identical bytes; grant consumed",
         mkd("a_ok").dispatch(KB, "r_a", body, man, T0) == "dispatched" and sent == [body] and status("a_ok") == "consumed")
    case("AUTH: a consumed grant never authorizes again",
         mkd("a_ok").dispatch(KB, "r_a", body, man, T0).startswith("held:not_dispatched:auth_consumed") and len(sent) == 1)
    case("UNSENT: a dispatched grant is not reported unsent", oda.unsent(store, str(J)) == [])
    # consumed, then refused at admission (queue full): burned with no journal -> surfaced
    lc.execute("UPDATE owner_projects SET max_open=1 WHERE label=?", (KB,))
    grant("a_q", rid="r_q")
    rq_res = mkd("a_q").dispatch(KB, "r_q", body, man, T0)
    case("UNSENT: consumed then refused at admission -> held, no journal, listed by unsent(); never regranted",
         rq_res.startswith("held:not_dispatched:") and status("a_q") == "consumed" and files(J / KB / "r_q") is None
         and oda.unsent(store, str(J)) == ["a_q"])
    lc.execute("UPDATE owner_projects SET max_open=? WHERE label=?", (ol.DEFAULT_MAX_OPEN, KB))
    grant("a_amb", rid="r_amb")
    broken = sqlite3.connect(str(base / "auth.db"), isolation_level=None)
    broken.close()
    amb = od.Dispatcher(gate, av, lambda l, h, t: sent.append(t) or True, reg, lambda: T0, authorize=consumer("a_amb", broken))
    case("AUTH: store error -> held auth_ambiguous, nothing written",
         amb.dispatch(KB, "r_amb", body, man, T0).startswith("held:not_dispatched:auth_ambiguous") and nothing("r_amb"))
    raising = od.Dispatcher(gate, av, lambda l, h, t: True, reg, lambda: T0, authorize=lambda *a: 1 / 0)
    case("AUTH: authorizer raising -> held auth_ambiguous", raising.dispatch(KB, "r_amb", body, man, T0)
         == "held:not_dispatched:auth_ambiguous:ZeroDivisionError" and nothing("r_amb"))
    case("AUTH: an authorizer returning anything but 'ok' never authorizes (self-attestation)",
         od.Dispatcher(gate, av, lambda l, h, t: True, reg, lambda: T0, authorize=lambda *a: True).dispatch(
             KB, "r_amb", body, man, T0) == "held:not_dispatched:True" and nothing("r_amb"))
    grant("a_race", rid="r_race")
    import threading
    res = []
    def worker():
        c = sqlite3.connect(str(base / "auth.db"), isolation_level=None, timeout=10)
        res.append(oda.consume(c, "a_race", label=KB, project=PROJ, holder=HOLDER, request_id="r_race",
                               body_sha256=sha, manifest=man, now=T0))
        c.close()
    ts = [threading.Thread(target=worker) for _ in range(8)]
    [t.start() for t in ts]; [t.join() for t in ts]
    case("AUTH: 8 concurrent consumers of one grant -> exactly one ok, rest auth_consumed",
         res.count("ok") == 1 and res.count("auth_consumed") == 7)
    lc.execute("PRAGMA foreign_keys=OFF")  # disposable DB: model a label with no mapping row
    lc.execute("DELETE FROM owner_projects WHERE label=?", (DOTS,))
    grant("a_unm", rid="r_unm", label=DOTS)
    unm = od.Dispatcher(gate, av, lambda l, h, t: True, {DOTS: (*PANE[DOTS], SESS[DOTS])}.get, lambda: T0,
                        authorize=consumer("a_unm"))
    case("MAPPING: no owner_projects row -> held owner_project_unmapped; grant untouched; nothing registered",
         unm.dispatch(DOTS, "r_unm", body, man, T0) == "held:not_dispatched:owner_project_unmapped"
         and status("a_unm") == "granted"
         and lc.execute("SELECT count(*) FROM owner_projects WHERE label=?", (DOTS,)).fetchone()[0] == 0)
    # store opening
    sd_ = base / "store"; sd_.mkdir(mode=0o700)
    good = sd_ / "auth.db"
    c = sqlite3.connect(str(good)); oda.migrate(c); c.close(); os.chmod(good, 0o600)
    def oerr(path):
        try:
            oda.open_store(str(path)).close(); return "open"
        except ValueError as e:
            return str(e)
    case("STORE: canonical private migrated store opens", oerr(good) == "open")
    (sd_ / "link.db").symlink_to(good)
    case("STORE: symlink path refused", oerr(sd_ / "link.db") == "store_path_not_canonical")
    case("STORE: missing store refused, not created", oerr(sd_ / "none.db") == "store_missing" and not (sd_ / "none.db").exists())
    os.chmod(good, 0o644); r1 = oerr(good); os.chmod(good, 0o600)
    case("STORE: group/other-readable store refused", r1 == "store_not_private_regular")
    os.chmod(sd_, 0o777); r2 = oerr(good); os.chmod(sd_, 0o700)
    case("STORE: world-writable parent refused", r2 == "store_parent_unprotected")
    (sd_ / "auth.db-wal").symlink_to(base / "elsewhere")
    case("STORE: symlinked -wal sidecar refused", oerr(good) == "store_sidecar_unsafe")
    os.unlink(sd_ / "auth.db-wal")
    e = sd_ / "empty.db"; sqlite3.connect(str(e)).close(); os.chmod(e, 0o600)
    case("STORE: unmigrated store refused", oerr(e) == "store_not_migrated")
    rq = base / "rq"; rq.mkdir()
    (rq / "req.txt").write_bytes(body)
    (rq / "link.txt").symlink_to(rq / "req.txt")
    (rq / "big.txt").write_bytes(b"x" * (oda.MAX_REQUEST_BYTES + 1))
    os.mkfifo(rq / "fifo")
    def rerr(parent, name):
        try:
            oda.read_request_once(parent, name); return "read"
        except (ValueError, OSError) as e:
            return str(e) if isinstance(e, ValueError) else type(e).__name__
    case("READ: regular file under canonical parent -> exact bytes", oda.read_request_once(str(rq), "req.txt") == body)
    case("READ: symlink refused (O_NOFOLLOW)", rerr(str(rq), "link.txt") == "OSError")
    case("READ: oversize refused", rerr(str(rq), "big.txt") == "bad_size")
    case("READ: fifo refused without blocking", rerr(str(rq), "fifo") == "not_regular_file")
    case("READ: non-canonical parent refused", rerr(str(rq) + "/../rq", "req.txt") == "parent_not_canonical")
    case("READ: path traversal name refused", rerr(str(rq), "../rq/req.txt") == "bad_name")
    store.close(); gate.close(); av.close(); lc.close()


def lease_writer_cases(base: Path) -> None:
    """owner-lease-claim.py: registry-row identity only, one-shot, no renew."""
    import importlib.util
    import io
    import contextlib
    spec = importlib.util.spec_from_file_location("olc", HERE / "owner-lease-claim.py")
    olc = importlib.util.module_from_spec(spec); spec.loader.exec_module(olc)
    lc, av, roots, lease_db = env(base)
    reg = {KB: (*PANE[KB], SESS[KB])}

    def run(label, flags=True, resolve=reg.get):
        saved = {k: os.environ.get(k) for k in ("HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DELIVERY", "HERDR_OWNER_LEASE_DB")}
        if flags:
            os.environ.update(HERDR_OWNER_LEASE_WRITER="1", HERDR_OWNER_LEASE_DELIVERY="1", HERDR_OWNER_LEASE_DB=lease_db)
        else:
            for k in saved:
                os.environ.pop(k, None)
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = olc.main(["--label", label, "--ttl", str(TTL)], resolve=resolve)
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return rc, buf.getvalue().strip()

    live = lambda lab: lc.execute("SELECT count(*) FROM owner_leases WHERE label=? AND released_at IS NULL", (lab,)).fetchone()[0]
    case("WRITER: flags off -> refused, no lease", run(KB, flags=False) == (4, "refused:flags_off") and live(KB) == 0)
    case("WRITER: label not in the registry -> refused", run(DOTS) == (2, "refused:not_registered_or_no_session") and live(DOTS) == 0)
    rc, out = run(KB)
    ht = ol.holder_tuple(lc, KB)
    case("WRITER: acquires with EXACTLY the registry (pane, birth, session digest)",
         rc == 0 and out == "acquired:knowledge-base:gen1" and ht is not None and ht[:3] == reg[KB])
    exp = lc.execute("SELECT expires_at FROM owner_leases WHERE label=? AND released_at IS NULL", (KB,)).fetchone()[0]
    case("WRITER: a second run never renews (same holder) -> lease_exists, expiry unchanged",
         run(KB) == (2, "refused:lease_exists")
         and lc.execute("SELECT expires_at FROM owner_leases WHERE label=? AND released_at IS NULL", (KB,)).fetchone()[0] == exp)
    case("WRITER: a different registry identity never takes over -> lease_exists",
         run(KB, resolve={KB: ("w9:p9", "term_x", SESS[KB])}.get) == (2, "refused:lease_exists") and ol.holder_tuple(lc, KB) == ht)
    lc.execute("PRAGMA foreign_keys=OFF")
    lc.execute("DELETE FROM owner_projects WHERE label=?", (DOTS,))
    case("WRITER: no owner_projects mapping -> refused, mapping not created",
         run(DOTS, resolve={DOTS: (*PANE[DOTS], SESS[DOTS])}.get) == (2, "refused:owner_project_unmapped")
         and lc.execute("SELECT count(*) FROM owner_projects WHERE label=?", (DOTS,)).fetchone()[0] == 0)
    av.close(); lc.close()


def cli_cases(base: Path) -> None:
    """owner-dispatch.py as the caller: subprocess for flag/store refusals,
    main() for the full path with the REAL delivery adapter (make_send) aimed
    at a recording stand-in for herdr-deliver."""
    import importlib.util
    import io
    import contextlib
    import time as _t
    cli = HERE / "owner-dispatch.py"
    spec = importlib.util.spec_from_file_location("odcli", cli)
    odc = importlib.util.module_from_spec(spec); spec.loader.exec_module(odc)
    lc, av, roots, lease_db = env(base)
    av.close()
    now = _t.time()
    acquire(lc, KB, now, session=SESS[KB])
    holder = ol.holder_tuple(lc, KB, now)
    proj = lc.execute("SELECT project FROM owner_projects WHERE label=?", (KB,)).fetchone()[0]
    sd = base / "authstore"; sd.mkdir(mode=0o700)
    adb = sd / "auth.db"
    c = sqlite3.connect(str(adb), isolation_level=None); oda.migrate(c); os.chmod(adb, 0o600)
    rq = base / "req"; rq.mkdir()
    body = "REQ cli \u00e9\n".encode()
    (rq / "r.txt").write_bytes(body)
    sha = hashlib.sha256(body).hexdigest()
    rec = base / "deliver.log"
    fake = base / "fake-deliver.sh"
    fake.write_text(f"#!/bin/sh\nprintf '%s\\n--\\n%s' \"$1\" \"$2\" > {rec}\nexit 0\n"); os.chmod(fake, 0o700)
    E = {"HERDR_OWNER_DISPATCH": "1", "HERDR_OWNER_LEASE_DELIVERY": "1", "HERDR_OWNER_LEASE_DB": lease_db,
         "HERDR_OWNER_DISPATCH_AUTH_DB": str(adb), "HERDR_RESULT_AVAILABILITY": "1",
         "HERDR_RESULT_AVAILABILITY_DB": str(base / "ra.db"), "HERDR_RESULT_AVAILABILITY_JOURNAL": str(base / "journal"),
         "HERDR_RESULT_AVAILABILITY_ROOTS": f"{KB}={roots[KB]}{os.pathsep}{DOTS}={roots[DOTS]}"}
    ARGS = lambda rid, aid: ["--label", KB, "--rid", rid, "--request-dir", str(rq), "--request-name", "r.txt",
                             "--auth-id", aid, "--manifest", "result.md"]

    def sub(env_over, rid="r_c", aid="a_c"):
        e = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_")}
        e.update(env_over)
        r = subprocess.run([sys.executable, str(cli), *ARGS(rid, aid)], capture_output=True, text=True, env=e, timeout=60)
        return r.returncode, r.stdout.strip()

    def inproc(rid, aid, resolve={KB: (*PANE[KB], SESS[KB])}.get):
        saved = {k: os.environ.get(k) for k in E}
        os.environ.update(E)
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = odc.main(ARGS(rid, aid), send=odc.make_send(str(fake)), resolve=resolve)
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return rc, buf.getvalue().strip()

    case("CLI: flags off (subprocess) -> exit 4 refused:flags_off", sub({}) == (4, "refused:flags_off"))
    (sd / "link.db").symlink_to(adb)
    case("CLI: symlinked auth store (subprocess) -> exit 4, refused before any read",
         sub({**E, "HERDR_OWNER_DISPATCH_AUTH_DB": str(sd / "link.db")}) == (4, "refused:store_path_not_canonical"))
    case("CLI: missing auth store (subprocess) -> exit 4, not created",
         sub({**E, "HERDR_OWNER_DISPATCH_AUTH_DB": str(sd / "x.db")}) == (4, "refused:store_missing")
         and not (sd / "x.db").exists())
    case("CLI: no grant -> exit 2 held auth_missing, adapter never called",
         inproc("r_c", "nope") == (2, "held:not_dispatched:auth_missing") and not rec.exists())
    insert_grant(c, "a_c", label=KB, project=proj, holder=holder, rid="r_c", sha=sha, manifest=["result.md"], expires=now + 600)
    rc, out = inproc("r_c", "a_c")
    delivered = rec.read_bytes() if rec.exists() else b""
    case("CLI: exact grant -> exit 0 dispatched; adapter got pane + the captured bytes (grant sha binds them)",
         (rc, out) == (0, "dispatched") and delivered == PANE[KB][0].encode() + b"\n--\n" + body
         and (roots[KB] / "r_c" / ra.REQUEST_FILE).read_bytes() == body)
    insert_grant(c, "a_d", label=KB, project=proj, holder=holder, rid="r_d", sha="0" * 64, manifest=["result.md"], expires=now + 600)
    case("CLI: grant for other bytes -> exit 2 auth_mismatch", inproc("r_d", "a_d") == (2, "held:not_dispatched:auth_mismatch"))
    # consumed-but-unsent grant present -> every later run refuses (recovery hold)
    insert_grant(c, "a_burn", label=KB, project=proj, holder=holder, rid="r_burn", sha=sha, manifest=["result.md"], expires=now + 600)
    c.execute("UPDATE owner_dispatch_auth SET status='consumed' WHERE auth_id='a_burn'")
    insert_grant(c, "a_e", label=KB, project=proj, holder=holder, rid="r_e", sha=sha, manifest=["result.md"], expires=now + 600)
    rc, out = inproc("r_e", "a_e")
    case("CLI: consumed-but-unsent grant -> exit 4 recovery hold; the new grant is NOT consumed",
         rc == 4 and out == "refused:recovery_needs_operator auth:a_burn=consumed_unsent"
         and c.execute("SELECT status FROM owner_dispatch_auth WHERE auth_id='a_e'").fetchone()[0] == "granted")
    c.close(); lc.close()


def publisher_tick_cases(base: Path) -> None:
    """(7) remote-mcp/publisher.py result_availability_tick: default off; a
    conductor without a registry-bound lease -> held:not_dispatched, nothing
    typed; with one -> exactly one notice typed to the conductor pane."""
    import importlib.util
    import time as _t
    root, J = base / "kb_root", base / "journal"
    root.mkdir(); J.mkdir()
    lease_db = str(base / "lease.db")
    lc = ol.connect(lease_db); ol.migrate(lc)
    ol.register_owner(lc, KB, "tntpgh/knowledge-base", now=_t.time())
    ol.register_owner(lc, "conductor", "tntpgh/thurber-os", now=_t.time())
    typed = base / "typed.log"
    fake = base / "fake-deliver.sh"
    fake.write_text(f'#!/bin/sh\nprintf "%s|%s\\n" "$1" "$2" >> {typed}\n')
    fake.chmod(0o700)
    env = {"HERDR_OWNER_LEASE_DELIVERY": "1", "HERDR_OWNER_LEASE_DB": lease_db,
           "HERDR_RESULT_AVAILABILITY_DB": str(base / "ra.db"),
           "HERDR_RESULT_AVAILABILITY_ROOTS": f"{KB}={root}", "HERDR_RESULT_AVAILABILITY_JOURNAL": str(J)}
    saved = {k: os.environ.get(k) for k in [*env, "HERDR_RESULT_AVAILABILITY", "HERDR_DELIVER"]}
    os.environ.update(env); os.environ["HERDR_DELIVER"] = str(fake)
    try:
        sys.path.insert(0, str(HERE / "remote-mcp"))
        spec = importlib.util.spec_from_file_location("publisher_under_test", HERE / "remote-mcp" / "publisher.py")
        pub = importlib.util.module_from_spec(spec); spec.loader.exec_module(pub)
        pub.DELIVER = str(fake)
        rows = {KB: {"pane_id": PANE[KB][0], "pane_birth": PANE[KB][1], "agent_session": "kb-sess"},
                "conductor": {"pane_id": "w72:p1", "pane_birth": "term_cond", "agent_session": "cond-sess"}}
        pub.registry_owners = lambda: {k: dict(v, workspace="", registered_at="", updated_at="") for k, v in rows.items()}
        kb_digest = pub.owner_session_digest(KB, rows[KB])
        ol.acquire(lc, KB, *PANE[KB], TTL, _t.time(), session_digest=kb_digest)
        os.environ.pop("HERDR_RESULT_AVAILABILITY", None)
        case("TICK default off: no flag -> None, nothing typed", pub.result_availability_tick() is None and not typed.exists())
        os.environ["HERDR_RESULT_AVAILABILITY"] = "1"
        av = ra.Availability(env["HERDR_RESULT_AVAILABILITY_DB"], {KB: str(root)}, str(J))
        d = od.Dispatcher(old.DeliveryGate(lease_db), av, lambda l, h, t: True, pub.registry_resolver,
                          authorize=auto_auth(base / "auth.db"))
        case("TICK fixture: dispatched through the publisher's own registry resolver",
             d.dispatch(KB, "r_tick", b"REQ tick\n", ["result.md"]) == "dispatched")
        (root / "r_tick" / "result.md").write_text("ACK r_tick")
        pub.result_availability_tick(); pub.result_availability_tick()
        out = pub.result_availability_tick()
        case("TICK no conductor lease: typed pre-send held, row stays staged, nothing typed, no gate row",
             out == {"r_tick": "held:not_dispatched:conductor_identity_gone"} and av.state("r_tick")[0] == "staged"
             and not typed.exists() and lc.execute("SELECT count(*) FROM owner_requests WHERE label='conductor'").fetchone()[0] == 0)
        ol.acquire(lc, "conductor", "w72:p1", "term_cond", TTL, _t.time(), session_digest=hashlib.sha256(b"wrong").hexdigest())
        case("TICK conductor lease not matching the registry session: still held, nothing typed",
             pub.result_availability_tick() == {"r_tick": "held:not_dispatched:conductor_identity_gone"} and not typed.exists())
        lc.execute("UPDATE owner_leases SET expires_at='2000-01-01T00:00:00.000000Z' WHERE label='conductor'")
        ol.acquire(lc, "conductor", "w72:p1", "term_cond", TTL, _t.time(),
                   session_digest=pub.owner_session_digest("conductor", rows["conductor"]))
        gate = old.DeliveryGate(lease_db)
        xid = ra.GatedNotice.exchange_id

        def stage(rid):
            assert d.dispatch(KB, rid, f"REQ {rid}\n".encode(), ["result.md"]) == "dispatched"
            (root / rid / "result.md").write_text(f"ACK {rid}")
            pub.result_availability_tick(); pub.result_availability_tick()
            row = av.conn.execute("SELECT observed, request_dir FROM ra_requests WHERE rid=?", (rid,)).fetchone()
            return ra.notice_text(rid, row[0], row[1])

        # RACE: ready/prepare saw the conductor, identity gone at the typing boundary.
        real_resolver, calls = pub.registry_resolver, {"n": 0}

        def flaky(label):
            if label == "conductor":
                calls["n"] += 1
                if calls["n"] > 1:
                    return None
            return real_resolver(label)
        pub.registry_resolver = flaky
        text = av.conn.execute("SELECT observed, request_dir FROM ra_requests WHERE rid='r_tick'").fetchone()
        text = ra.notice_text("r_tick", *text)
        out = pub.result_availability_tick()
        pub.registry_resolver = real_resolver
        case("RACE identity gone at the boundary: typed pre-send held, row staged (never notifying/ambiguous), nothing typed",
             out == {"r_tick": "held:not_dispatched:identity_changed_pre_send"} and av.state("r_tick")[0] == "staged"
             and not typed.exists() and gate.record(xid(text))[2:] == ("blocked", "identity_changed_pre_send"))
        case("RACE: the blocked notice is never re-admitted (no resend grant)",
             pub.result_availability_tick()["r_tick"] == "held:not_dispatched:owner_lease_duplicate:blocked" and not typed.exists())
        t2 = stage("r_tick2")
        out = pub.result_availability_tick()
        lines = typed.read_text().splitlines() if typed.exists() else []
        case("TICK registry-bound conductor: notified through the gate, exactly one notice, body-bound exchange id delivering",
             out["r_tick2"] == "notified" and len(lines) == 1 and lines[0] == f"w72:p1|{t2}"
             and gate.record(xid(t2))[:3] == ("conductor", gate.record(xid(t2))[1], "delivering")
             and "r_tick2" not in pub.result_availability_tick())
        t3 = stage("r_tick3")
        bad = base / "fail-deliver.sh"
        bad.write_text("#!/bin/sh\nexit 1\n"); bad.chmod(0o700)
        pub.DELIVER = str(bad)
        out = pub.result_availability_tick()
        pub.DELIVER = str(fake)
        case("POST-SEND failure: ambiguous, gate blocked send_not_confirmed (not retryable)",
             out["r_tick3"] == "ambiguous" and gate.record(xid(t3))[2:] == ("blocked", "send_not_confirmed"))
        t4 = stage("r_tick4")

        class Crash(BaseException):
            pass
        real_prepare = ra.GatedNotice.prepare

        def crash_after_prepare(self, rid, text):
            r = real_prepare(self, rid, text)
            if rid != "r_tick4":
                return r
            raise Crash()  # killed after begin_notice, before the notifying CAS
        ra.GatedNotice.prepare = crash_after_prepare
        try:
            pub.result_availability_tick()
        except Crash:
            pass
        finally:
            ra.GatedNotice.prepare = real_prepare
        out = pub.result_availability_tick()
        case("CRASH after begin_notice, before CAS: row staged, gate delivering, next tick held duplicate, never typed",
             out["r_tick4"] == "held:not_dispatched:owner_lease_duplicate:delivering" and av.state("r_tick4")[0] == "staged"
             and gate.record(xid(t4))[2] == "delivering" and len(typed.read_text().splitlines()) == 1)
        gate.close()
        av.close()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        lc.close()


def _raises(fn):
    try:
        fn()
    except Exception as exc:  # noqa: BLE001
        return exc
    return None


if __name__ == "__main__":
    sys.exit(main())
