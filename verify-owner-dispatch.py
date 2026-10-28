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
import time
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
    # Journal duplicate detection now runs BEFORE admit() (intent.json is
    # written ahead of admission so a refused admission is always durable --
    # see owner_dispatch.py's admission-refusal fix); a RID with an existing
    # journal entry is caught there, never reaching the gate a second time.
    case("DUPLICATE rid: refused by the journal, sender not called again, journal unchanged",
         d.dispatch(KB, "r_kb1", b"REQ kb\n", ["result.md"], T0) == "held:not_dispatched:duplicate_rid"
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
         mk(s2).dispatch(KB, "r_crash_pre", b"REQ\n", ["result.md"], T0) == "held:not_dispatched:duplicate_rid"
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
    # Each process's own final re-dispatch of its label's q0 races against a
    # journal entry (its own OR its racing twin's, same shared journal root)
    # that is guaranteed to exist by then -- the journal's exclusive mkdir
    # catches it before the gate is asked again.
    case("CONCURRENT: every racing duplicate refused by the already-journaled rid; each process sent only its own label",
         all(line.split()[2] == "held:not_dispatched:duplicate_rid" for line in lines) and len(lines) == 4)
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
    register_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    unregister_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    reregister_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    cli_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    publisher_tick_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    operator_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    issue_cases(Path(os.path.realpath(tempfile.mkdtemp())))
    standing_issue_cases(Path(os.path.realpath(tempfile.mkdtemp())))
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
    case("UNSENT: a dispatched grant is accounted for by its own envelope in intent.json",
         oda.unsent(store, str(J)) == [] and json.loads((J / KB / "r_a" / "intent.json").read_text())["auth"]["auth_id"] == "a_ok")
    # Forged/stale accounting: a consumed grant whose rid dir holds an intent
    # that is old (no/other auth), symlinked, or malformed stays UNSENT.
    for aid, rid, make in [
            ("a_old", "r_old", lambda d: (d / "intent.json").write_text(json.dumps({"rid": "r_old", "label": KB}))),
            ("a_oth", "r_oth", lambda d: (d / "intent.json").write_text(json.dumps({"rid": "r_oth", "label": KB, "auth": {"auth_id": "a_ok"}}))),
            ("a_sym", "r_sym", lambda d: (d / "intent.json").symlink_to(base / "forged-intent.json")),
            ("a_bad", "r_bad", lambda d: (d / "intent.json").write_bytes(b"{not json"))]:
        grant(aid, rid=rid, status="consumed")
        store.execute("UPDATE owner_dispatch_auth SET consumed_at='t' WHERE auth_id=?", (aid,))
        if aid == "a_sym":  # symlink target carries the EXACT envelope: only O_NOFOLLOW rejects it
            (base / "forged-intent.json").write_text(json.dumps({"rid": rid, "label": KB, "auth": oda._envelope(store, aid)}))
        (J / KB / rid).mkdir(parents=True)
        make(J / KB / rid)
    lst = oda.unsent(store, str(J))
    case("UNSENT: old / other-envelope / symlinked / malformed intent never accounts for a consumed grant",
         all(a in lst for a in ("a_old", "a_oth", "a_sym", "a_bad")) and "a_ok" not in lst)
    for aid in ("a_old", "a_oth", "a_sym", "a_bad"):
        store.execute("DELETE FROM owner_dispatch_auth WHERE auth_id=?", (aid,))
    forged = {"auth_id": "x", "owner_label": KB, "project": "tntpgh/other"}
    case("AUTH: an envelope that does not restate this call's binding -> auth_envelope_mismatch",
         od.Dispatcher(gate, av, lambda l, h, t: True, reg, lambda: T0, authorize=lambda *a: forged).dispatch(
             KB, "r_env", body, man, T0) == "held:not_dispatched:auth_envelope_mismatch" and nothing("r_env"))
    # consumed, then refused at admission (queue full): burned with no journal -> surfaced
    lc.execute("UPDATE owner_projects SET max_open=1 WHERE label=?", (KB,))
    grant("a_q", rid="r_q")
    rq_res = mkd("a_q").dispatch(KB, "r_q", body, man, T0)
    case("ADMISSION REFUSED: consumed then refused at admission (queue full) -> durably journaled as refused, "
         "never surfaced as consumed-unsent, never regranted",
         rq_res == "held:not_dispatched:owner_queue_full" and status("a_q") == "consumed"
         and files(J / KB / "r_q") == ["intent.json", "refused.json"]
         and oda.unsent(store, str(J)) == [] and oda.unresolved(store, str(J)) == [])
    case("ADMISSION REFUSED: recover() classifies it cleanly as refused, never mismatch/unrecorded "
         "(no gate row exists for a refusal admit() never admitted)",
         mkd("a_q").recover(T0)[f"{KB}/r_q"] == "refused")
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
             KB, "r_amb", body, man, T0) == "held:not_dispatched:auth_not_envelope" and nothing("r_amb"))
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
         sum(isinstance(r, dict) for r in res) == 1 and res.count("auth_consumed") == 7)
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
    case("STORE: symlink path refused", oerr(sd_ / "link.db") == "db_path_not_canonical")
    case("STORE: missing store refused, not created", oerr(sd_ / "none.db") == "db_missing" and not (sd_ / "none.db").exists())
    os.chmod(good, 0o644); r1 = oerr(good); os.chmod(good, 0o600)
    case("STORE: group/other-readable store refused", r1 == "db_not_private_regular")
    os.chmod(sd_, 0o777); r2 = oerr(good); os.chmod(sd_, 0o700)
    case("STORE: world-writable parent refused", r2 == "db_parent_unprotected")
    (sd_ / "auth.db-wal").symlink_to(base / "elsewhere")
    case("STORE: symlinked -wal sidecar refused", oerr(good) == "db_sidecar_unsafe")
    os.unlink(sd_ / "auth.db-wal")
    import private_sqlite as ps
    other = sd_ / "other.db"
    c2 = sqlite3.connect(str(other)); oda.migrate(c2); c2.close(); os.chmod(other, 0o600)
    def swapping_connect(pth):
        os.rename(pth, str(sd_ / "orig.db")); os.rename(str(other), pth)  # same-UID swap during open
        return sqlite3.connect(pth)
    try:
        ps.open_private(str(good), swapping_connect, require_table="owner_dispatch_auth"); sw = "open"
    except ValueError as ex:
        sw = str(ex)
    case("STORE: file swapped while SQLite opens it -> db_swapped_after_open (connection closed)", sw == "db_swapped_after_open")
    os.rename(str(sd_ / "orig.db"), str(good))
    e = sd_ / "empty.db"; sqlite3.connect(str(e)).close(); os.chmod(e, 0o600)
    case("STORE: unmigrated store refused", oerr(e) == "db_not_migrated")
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

    def run(label, flags=True, resolve=reg.get, ttl=TTL):
        saved = {k: os.environ.get(k) for k in ("HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DELIVERY", "HERDR_OWNER_LEASE_DB")}
        if flags:
            os.environ.update(HERDR_OWNER_LEASE_WRITER="1", HERDR_OWNER_LEASE_DELIVERY="1", HERDR_OWNER_LEASE_DB=lease_db)
        else:
            for k in saved:
                os.environ.pop(k, None)
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = olc.main(["--label", label, "--ttl", str(ttl)], resolve=resolve)
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return rc, buf.getvalue().strip()

    os.chmod(lease_db, 0o600)
    leases = lambda lab: lc.execute("SELECT generation, released_at, expires_at FROM owner_leases WHERE label=? ORDER BY generation", (lab,)).fetchall()
    events = lambda: lc.execute("SELECT count(*) FROM owner_events").fetchone()[0]
    case("WRITER: flags off -> refused, no lease", run(KB, flags=False) == (4, "refused:flags_off") and leases(KB) == [])
    case("WRITER: label not in the registry -> refused", run(DOTS) == (2, "refused:not_registered_or_no_session") and leases(DOTS) == [])
    # (REVIEW.md round-2 Medium): a claim-time TTL check against bare
    # MIN_LEASE_REMAINING_S (180s) gives a lease claimed at exactly that
    # floor ZERO slack -- begin_notice()'s own remaining-time fence is
    # evaluated at whatever LATER wall-clock moment a separate
    # owner-dispatch.py/queue-supervisor.py process reaches it, so ANY
    # claim-to-delivery delay reproduces the exact "parked at queued
    # forever" failure (REVIEW.md Low-1) the floor exists to close -- it
    # only moved the threshold, it never added margin. The floor is now
    # CLAIM_TTL_FLOOR_S = MIN_LEASE_REMAINING_S + CLAIM_TO_DELIVERY_SLACK_S.
    case("WRITER: TTL below the delivery floor -> refused, no lease",
         run(KB, ttl=old.CLAIM_TTL_FLOOR_S - 1) == (2, f"refused:ttl_below_delivery_floor:{old.CLAIM_TTL_FLOOR_S}")
         and leases(KB) == [])
    # Exactly-at-floor TTL folded into the real gen1 claim below (a second
    # successful claim here would consume the only initial-claim slot KB
    # has, breaking every case that follows). owner-lease-claim.py never
    # accepts an injected `now`, so the real wall clock is the claim
    # moment: captured as t_claim for the margin check right after.
    t_claim = time.time()
    rc, out = run(KB, ttl=old.CLAIM_TTL_FLOOR_S)
    ht = ol.holder_tuple(lc, KB)
    case("WRITER: initial claim = generation 1 with EXACTLY the registry (pane, birth, session digest)",
         rc == 0 and out == "acquired:knowledge-base:gen1" and ht is not None and ht[:3] == reg[KB] and ht[3] == 1)
    # The margin itself (REVIEW.md round-2 Medium, not reverted -- reasoned
    # against the pre-fix floor): run begin_notice() against the SAME
    # just-claimed KB lease with an INJECTED `now` -- no real sleep -- set
    # past the OLD 180s margin. Under the pre-fix floor (TTL == 180 exactly)
    # this delay alone would already put remaining time below
    # MIN_LEASE_REMAINING_S, returning 'lease_too_short'; the new floor's
    # extra CLAIM_TO_DELIVERY_SLACK_S must still clear it.
    margin_gate = old.DeliveryGate(lease_db)
    adm = margin_gate.admit(KB, *PANE[KB], "r_margin", now=time.time())
    case("DELIVERY: margin fixture admitted at gen1", adm.ok and adm.generation == 1)
    delayed_now = t_claim + old.MIN_LEASE_REMAINING_S + 1  # 1s past the OLD 180s slack
    case("DELIVERY: a claim at the NEW floor still clears begin_notice() after a delay past the old 180s margin",
         margin_gate.begin_notice(KB, *PANE[KB], 1, "r_margin", now=delayed_now) == "delivering")
    margin_gate.close()
    before, ev = leases(KB), events()
    case("WRITER: a second run (same holder, live lease) -> not_initial; nothing renewed or written",
         run(KB) == (2, "refused:not_initial") and leases(KB) == before and events() == ev)
    case("WRITER: a different registry identity never takes over -> not_initial",
         run(KB, resolve={KB: ("w9:p9", "term_x", SESS[KB])}.get) == (2, "refused:not_initial") and leases(KB) == before)
    # EXPIRED predecessor: acquire() would release it, stale its requests and
    # take gen 2. The initial claim must touch nothing.
    lc.execute("UPDATE owner_leases SET expires_at='2000-01-01T00:00:00.000000Z' WHERE label=?", (KB,))
    expired, ev = leases(KB), events()
    case("WRITER: EXPIRED unreleased predecessor -> not_initial; not released, no gen 2, no events",
         run(KB) == (2, "refused:not_initial") and leases(KB) == expired and events() == ev
         and all(r[1] is None for r in expired) and len(expired) == 1)
    # request/recovery history without any lease row -> refused
    lc.execute("PRAGMA foreign_keys=OFF")
    lc.execute("INSERT INTO owner_requests(request_id,label,generation,state,created_at,updated_at) VALUES ('old_r',?,1,'stale','t','t')", (DOTS,))
    case("WRITER: request/recovery history, no lease -> not_initial",
         run(DOTS, resolve={DOTS: (*PANE[DOTS], SESS[DOTS])}.get) == (2, "refused:not_initial") and leases(DOTS) == [])
    lc.execute("DELETE FROM owner_requests WHERE request_id='old_r'")
    lc.execute("DELETE FROM owner_projects WHERE label=?", (DOTS,))
    case("WRITER: no owner_projects mapping -> refused, mapping not created",
         run(DOTS, resolve={DOTS: (*PANE[DOTS], SESS[DOTS])}.get) == (2, "refused:owner_project_unmapped")
         and lc.execute("SELECT count(*) FROM owner_projects WHERE label=?", (DOTS,)).fetchone()[0] == 0)
    os.chmod(lease_db, 0o644)
    case("WRITER: group/other-readable lease DB -> refused before any claim", run(KB)[1] == "refused:lease_db_not_private_regular")
    os.chmod(lease_db, 0o600)
    av.close(); lc.close()


def register_cases(base: Path) -> None:
    """owner-register.py: REVIEW.md Medium-1 -- the first and only
    production/CLI caller of owner_lease.register_owner(), the write
    everything downstream (owner-lease-claim.py, owner-dispatch.py,
    queue-supervisor.py) is fenced on. Mirrors lease_writer_cases()'s own
    refusal-posture coverage for owner-lease-claim.py."""
    import importlib.util
    import io
    import contextlib
    spec = importlib.util.spec_from_file_location("orc", HERE / "owner-register.py")
    orc = importlib.util.module_from_spec(spec); spec.loader.exec_module(orc)
    lc, av, roots, lease_db = env(base)
    av.close()
    NEW = "tourguide"  # env() only pre-registers KB and DOTS; this label is fresh
    NEW_PANE = ("w5:p5", "term_tg1")
    NEW_SESS = hashlib.sha256(b"tg-session-1").hexdigest()
    reg = {NEW: (*NEW_PANE, NEW_SESS)}

    def run(label=NEW, project="tntpgh/tourguide", max_open=None, flags=True, dry_run=False, resolve=reg.get):
        saved = {k: os.environ.get(k) for k in ("HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DB")}
        if flags:
            os.environ.update(HERDR_OWNER_LEASE_WRITER="1", HERDR_OWNER_LEASE_DB=lease_db)
        else:
            for k in saved:
                os.environ.pop(k, None)
        argv = ["--label", label, "--project", project]
        if max_open is not None:
            argv += ["--max-open", str(max_open)]
        if dry_run:
            argv.append("--dry-run")
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = orc.main(argv, resolve=resolve)
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return rc, buf.getvalue().strip()

    os.chmod(lease_db, 0o600)
    projects = lambda: lc.execute("SELECT label, project, max_open FROM owner_projects ORDER BY label").fetchall()
    before = projects()
    case("REGISTER: flags off -> refused, no row",
         run(flags=False) == (4, "refused:flags_off") and projects() == before)
    case("REGISTER: label not resolvable in the registry -> refused, no row",
         run(label="ghost") == (2, "refused:not_registered_or_no_session") and projects() == before)
    rc, out = run(dry_run=True)
    case("REGISTER: --dry-run prints the exact row and never writes it",
         rc == 0 and f"dry-run:owner_projects(label={NEW!r}" in out and "project='tntpgh/tourguide'" in out
         and f"rollback: DELETE FROM owner_projects WHERE label={NEW!r}" in out and projects() == before)
    case("REGISTER: non-canonical project is refused, no row",
         run(project="not-a-github-url") == (2, "refused:InvalidOwner") and projects() == before)
    case("REGISTER: max_open out of range is refused, no row",
         run(max_open=ol.MAX_OPEN_LIMIT + 1) == (2, f"refused:max_open_out_of_range:1..{ol.MAX_OPEN_LIMIT}")
         and projects() == before)
    rc, out = run()
    lines = out.splitlines()
    case("REGISTER: writes the row and prints the rollback line",
         rc == 0 and lines[0] == f"registered:{NEW}:tntpgh/tourguide"
         and lines[1] == f"rollback: DELETE FROM owner_projects WHERE label={NEW!r} "
                          f"(run against {lease_db}; refused by foreign_keys=ON once any lease/request exists for this label)"
         and projects() == before + [(NEW, "tntpgh/tourguide", ol.DEFAULT_MAX_OPEN)])
    after_write = projects()
    case("REGISTER: idempotent re-run, same label/project -> succeeds again, no duplicate row",
         run()[0] == 0 and projects() == after_write)
    # (REVIEW.md round-2 Minor): once a lease exists for the label, the
    # DELETE rollback line is guaranteed to be refused by foreign_keys=ON
    # -- the idempotent re-registration case above is exactly that moment
    # (SPEC.md item 2). The printed guidance must name the REAL procedure
    # (lib/owner_lease.py's disable(), non-destructive, preserves grants and
    # the audit trail) instead of only repeating a DELETE line that will
    # fail. Fails without the change: the old _rollback_line() always
    # printed the bare DELETE line, with no disable()/stop-admission
    # guidance at all once it is refused.
    ol.acquire(lc, NEW, *NEW_PANE, TTL, time.time(), session_digest=NEW_SESS)
    rc, out = run()
    lines = out.splitlines()
    case("REGISTER: once a lease exists, idempotent re-run still succeeds and names the real rollback",
         rc == 0 and lines[0] == f"registered:{NEW}:tntpgh/tourguide"
         and lines[1] == f"rollback: DELETE FROM owner_projects WHERE label={NEW!r} "
                          f"(run against {lease_db}; refused by foreign_keys=ON once any lease/request exists for this label)"
         and "DELETE refused" in lines[2]
         and "disable(" in out and "owner_state.enabled=0" in out
         and "never delete once a lease or request references the label" in out)
    case("REGISTER: same label, DIFFERENT project -> refused, row unchanged",
         run(project="tntpgh/other-project") == (2, "refused:InvalidOwner") and projects() == after_write)
    os.chmod(lease_db, 0o644)
    case("REGISTER: group/other-readable lease DB -> refused before any write",
         run(label="another-fresh-label")[1] == "refused:lease_db_not_private_regular" and projects() == after_write)
    os.chmod(lease_db, 0o600)

    # --- r15/F2: a plain re-run must REFUSE on an already-unregistered row,
    # never silently clear it and resume as if nothing had happened ---
    AR = "ar-label"
    AR_RESOLVE = {AR: ("w6:p6", "term_ar1", hashlib.sha256(b"ar-session-1").hexdigest())}
    ol.register_owner(lc, AR, "tntpgh/ar-project", now=T0, unregister_token="ar-old-tok")
    ol.unregister_owner(lc, AR, "ar-old-tok", now=T0 + 1, dry_run=False)
    before_ar = lc.execute("SELECT unregistered_at, unregister_token FROM owner_projects WHERE label=?",
                           (AR,)).fetchone()
    rc, out = run(label=AR, project="tntpgh/ar-project", resolve=AR_RESOLVE.get)
    case("REGISTER: refuses an already-unregistered row (AlreadyUnregistered), never silently clears it",
         rc == 2 and out.startswith("refused:AlreadyUnregistered:")
         and lc.execute("SELECT unregistered_at, unregister_token FROM owner_projects WHERE label=?",
                        (AR,)).fetchone() == before_ar)
    lc.close()


def unregister_cases(base: Path) -> None:
    """owner-lease-unregister.py: supported per-label rollback
    (R12/R13-BOUNDS.md). Dry-run default; --apply required; authorization
    token required (a label registered with none can never be
    unregistered); live-lease identity+generation fence; refuses while any
    OPEN owner_requests exist (even for dry-run); idempotent;
    DeliveryGate.registered() (lib/owner_lease_delivery.py) flips to False
    only after a successful --apply, returning the label to legacy
    delivery under the per-label gate (R8-PERLABEL.md); no code path other
    than this CLI ever calls unregister_owner()."""
    import importlib.util
    import io
    import contextlib
    spec = importlib.util.spec_from_file_location("olu", HERE / "owner-lease-unregister.py")
    olu = importlib.util.module_from_spec(spec); spec.loader.exec_module(olu)
    lc, av, roots, lease_db = env(base)
    av.close()
    os.chmod(lease_db, 0o600)
    gate = old.DeliveryGate(lease_db)
    UL, TOK = "ur-label", "secret-unregister-token-1"
    UL_PANE, UL_BIRTH, UL_SESS = "w9:p9", "term_ur1", hashlib.sha256(b"ur-session-1").hexdigest()
    ol.register_owner(lc, UL, "tntpgh/ur-project", now=T0, unregister_token=TOK)

    def run(label=UL, token=TOK, generation=0, pane_id="", pane_birth="", apply=False, flags=True):
        saved = {k: os.environ.get(k) for k in ("HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DB")}
        if flags:
            os.environ.update(HERDR_OWNER_LEASE_WRITER="1", HERDR_OWNER_LEASE_DB=lease_db)
        else:
            for k in saved:
                os.environ.pop(k, None)
        argv = ["--label", label, "--token", token]
        if generation:
            argv += ["--generation", str(generation)]
        if pane_id:
            argv += ["--pane-id", pane_id]
        if pane_birth:
            argv += ["--pane-birth", pane_birth]
        if apply:
            argv.append("--apply")
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = olu.main(argv)
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return rc, buf.getvalue().strip()

    case("UNREGISTER: flags off -> refused, nothing changed",
         run(flags=False) == (4, "refused:flags_off") and gate.registered(UL))
    case("UNREGISTER: unmapped label -> refused",
         run(label="ghost-label") == (2, "refused:owner_project_unmapped:ghost-label is not a registered owner"))
    case("UNREGISTER: WRONG token -> refused:unauthorized, nothing changed (no auth, no fallback)",
         run(token="wrong-token")[0] == 2 and run(token="wrong-token")[1].startswith("refused:unauthorized:")
         and gate.registered(UL))
    case("UNREGISTER: no live lease yet, correct token -> dry-run succeeds",
         run() == (0, f"dry-run:would_unregister:{UL}") and gate.registered(UL))

    # --- live-lease identity+generation fence ---
    gen1 = ol.acquire(lc, UL, UL_PANE, UL_BIRTH, TTL, T0, session_digest=UL_SESS)
    case("fixture: UL now has a live lease", gen1 == 1)
    case("UNREGISTER: correct token but WRONG generation/identity -> refused:unauthorized, nothing changed",
         run(generation=99, pane_id="w0:p0", pane_birth="term_wrong")[0] == 2
         and run(generation=99, pane_id="w0:p0", pane_birth="term_wrong")[1].startswith("refused:unauthorized:")
         and gate.registered(UL) and ol.holder_tuple(lc, UL, T0 + 1) is not None)
    case("UNREGISTER: correct token AND correct generation/identity -> dry-run succeeds",
         run(generation=gen1, pane_id=UL_PANE, pane_birth=UL_BIRTH) == (0, f"dry-run:would_unregister:{UL}"))

    # --- refuse while an OPEN owner_request exists, dry-run or apply ---
    holder = ol.holder_tuple(lc, UL, T0 + 1)
    ol.enqueue(lc, UL, holder[3], holder[0], holder[1], "r_open", now=T0 + 1)
    good = dict(generation=gen1, pane_id=UL_PANE, pane_birth=UL_BIRTH)
    case("UNREGISTER: open owner_request blocks even dry-run",
         run(**good)[0] == 2 and run(**good)[1].startswith("refused:open_requests:"))
    case("UNREGISTER: open owner_request blocks --apply too, nothing changed",
         run(apply=True, **good)[0] == 2 and gate.registered(UL))
    ol.transition(lc, "r_open", "delivering", UL, holder[3], holder[0], holder[1], now=T0 + 2)
    ol.transition(lc, "r_open", "replied", UL, holder[3], holder[0], holder[1], now=T0 + 3)
    case("UNREGISTER: once the request reaches a TERMINAL state, dry-run succeeds",
         run(**good) == (0, f"dry-run:would_unregister:{UL}") and gate.registered(UL))

    # --- apply: releases the live lease and sets unregistered_at ---
    case("UNREGISTER: before apply, UL still has a live lease",
         ol.holder_tuple(lc, UL, T0 + 3) is not None)
    rc, out = run(apply=True, **good)
    case("UNREGISTER: --apply releases the lease and unregisters",
         rc == 0 and out == f"apply:unregistered:{UL}"
         and ol.holder_tuple(lc, UL, T0 + 3) is None and not gate.registered(UL))
    case("UNREGISTER: no cross-owner reroute -- KB and DOTS still registered and untouched",
         gate.registered(KB) and gate.registered(DOTS)
         and lc.execute("SELECT unregistered_at FROM owner_projects WHERE label IN (?,?)", (KB, DOTS)).fetchall()
             == [(None,), (None,)])
    case("UNREGISTER: idempotent re-run (dry-run), correct token -> already_unregistered",
         run() == (0, f"dry-run:already_unregistered:{UL}"))
    case("UNREGISTER: idempotent re-run (--apply), correct token -> already_unregistered, no error",
         run(apply=True) == (0, f"apply:already_unregistered:{UL}"))
    case("UNREGISTER: WRONG token after unregister learns nothing (still refused, not already_unregistered)",
         run(token="wrong-token")[0] == 2 and run(token="wrong-token")[1].startswith("refused:unauthorized:"))
    gate.close()

    # --- GUARD (R14-GUARD.md): no code path other than this CLI REALLY
    # CALLS unregister_owner() -- detects ast.Call nodes only (func is a
    # Name or Attribute named 'unregister_owner'), never a docstring/
    # comment/string mention, so owner-register.py's and
    # owner_lease_delivery.py's prose references to the name are correctly
    # NOT flagged, with no allowlist needed for either. ---
    import ast as _ast

    def _real_calls(path: Path, name: str) -> list[int]:
        tree = _ast.parse(path.read_text())
        hits = []
        for node in _ast.walk(tree):
            if isinstance(node, _ast.Call):
                fn = node.func
                if (isinstance(fn, _ast.Name) and fn.id == name) or (isinstance(fn, _ast.Attribute) and fn.attr == name):
                    hits.append(node.lineno)
        return hits

    allowed = {"owner-lease-unregister.py", "lib/owner_lease.py"}
    offenders = []
    for py in HERE.glob("**/*.py"):
        rel = str(py.relative_to(HERE))
        if rel in allowed or rel.startswith("tmp/") or "/.venv/" in rel or rel.startswith("verify-"):
            continue
        if _real_calls(py, "unregister_owner"):
            offenders.append(rel)
    case("GUARD: no production code path other than this CLI calls unregister_owner() automatically",
         offenders == [])

    # self-test: prove the guard is not vacuously true -- a REAL call in a
    # file outside the allowlist/scan-excludes must actually be detected.
    import tempfile as _tempfile
    _selftest_dir = Path(_tempfile.mkdtemp())
    _selftest_path = _selftest_dir / "would_be_offender.py"
    _selftest_path.write_text("def x():\n    unregister_owner(None, 'l', 't')\n")
    case("GUARD self-test: a real unregister_owner() call IS detected by _real_calls()",
         _real_calls(_selftest_path, "unregister_owner") == [2])
    case("GUARD self-test: a docstring/comment mention is NOT detected as a call",
         _real_calls(HERE / "owner-register.py", "unregister_owner") == []
         and _real_calls(HERE / "lib" / "owner_lease_delivery.py", "unregister_owner") == [])
    import shutil as _shutil
    _shutil.rmtree(_selftest_dir, ignore_errors=True)
    lc.close()


def reregister_cases(base: Path) -> None:
    """owner-lease-reregister.py: r15/F2's explicit, authorized recovery
    path for a label owner-lease-unregister.py has already turned off.
    Dry-run default; --apply required; authorization is the label's
    CURRENT unregister_token; the new token/bound NEVER inherit the old
    ones; never creates or revives a lease."""
    import importlib.util
    import io
    import contextlib
    spec = importlib.util.spec_from_file_location("olrr", HERE / "owner-lease-reregister.py")
    olrr = importlib.util.module_from_spec(spec); spec.loader.exec_module(olrr)
    lc, av, roots, lease_db = env(base)
    av.close()
    os.chmod(lease_db, 0o600)
    gate = old.DeliveryGate(lease_db)
    RL, OLD_TOK = "rr-label", "old-tok-1"
    ol.register_owner(lc, RL, "tntpgh/rr-project", now=T0, unregister_token=OLD_TOK)
    ol.unregister_owner(lc, RL, OLD_TOK, now=T0 + 1, dry_run=False)
    case("fixture: RL is unregistered", not gate.registered(RL))

    def row():
        return lc.execute("SELECT unregistered_at, unregister_token, lifecycle_end_at FROM owner_projects "
                          "WHERE label=?", (RL,)).fetchone()

    def run(label=RL, project="tntpgh/rr-project", token=OLD_TOK, new_token="new-tok-1", end=T0 + 5_000_000,
            apply=False, flags=True):
        saved = {k: os.environ.get(k) for k in ("HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DB")}
        if flags:
            os.environ.update(HERDR_OWNER_LEASE_WRITER="1", HERDR_OWNER_LEASE_DB=lease_db)
        else:
            for k in saved:
                os.environ.pop(k, None)
        argv = ["--label", label, "--project", project, "--token", token, "--new-token", new_token,
                "--lifecycle-end", str(end)]
        if apply:
            argv.append("--apply")
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = olrr.main(argv)
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return rc, buf.getvalue().strip()

    before_row = row()
    case("REREGISTER: flags off -> refused, nothing changed",
         run(flags=False) == (4, "refused:flags_off") and row() == before_row)
    case("REREGISTER: wrong token -> refused:unauthorized, row unchanged INCLUDING the old token",
         run(token="wrong-token")[0] == 2 and run(token="wrong-token")[1].startswith("refused:unauthorized:")
         and row() == before_row)
    case("REREGISTER: project mismatch -> refused, row unchanged",
         run(project="tntpgh/other-project")[0] == 2 and row() == before_row)
    case("REREGISTER: dry-run (correct token) changes nothing",
         run() == (0, f"dry-run:would_reregister:{RL}") and row() == before_row and not gate.registered(RL))
    case("REREGISTER: never creates or revives a lease before apply",
         ol.holder_tuple(lc, RL, T0 + 2) is None)
    rc, out = run(apply=True)
    case("REREGISTER: --apply flips registered() to True with the new token/bound",
         rc == 0 and out == f"apply:reregistered:{RL}" and gate.registered(RL))
    after_row = row()
    case("REREGISTER: unregistered_at cleared, token is the NEW one, NOT the old",
         after_row[0] is None and after_row[1] == "new-tok-1" and after_row[1] != OLD_TOK)
    case("REREGISTER: lifecycle_end_at was set to the NEW supplied bound",
         after_row[2] == ol._iso(T0 + 5_000_000))
    case("REREGISTER: still never created or revived a lease",
         ol.holder_tuple(lc, RL, T0 + 2) is None)
    case("REREGISTER: the OLD token can no longer unregister the label (rotated, not retained)",
         isinstance(_raises(lambda: ol.unregister_owner(lc, RL, OLD_TOK, now=T0 + 3, dry_run=True)), ol.Unauthorized))
    case("REREGISTER: not-currently-unregistered label -> not_unregistered, nothing to do",
         run(token="new-tok-1") == (0, f"dry-run:not_unregistered:{RL}"))
    gate.close()

    # --- r16/F3: two concurrent reregister_owner() calls (same old token,
    # different new tokens) must NEVER both report "reregistered" -- the
    # loser must see "race_lost" and write nothing, never silently
    # overwritten while believing it won (tmp/in/ra/r16/reregister-toctou-
    # check.py). Reproduced by monkeypatching ol._tx to let a SECOND
    # connection's ENTIRE reregister_owner() call commit in the exact
    # window between the FIRST caller's advisory read and its own _tx().
    TC = "race-label"
    ol.register_owner(lc, TC, "tntpgh/race-project", now=T0, unregister_token="tok-shared")
    ol.unregister_owner(lc, TC, "tok-shared", now=T0 + 1, dry_run=False)
    lc2 = ol.connect(lease_db)
    real_tx = ol._tx

    def spying_tx(conn, fn, mutation=True):
        if spying_tx.armed:
            spying_tx.armed = False
            spying_tx.b_result = ol.reregister_owner(lc2, TC, "tntpgh/race-project", "tok-shared", "tok-B",
                                                     T0 + 2_000_000, now=T0 + 2, dry_run=False)
        return real_tx(conn, fn, mutation=mutation)

    spying_tx.armed = True
    spying_tx.b_result = None
    ol._tx = spying_tx
    try:
        a_result = ol.reregister_owner(lc, TC, "tntpgh/race-project", "tok-shared", "tok-A",
                                       T0 + 1_000_000, now=T0 + 3, dry_run=False)
    finally:
        ol._tx = real_tx
    race_row = lc.execute("SELECT unregistered_at, unregister_token, lifecycle_end_at FROM owner_projects "
                          "WHERE label=?", (TC,)).fetchone()
    race_events = lc.execute("SELECT kind FROM owner_events WHERE label=? AND kind='reregistered'",
                             (TC,)).fetchall()
    case("r16/F3: interleaved caller B (landed first) reports reregistered",
         spying_tx.b_result == "reregistered")
    case("r16/F3: interleaved caller A (lost the race) reports race_lost, NOT reregistered",
         a_result == "race_lost")
    case("r16/F3: row holds the WINNER's (B's) token and bound, not A's",
         race_row == (None, "tok-B", ol._iso(T0 + 2_000_000)))
    case("r16/F3: audit has exactly ONE reregistered line, not two",
         len(race_events) == 1)

    # --- r16/F3: the CLI surfaces race_lost as a nonzero exit, not a
    # false success (monkeypatch ol.reregister_owner itself, since driving
    # an ACTUAL race through the CLI's own main() needs the same
    # cross-connection interleaving already proven above at the library
    # level -- this only needs to prove the CLI's result->exit mapping) ---
    real_reregister = ol.reregister_owner
    ol.reregister_owner = lambda *a, **k: "race_lost"
    try:
        rc_cli, out_cli = run(apply=True)
    finally:
        ol.reregister_owner = real_reregister
    case("r16/F3: CLI exits nonzero (2) and prints race_lost, never a fake success",
         rc_cli == 2 and out_cli == f"apply:race_lost:{RL}")
    lc2.close()
    lc.close()


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
    os.chmod(lease_db, 0o600)
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

    def inproc_env(over, rid, aid):
        saved = {k: os.environ.get(k) for k in E}
        os.environ.update({**E, **over})
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = odc.main(ARGS(rid, aid), send=odc.make_send(str(fake)), resolve={KB: (*PANE[KB], SESS[KB])}.get)
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return rc, buf.getvalue().strip()

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
         sub({**E, "HERDR_OWNER_DISPATCH_AUTH_DB": str(sd / "link.db")}) == (4, "refused:db_path_not_canonical"))
    case("CLI: missing auth store (subprocess) -> exit 4, not created",
         sub({**E, "HERDR_OWNER_DISPATCH_AUTH_DB": str(sd / "x.db")}) == (4, "refused:db_missing")
         and not (sd / "x.db").exists())
    (base / "lease-link.db").symlink_to(lease_db)
    case("CLI: symlinked LEASE DB -> exit 4 refused before dispatch",
         inproc_env({"HERDR_OWNER_LEASE_DB": str(base / "lease-link.db")}, "r_c", "nope") == (4, "refused:lease_db_path_not_canonical"))
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
    # operator resolution: wrong key keeps the hold; exact key lifts it for a_burn only; a_burn stays listed by unsent()
    bad_key = oda.resolve(c, "a_burn", envelope_sha256_hex="0" * 64, operator="terrence", decision_ref="form-x", note="handoff read-back: request.txt absent",
                          outcome="confirmed_not_delivered")
    rc_wrong = inproc("r_e", "a_e")[0]
    good = oda.resolve(c, "a_burn", envelope_sha256_hex=oda.envelope_sha256(oda._envelope(c, "a_burn")),
                       operator="terrence", decision_ref="form-x", outcome="confirmed_not_delivered",
                       note="handoff read-back: request.txt absent")
    rc2, out2 = inproc("r_e", "a_e")
    case("CLI: resolution with a wrong envelope key keeps exit 4; exact key lifts the hold; evidence still in unsent()",
         bad_key == "resolve_key_mismatch" and rc_wrong == 4 and good == "resolved" and (rc2, out2) == (0, "dispatched")
         and oda.unsent(c, str(base / "journal")) == ["a_burn"] and oda.unresolved(c, str(base / "journal")) == [])
    c.close(); lc.close()


def operator_cases(base: Path) -> None:
    """revoke()/resolve()/unresolved() on a disposable store: append-only, exact-key, no regrant."""
    c = sqlite3.connect(str(base / "op.db"), isolation_level=None)
    oda.migrate(c); oda.migrate(c)
    H = ("w93:p2", "term_kb1", SESS[KB], 1)
    g = lambda aid, **kw: insert_grant(c, aid, label=KB, project="p", holder=H, rid="r_" + aid, sha="a" * 64,
                                       manifest=["m"], **kw)
    st = lambda aid: c.execute("SELECT status FROM owner_dispatch_auth WHERE auth_id=?", (aid,)).fetchone()[0]
    con = lambda aid, now=T0: oda.consume(c, aid, label=KB, project="p", holder=H, request_id="r_" + aid,
                                          body_sha256="a" * 64, manifest=["m"], now=now)
    rv = lambda aid, now=T0, op="terrence", ref="form-1": oda.revoke(c, aid, operator=op, decision_ref=ref, now=now)
    g("g1"); g("g2"); g("g3", expires=T0 - 1)
    case("REVOKE: unexpired grant -> revoked (denied) and later consume holds auth_denied",
         rv("g1") == "revoked" and st("g1") == "denied" and con("g1") == "auth_denied")
    case("REVOKE: no operator/decision ref -> invalid, grant untouched", rv("g2", op="") == "revoke_invalid"
         and rv("g2", ref="") == "revoke_invalid" and st("g2") == "granted")
    env2 = con("g2")
    case("REVOKE: after consumption -> too_late_consumed (cancellation cannot undo a started action)",
         isinstance(env2, dict) and rv("g2") == "revoke_too_late_consumed" and st("g2") == "consumed")
    case("REVOKE: expired / missing / already revoked -> typed refusal, no record",
         rv("g3") == "revoke_expired" and rv("nope") == "revoke_missing" and rv("g1") == "revoke_denied"
         and c.execute("SELECT COUNT(*) FROM owner_dispatch_operator").fetchone()[0] == 1)
    J = base / "journal"; J.mkdir()
    key = oda.envelope_sha256(env2)
    R = lambda aid, k=key, **kw: oda.resolve(c, aid, envelope_sha256_hex=k, operator=kw.get("op", "terrence"),
                                              decision_ref="form-2", outcome=kw.get("out", "abandoned_uncertain"),
                                              new_request_id=kw.get("nr"), note=kw.get("note", "operator evidence"))
    case("RESOLVE: an outcome without evidence (empty note) is refused", R("g2", note=" ") == "resolve_invalid")
    case("RESOLVE: invalid outcome / not consumed / missing / wrong key -> refused, no record",
         R("g2", out="ok") == "resolve_invalid" and R("g1") == "resolve_not_consumed" and R("nope") == "resolve_missing"
         and R("g2", k=key[::-1]) == "resolve_key_mismatch" and oda.unresolved(c, str(J)) == ["g2"])
    case("RESOLVE: exact key -> resolved; grant unchanged, nothing regranted, duplicate refused",
         R("g2", nr="r_new") == "resolved" and st("g2") == "consumed" and oda.unresolved(c, str(J)) == []
         and oda.unsent(c, str(J)) == ["g2"] and R("g2") == "resolve_duplicate"
         and c.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE request_id='r_new'").fetchone()[0] == 0)
    # a changed envelope after resolution (row tampered) re-opens the hold
    c.execute("UPDATE owner_dispatch_auth SET consumed_at='other' WHERE auth_id='g2'")
    case("RESOLVE: envelope changed after resolution -> hold re-opens (key no longer matches)",
         oda.unresolved(c, str(J)) == ["g2"])
    case("OPERATOR LOG: append-only (UPDATE and DELETE abort)",
         _raises(lambda: c.execute("UPDATE owner_dispatch_operator SET note='x'"))
         and _raises(lambda: c.execute("DELETE FROM owner_dispatch_operator")))
    c.close()


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


def _frozen_gen1_module(ref="1a0b873"):
    """owner-dispatch-issue.py exactly as it existed at `ref` (the commit
    this branch started from), read via `git show` and exec'd IN MEMORY --
    never written to disk, never re-derived from the current file. Used
    only to prove the classic gen1 (claim_initial) path's schema,
    approval_bytes and render_form are byte-identical to that frozen,
    pre-successor baseline."""
    import types
    src = subprocess.run(["git", "show", f"{ref}:owner-dispatch-issue.py"], cwd=HERE, capture_output=True, check=True).stdout
    mod = types.ModuleType(f"odissue_frozen_{ref}")
    mod.__file__ = f"<frozen:{ref}:owner-dispatch-issue.py>"
    exec(compile(src, mod.__file__, "exec"), mod.__dict__)
    return mod


def issue_cases(base: Path) -> None:
    """owner-dispatch-issue.py: trust root = the answered formserve record + served HTML;
    one approval -> expected gen-1 claim + one grant + immutable issuance record."""
    import importlib.util
    import io
    import contextlib
    import time as _t
    spec = importlib.util.spec_from_file_location("odissue", HERE / "owner-dispatch-issue.py")
    odi = importlib.util.module_from_spec(spec); spec.loader.exec_module(odi)
    spec2 = importlib.util.spec_from_file_location("odcli2", HERE / "owner-dispatch.py")
    odc = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(odc)
    now = float(int(_t.time()))
    HOLD = {"pane_id": PANE[KB][0], "pane_birth": PANE[KB][1], "session_digest": SESS[KB]}
    PANE2, SESS2 = ("w93:p9", "term_kb2"), hashlib.sha256(b"kb-session-2").hexdigest()
    HOLD2 = {"pane_id": PANE2[0], "pane_birth": PANE2[1], "session_digest": SESS2}
    reg_ok = {KB: (*PANE[KB], SESS[KB])}.get
    reg_ok2 = {KB: (*PANE2, SESS2)}.get
    body = b"READ-ONLY: list the newest result file name. Write nothing.\n"
    n = [0]

    def setup(max_open=1):
        n[0] += 1
        d = base / f"c{n[0]}"; d.mkdir(mode=0o700)
        lc, av, roots, lease_db = env(d); av.close()
        lc.execute("UPDATE owner_projects SET max_open=? WHERE label=?", (max_open, KB))
        os.chmod(lease_db, 0o600)
        adb = d / "auth.db"
        c = sqlite3.connect(str(adb), isolation_level=None); oda.migrate(c); c.close(); os.chmod(adb, 0o600)
        rq = d / "req"; rq.mkdir(); (rq / "req.txt").write_bytes(body)
        (d / "state" / "forms").mkdir(parents=True)
        proj = lc.execute("SELECT project FROM owner_projects WHERE label=?", (KB,)).fetchone()[0]
        return d, lc, lease_db, adb, rq, roots, proj

    def decision(d, proj, over=None, answers=None, status="answered", answered_at=None, html_extra=b"",
                prev_gen=0, prev_holder=None):
        rec = {"protocol": odi.PROTOCOL, "owner_label": KB, "project": proj, "max_open": 1, "expected_holder": dict(HOLD),
               "expected_generation": prev_gen + 1, "lease_ttl_s": 1800, "request_id": f"kbpilot-{n[0]}",
               "request_name": "req.txt", "request_sha256": hashlib.sha256(body).hexdigest(), "manifest": ["result.md"],
               "auth_id": f"auth-{n[0]}", "grant_window_s": 1800}
        if prev_gen >= 1:
            rec["expected_prev_generation"] = prev_gen
            rec["expected_prev_holder"] = prev_holder
        rec.update(over or {})
        emb = odi.approval_bytes(rec)
        fid = f"20261022T1200{n[0] % 100:02d}-86{n[0] % 100:02d}"
        html = odi.render_form(rec) + html_extra
        ans = {"decision": "approve", "approval_sha256": hashlib.sha256(emb).hexdigest()} if answers is None else answers
        row = {"id": fid, "status": status, "answers": ans, "answered_at": int((now - 60) * 1000) if answered_at is None else answered_at}
        (d / "state" / "forms" / f"{fid}.html").write_bytes(html)
        (d / "state" / "forms" / f"{fid}.json").write_text(json.dumps(row))
        return fid, rec, hashlib.sha256(emb).hexdigest()

    KEYS_ENV = ("HERDR_OWNER_DISPATCH_ISSUE", "HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DELIVERY",
                "HERDR_OWNER_LEASE_DB", "HERDR_OWNER_DISPATCH_AUTH_DB")
    real_root = odi.STATE_ROOT

    def run(d, lease_db, adb, rq, fid, resolve=reg_ok, flags=True, t=None):
        E = {"HERDR_OWNER_DISPATCH_ISSUE": "1", "HERDR_OWNER_LEASE_WRITER": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
             "HERDR_OWNER_LEASE_DB": lease_db, "HERDR_OWNER_DISPATCH_AUTH_DB": str(adb)} if flags else {}
        odi.STATE_ROOT = os.path.realpath(d / "state")   # the pinned root, rebound for the test only
        saved = {k: os.environ.get(k) for k in KEYS_ENV}
        for k in saved: os.environ.pop(k, None)
        os.environ.update(E)
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = odi.main(["--form-id", fid, "--request-dir", str(rq)], resolve=resolve, now=now if t is None else t)
        finally:
            odi.STATE_ROOT = real_root
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return rc, buf.getvalue().strip()

    def q(adb, sql):
        c = sqlite3.connect(str(adb)); r = c.execute(sql).fetchall(); c.close(); return r

    def lease_rows(lc):
        return lc.execute("SELECT COUNT(*) FROM owner_leases").fetchone()[0]

    # happy path: grant + immutable issuance record in one transaction; replay refused; dispatch works
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    first = run(d, ldb, adb, rq, fid)
    again = run(d, ldb, adb, rq, fid)
    iss = q(adb, "SELECT auth_id, approval_sha256, form_id, length(approval_bytes) FROM owner_dispatch_issuance")
    g = q(adb, "SELECT approval_id, prompt_id, expires_at FROM owner_dispatch_auth")
    case("ISSUE: answered form record -> gen-1 claim, one grant + issuance record (approval sha + bytes + form id); replay refused",
         first == (0, f"issued:{rec['auth_id']}:gen1") and again == (2, "refused:approval_already_used")
         and iss == [(rec["auth_id"], asha, fid, iss[0][3])] and iss[0][3] > 100
         and g == [(fid, fid, now - 60 + 1800)] and ol.holder_tuple(lc, KB, now) == (*PANE[KB], SESS[KB], 1))
    ac = sqlite3.connect(str(adb), isolation_level=None)
    case("ISSUE: issuance record is append-only",
         _raises(lambda: ac.execute("UPDATE owner_dispatch_issuance SET approval_sha256=?", ("f" * 64,)))
         and _raises(lambda: ac.execute("DELETE FROM owner_dispatch_issuance")))
    ac.close()
    sent = []
    E = {"HERDR_OWNER_DISPATCH": "1", "HERDR_OWNER_LEASE_DELIVERY": "1", "HERDR_OWNER_LEASE_DB": ldb,
         "HERDR_OWNER_DISPATCH_AUTH_DB": str(adb), "HERDR_RESULT_AVAILABILITY": "1", "HERDR_RESULT_AVAILABILITY_DB": str(d / "ra.db"),
         "HERDR_RESULT_AVAILABILITY_JOURNAL": str(d / "journal"),
         "HERDR_RESULT_AVAILABILITY_ROOTS": f"{KB}={roots[KB]}{os.pathsep}{DOTS}={roots[DOTS]}"}
    saved = {k: os.environ.get(k) for k in E}
    os.environ.update(E)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = odc.main(["--label", KB, "--rid", rec["request_id"], "--request-dir", str(rq), "--request-name", "req.txt",
                           "--auth-id", rec["auth_id"], "--manifest", "result.md"],
                          send=lambda pane, handoff, text: sent.append((pane, text)) or True, resolve=reg_ok)
    finally:
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    case("ISSUE -> DISPATCH: the issued grant dispatches the frozen bytes once through owner-dispatch.py",
         (rc, buf.getvalue().strip()) == (0, "dispatched") and (roots[KB] / rec["request_id"] / ra.REQUEST_FILE).read_bytes() == body)
    lc.close()

    other = hashlib.sha256(b"other").hexdigest()
    for name, kw, want in [
        ("flags off", {"flags": False}, (4, "refused:flags_off")),
        ("form still open", {"status": "open"}, (2, "refused:form_not_answered")),
        ("form expired (unanswered, never a decline)", {"status": "expired"}, (2, "refused:form_not_answered")),
        ("answer declines", {"answers": {"decision": "decline"}}, (2, "refused:form_not_approved")),
        ("answer echoes a different record sha", {"answers": {"decision": "approve", "approval_sha256": other}}, (2, "refused:form_answer_not_bound_to_displayed_record")),
        ("page carries two embedded records", {"html_extra": b'<script type="application/json" id="owner-dispatch-approval">{}</script>'}, (2, "refused:form_html_no_single_embedded_approval")),
        ("approval older than its window", {"answered_at": int((now - 1801) * 1000)}, (2, "refused:approval_expired")),
        ("window over 60 min", {"over": {"grant_window_s": 3601}}, (2, "refused:approval_field_grant_window_s")),
        ("max_open not 1 in record", {"over": {"max_open": 2}}, (2, "refused:approval_max_open_not_1")),
        ("request bytes differ", {"over": {"request_sha256": "0" * 64}}, (2, "refused:request_sha_mismatch")),
        ("generation != 1 (gen1 shape)", {"over": {"expected_generation": 2}}, (2, "refused:approval_generation_not_initial")),
        ("expected_prev_generation negative (successor shape)",
         {"prev_gen": 1, "prev_holder": dict(HOLD2), "over": {"expected_prev_generation": -1}},
         (2, "refused:approval_field_expected_prev_generation")),
        ("expected_prev_holder present without expected_prev_generation (not the frozen gen1 shape)",
         {"over": {"expected_prev_holder": dict(HOLD)}}, (2, "refused:approval_schema")),
        ("successor with no expected_prev_holder", {"prev_gen": 1, "over": {"expected_prev_holder": None}}, (2, "refused:approval_prev_holder_schema")),
        ("successor generation mismatches prev+1", {"prev_gen": 1, "prev_holder": dict(HOLD2), "over": {"expected_generation": 5}},
         (2, "refused:approval_generation_mismatch")),
        ("extra field", {"over": {"note": "x"}}, (2, "refused:approval_schema")),
        ("holder digest differs", {"over": {"expected_holder": {**HOLD, "session_digest": other}}}, (2, "refused:identity_mismatch")),
        ("dead/other owner label", {"over": {"owner_label": DOTS}}, (2, "refused:identity_mismatch")),
        ("project differs", {"over": {"project": "tntpgh/other"}}, (2, "refused:owner_project_mismatch")),
        ("live mapping max_open != 1", {"max_open": 5}, (2, "refused:owner_project_mismatch")),
        ("registry has no session", {"resolve": lambda l: None}, (2, "refused:identity_mismatch")),
    ]:
        d, lc, ldb, adb, rq, roots, proj = setup(max_open=kw.get("max_open", 1))
        fid, rec, asha = decision(d, proj, over=kw.get("over"), answers=kw.get("answers"), status=kw.get("status", "answered"),
                                  answered_at=kw.get("answered_at"), html_extra=kw.get("html_extra", b""),
                                  prev_gen=kw.get("prev_gen", 0), prev_holder=kw.get("prev_holder"))
        got = run(d, ldb, adb, rq, fid, resolve=kw.get("resolve", reg_ok), flags=kw.get("flags", True))
        case(f"ISSUE refused before any write: {name}", got == want and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)]
             and lease_rows(lc) == 0)
        lc.close()
    # caller cannot point at an arbitrary file: only a form id in the canonical forms dir; symlinked record refused
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    fj = d / "state" / "forms" / f"{fid}.json"
    (d / "elsewhere.json").write_bytes(fj.read_bytes()); fj.unlink(); fj.symlink_to(d / "elsewhere.json")
    case("ISSUE: path-like form id and a symlinked record are refused",
         run(d, ldb, adb, rq, "../x")[0] == 2 and run(d, ldb, adb, rq, fid) == (2, "refused:form_unreadable") and lease_rows(lc) == 0)
    lc.close()
    # pinned root: HERDR_STATE_ROOT pointing at another valid answered form is ignored
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    other_root = d / "other"; (other_root / "forms").mkdir(parents=True)
    for ext in (".json", ".html"):
        (other_root / "forms" / f"{fid}{ext}").write_bytes((d / "state" / "forms" / f"{fid}{ext}").read_bytes())
        (d / "state" / "forms" / f"{fid}{ext}").unlink()
    os.environ["HERDR_STATE_ROOT"] = str(other_root)
    try:
        got = run(d, ldb, adb, rq, fid)
    finally:
        os.environ.pop("HERDR_STATE_ROOT", None)
    case("ISSUE: the forms root is pinned; HERDR_STATE_ROOT at another answered form is ignored", got == (2, "refused:form_unreadable") and lease_rows(lc) == 0)
    lc.close()
    import shutil
    def symlink_forms(d):
        real = d / "state" / "real"; real.mkdir()
        for f in (d / "state" / "forms").iterdir():
            (real / f.name).write_bytes(f.read_bytes())
        shutil.rmtree(d / "state" / "forms"); (d / "state" / "forms").symlink_to(real)
    for name, mutate, want in [
        ("symlinked forms dir", symlink_forms, "refused:forms_dir_unsafe_path"),
        ("group-writable forms dir", lambda d: os.chmod(d / "state" / "forms", 0o775), "refused:forms_dir_not_private"),
        ("world-writable ancestor", lambda d: os.chmod(d / "state", 0o777), "refused:forms_dir_unsafe_ancestor"),
        ("group-writable record file", lambda d: [os.chmod(f, 0o664) for f in (d / "state" / "forms").glob("*.json")], "refused:form_file_not_private_regular"),
        ("served page differs from the canonical rendering",
         lambda d: [f.write_bytes(f.read_bytes().replace(b"Approve ONE", b"Approve one")) for f in (d / "state" / "forms").glob("*.html")],
         "refused:form_html_not_canonical_rendering"),
    ]:
        d, lc, ldb, adb, rq, roots, proj = setup()
        fid, rec, asha = decision(d, proj)
        mutate(d)
        got = run(d, ldb, adb, rq, fid)
        case(f"ISSUE refused before any write: {name}", got == (2, want) and lease_rows(lc) == 0
             and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)])
        lc.close()
    d, lc, ldb, adb, rq, roots, proj = setup()
    out = d / "built.html"
    with contextlib.redirect_stdout(io.StringIO()):
        rcb = odi.main(["build-form", "--label", KB, "--project", proj, "--request-dir", str(rq), "--request-name", "req.txt",
                        "--request-id", "kbpilot-b", "--auth-id", "auth-b", "--manifest", "result.md", "--out", str(out)], resolve=reg_ok)
    emb = odi.EMBED.findall(out.read_bytes())[0]
    brec = json.loads(emb)
    fidb = "20261022T120099-8699"
    (d / "state" / "forms" / f"{fidb}.html").write_bytes(out.read_bytes())
    (d / "state" / "forms" / f"{fidb}.json").write_text(json.dumps({"id": fidb, "status": "answered", "answered_at": int((now - 60) * 1000),
        "answers": {"decision": "approve", "approval_sha256": hashlib.sha256(emb).hexdigest()}}))
    case("BUILD-FORM: offline page binds fresh registry holder + request sha (0600), and the issuer accepts exactly it",
         rcb == 0 and (out.stat().st_mode & 0o777) == 0o600 and brec["expected_holder"] == HOLD
         and brec["request_sha256"] == hashlib.sha256(body).hexdigest() and run(d, ldb, adb, rq, fidb) == (0, "issued:auth-b:gen1"))
    with contextlib.redirect_stdout(io.StringIO()):
        rcn = odi.main(["build-form", "--label", KB, "--project", proj, "--request-dir", str(rq), "--request-name", "req.txt",
                        "--request-id", "x", "--auth-id", "y", "--manifest", "result.md", "--out", str(d / "n.html")], resolve=lambda l: None)
    case("BUILD-FORM: unresolved registry identity -> refused, no page", rcn == 2 and not (d / "n.html").exists())
    lc.close()
    # unexpected error BEFORE the claim -> refused, nothing written
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    def raise_first(label):
        raise RuntimeError("registry read failed")
    case("ISSUE: unexpected error before the claim -> refused exit 2, no lease, no grant",
         run(d, ldb, adb, rq, fid, resolve=raise_first) == (2, "refused:error_RuntimeError") and lease_rows(lc) == 0
         and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)])
    lc.close()
    # existing lease never adopted
    d, lc, ldb, adb, rq, roots, proj = setup()
    acquire(lc, KB, now, session=SESS[KB])
    fid, rec, asha = decision(d, proj)
    case("ISSUE: an existing lease is never adopted (not_initial), no grant", run(d, ldb, adb, rq, fid) == (2, "refused:not_initial")
         and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)] and lease_rows(lc) == 1)
    lc.close()
    # identity moves after claim -> claimed_not_issued (grant verified absent)
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    calls = [0]
    def moving(label):
        calls[0] += 1
        return reg_ok(label) if calls[0] == 1 else (PANE[KB][0], "term_new", SESS[KB])
    case("ISSUE: identity changes after the claim -> claimed_not_issued exit 5 (grant verified absent), lease held",
         run(d, ldb, adb, rq, fid, resolve=moving) == (5, "claimed_not_issued:identity_mismatch")
         and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)] and lease_rows(lc) == 1)
    lc.close()
    # resolver raises after claim -> unexpected error classified by the store: absent but not a Refused -> issue_uncertain
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    calls2 = [0]
    def boom(label):
        calls2[0] += 1
        if calls2[0] == 1:
            return reg_ok(label)
        raise RuntimeError("registry read failed")
    case("ISSUE: unexpected error after the claim -> issue_uncertain exit 6, never 'unissued', no grant, lease held",
         run(d, ldb, adb, rq, fid, resolve=boom) == (6, "issue_uncertain:error_RuntimeError:store_absent") and lease_rows(lc) == 1)
    lc.close()
    # commit raises but the row landed -> reported issued (verified), not unissued
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    real_insert = odi.insert_grant
    def insert_then_fail(store, dec, exp):
        real_insert(store, dec, exp)
        raise sqlite3.OperationalError("disk I/O error after commit")
    odi.insert_grant = insert_then_fail
    try:
        got = run(d, ldb, adb, rq, fid)
    finally:
        odi.insert_grant = real_insert
    case("ISSUE: error after a commit that landed -> verified 'issued' (exit 0), never reported unissued",
         got[0] == 0 and got[1].startswith(f"issued:{rec['auth_id']}:gen1 (after error_OperationalError")
         and q(adb, "SELECT COUNT(*) FROM owner_dispatch_issuance") == [(1,)])
    lc.close()
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    def insert_wrong_then_fail(store, dec, exp):
        real_insert(store, dec, exp + 1)
        raise sqlite3.OperationalError("disk I/O error after commit")
    odi.insert_grant = insert_wrong_then_fail
    try:
        got = run(d, ldb, adb, rq, fid)
    finally:
        odi.insert_grant = real_insert
    case("ISSUE: a stored grant that differs from the complete expected tuple -> issue_uncertain store_unknown, never issued",
         got == (6, "issue_uncertain:error_OperationalError:store_unknown"))
    lc.close()
    # error where the store cannot be read back -> issue_uncertain store_unknown
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    real_gs = odi.grant_state
    def fail_insert(store, dec, exp):
        raise sqlite3.OperationalError("database is locked")
    odi.insert_grant, odi.grant_state = fail_insert, (lambda db, dec, exp: "unknown")
    try:
        got = run(d, ldb, adb, rq, fid)
    finally:
        odi.insert_grant, odi.grant_state = real_insert, real_gs
    case("ISSUE: failed issue with unreadable store -> issue_uncertain exit 6 store_unknown",
         got == (6, "issue_uncertain:error_OperationalError:store_unknown"))
    lc.close()

    # --- SUCCESSOR CLAIM (claim_successor via owner-dispatch-issue.py) ---
    # live predecessor: refused, no second row, no grant
    d, lc, ldb, adb, rq, roots, proj = setup()
    acquire(lc, KB, now - 10)  # gen1, PANE[KB]/SESS[KB], still live (TTL 3600)
    fid, rec, asha = decision(d, proj, prev_gen=1, prev_holder=dict(HOLD), over={"expected_holder": dict(HOLD2)})
    case("SUCCESSOR: live predecessor refused, no second lease row, no grant",
         run(d, ldb, adb, rq, fid, resolve=reg_ok2) == (2, "refused:successor_live_predecessor")
         and lease_rows(lc) == 1 and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)])
    lc.close()

    # wrong prev generation vs the actual (expired) predecessor
    d, lc, ldb, adb, rq, roots, proj = setup()
    acquire(lc, KB, now - TTL - 100)  # gen1, expired
    fid, rec, asha = decision(d, proj, prev_gen=2, prev_holder=dict(HOLD), over={"expected_holder": dict(HOLD2)})
    case("SUCCESSOR: expected_prev_generation != actual predecessor generation refused",
         run(d, ldb, adb, rq, fid, resolve=reg_ok2) == (2, "refused:successor_wrong_prev_generation")
         and lease_rows(lc) == 1 and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)])
    lc.close()

    # correct generation but the approval's expected_prev_holder no longer matches
    # the real predecessor at that generation (stale/forged form content)
    d, lc, ldb, adb, rq, roots, proj = setup()
    acquire(lc, KB, now - TTL - 100)  # gen1, PANE[KB]/SESS[KB] (HOLD), expired
    fid, rec, asha = decision(d, proj, prev_gen=1, prev_holder=dict(HOLD2), over={"expected_holder": dict(HOLD2)})
    case("SUCCESSOR: expected_prev_holder no longer matches the real predecessor (same generation) refused, zero writes",
         run(d, ldb, adb, rq, fid, resolve=reg_ok2) == (2, "refused:successor_prev_holder_mismatch")
         and lease_rows(lc) == 1 and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)]
         and lc.execute("SELECT released_at FROM owner_leases WHERE generation=1").fetchone()[0] is None)
    lc.close()

    # same generation, same pane_id/pane_birth, but a DIFFERENT session digest
    # (a renewal under the same pane with a new session) -- refused, zero writes, no grant
    d, lc, ldb, adb, rq, roots, proj = setup()
    acquire(lc, KB, now - TTL - 100)  # gen1, PANE[KB]/SESS[KB] (HOLD), expired
    stale_sess = hashlib.sha256(b"stale-predecessor-session").hexdigest()
    fid, rec, asha = decision(d, proj, prev_gen=1, prev_holder={**HOLD, "session_digest": stale_sess},
                              over={"expected_holder": dict(HOLD2)})
    case("SUCCESSOR: same generation/pane/birth but a changed session digest refused, zero writes, no grant",
         run(d, ldb, adb, rq, fid, resolve=reg_ok2) == (2, "refused:successor_prev_holder_mismatch")
         and lease_rows(lc) == 1 and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)]
         and lc.execute("SELECT released_at FROM owner_leases WHERE generation=1").fetchone()[0] is None)
    lc.close()

    # open owner_requests: refused rather than silently staled
    d, lc, ldb, adb, rq, roots, proj = setup()
    g1 = acquire(lc, KB, now - TTL - 100)
    ol.enqueue(lc, KB, g1, *PANE[KB], "open-req-1", now=now - TTL - 100)
    fid, rec, asha = decision(d, proj, prev_gen=1, prev_holder=dict(HOLD), over={"expected_holder": dict(HOLD2)})
    case("SUCCESSOR: open owner_requests refused, request left open (not staled)",
         run(d, ldb, adb, rq, fid, resolve=reg_ok2) == (2, "refused:successor_open_requests")
         and lease_rows(lc) == 1
         and lc.execute("SELECT state FROM owner_requests WHERE request_id='open-req-1'").fetchone()[0] == "queued")
    lc.close()

    # new holder == predecessor holder: refused
    d, lc, ldb, adb, rq, roots, proj = setup()
    acquire(lc, KB, now - TTL - 100, session=SESS2, pane=PANE2)  # gen1, expired, held by PANE2/SESS2
    fid, rec, asha = decision(d, proj, prev_gen=1, prev_holder=dict(HOLD2), over={"expected_holder": dict(HOLD2)})
    case("SUCCESSOR: new holder equal to the predecessor holder refused",
         run(d, ldb, adb, rq, fid, resolve=reg_ok2) == (2, "refused:successor_same_holder")
         and lease_rows(lc) == 1)
    lc.close()

    # happy path: expired predecessor released (row kept) and gen2 claimed + grant issued
    d, lc, ldb, adb, rq, roots, proj = setup()
    acquire(lc, KB, now - TTL - 100)  # gen1, PANE[KB]/SESS[KB], expired
    fid, rec, asha = decision(d, proj, prev_gen=1, prev_holder=dict(HOLD), over={"expected_holder": dict(HOLD2)})
    got = run(d, ldb, adb, rq, fid, resolve=reg_ok2)
    case("SUCCESSOR: expired predecessor released (row kept) -> gen2 claimed, one grant issued",
         got == (0, f"issued:{rec['auth_id']}:gen2") and lease_rows(lc) == 2
         and lc.execute("SELECT label, released_at IS NOT NULL, release_reason FROM owner_leases WHERE generation=1").fetchone()
             == (KB, 1, "expired")
         and ol.holder_tuple(lc, KB, now) == (*PANE2, SESS2, 2)
         and q(adb, "SELECT lease_generation FROM owner_dispatch_auth") == [(2,)])
    lc.close()

    # BUILD-FORM successor: resolves the EXPIRED predecessor's identity from --lease-db
    d, lc, ldb, adb, rq, roots, proj = setup()
    acquire(lc, KB, now - TTL - 100)  # gen1, PANE[KB]/SESS[KB], expired
    out = d / "built-successor.html"
    with contextlib.redirect_stdout(io.StringIO()):
        rcb = odi.main(["build-form", "--label", KB, "--project", proj, "--request-dir", str(rq), "--request-name", "req.txt",
                        "--request-id", "kbpilot-succ", "--auth-id", "auth-succ", "--manifest", "result.md",
                        "--expected-prev-generation", "1", "--lease-db", ldb, "--out", str(out)], resolve=reg_ok2)
    emb = odi.EMBED.findall(out.read_bytes())[0]
    brec = json.loads(emb)
    fidb = "20261022T120098-8698"
    (d / "state" / "forms" / f"{fidb}.html").write_bytes(out.read_bytes())
    (d / "state" / "forms" / f"{fidb}.json").write_text(json.dumps({"id": fidb, "status": "answered", "answered_at": int((now - 60) * 1000),
        "answers": {"decision": "approve", "approval_sha256": hashlib.sha256(emb).hexdigest()}}))
    case("BUILD-FORM successor: resolves the expired predecessor's identity, generation N+1, issuer accepts it",
         rcb == 0 and brec["expected_prev_generation"] == 1 and brec["expected_prev_holder"] == HOLD
         and brec["expected_generation"] == 2 and brec["expected_holder"] == HOLD2
         and run(d, ldb, adb, rq, fidb, resolve=reg_ok2) == (0, "issued:auth-succ:gen2"))
    lc.close()

    # --- FROZEN COMPAT (1a0b873): classic gen1 shape is byte-identical to the pre-successor baseline ---
    frozen = _frozen_gen1_module()
    d, lc, ldb, adb, rq, roots, proj = setup()
    fid, rec, asha = decision(d, proj)  # prev_gen=0 default -> classic shape, no successor keys at all
    case("FROZEN COMPAT (1a0b873): classic gen1 KEYS/approval_bytes/render_form byte-identical to the frozen baseline",
         set(rec) == frozen.KEYS
         and frozen.validate_approval(dict(rec)) == rec
         and frozen.approval_bytes(rec) == odi.approval_bytes(rec)
         and frozen.render_form(rec) == odi.render_form(rec))
    frozen_successor = _frozen_gen1_module(ref="0ac8ba1f7f5431899819b3a7fd1713957e965bb8")  # SUCCESSOR_KEYS postdates 1a0b873
    saved_root = odi.STATE_ROOT
    odi.STATE_ROOT = os.path.realpath(d / "state")
    try:
        dec_default = odi.read_decision(fid)  # DEFAULT kwargs: the standing extension must not change this
    finally:
        odi.STATE_ROOT = saved_root
    case("STANDING EXTENSION DID NOT CHANGE SINGLE-USE: read_decision()'s default kwargs still select "
         "validate_approval/render_form, window() still reads grant_window_s with no key kwarg, "
         "MAX_WINDOW_S and KEYS are unchanged",
         dec_default["rec"] == rec
         and odi.window(dec_default, now) == dec_default["answered_at"] + rec["grant_window_s"]
         and odi.MAX_WINDOW_S == 3600 and odi.KEYS == frozen.KEYS and odi.SUCCESSOR_KEYS == frozen_successor.SUCCESSOR_KEYS)
    lc.close()


def standing_issue_cases(base: Path) -> None:
    """owner-dispatch-issue.py issue-standing: SEPARATE record kind
    (STANDING_PROTOCOL/STANDING_KEYS), reusing read_decision parameterized
    but NO lease claim -- only reconfirms the ALREADY-LIVE holder/generation,
    then writes one kind='standing' row + issuance record in ONE transaction
    via lib/owner_dispatch_auth, against an ALREADY-migrated store: the
    issuer never migrates; a v1 store is refused. The signed queue_items
    must equal the canonical derivation from the EXACT queue bytes."""
    import importlib.util
    import io
    import contextlib
    import time as _t
    spec = importlib.util.spec_from_file_location("odissue_standing", HERE / "owner-dispatch-issue.py")
    odi = importlib.util.module_from_spec(spec); spec.loader.exec_module(odi)
    now = float(int(_t.time()))
    HOLD = {"pane_id": PANE[KB][0], "pane_birth": PANE[KB][1], "session_digest": SESS[KB]}
    reg_ok = {KB: (*PANE[KB], SESS[KB])}.get
    items = [{"id": "i1", "request": "do one\n", "auth_id": "standing-auth", "manifest": ["result.md"]},
             {"id": "i2", "request": "do two\n", "auth_id": "standing-auth", "manifest": ["result.md"], "cost_cents": 40}]
    queue_bytes = json.dumps(items).encode()
    queue_sha = hashlib.sha256(queue_bytes).hexdigest()
    canon_items = [{"id": it["id"], "request_sha256": hashlib.sha256(it["request"].encode()).hexdigest(),
                    "manifest": list(it.get("manifest", [])), "cost_cents": it.get("cost_cents"),
                    "action": "hold" if it.get("hold") else "dispatch"} for it in items]
    assert odi.canonical_queue_items(queue_bytes) == canon_items  # the test's own derivation matches the real one
    n = [0]

    def setup(migrated=True):
        n[0] += 1
        d = base / f"s{n[0]}"; d.mkdir(mode=0o700)
        lc, av, roots, lease_db = env(d); av.close()
        os.chmod(lease_db, 0o600)
        acquire(lc, KB, now=now - 10)   # the lane's holder is ALREADY live -- issue-standing claims nothing
        adb = d / "auth.db"
        ac0 = sqlite3.connect(str(adb), isolation_level=None)
        if migrated:
            oda.migrate(ac0)   # a SEPARATE, separately-approved setup step -- issue-standing never does this itself
        else:
            for stmt in oda.MIGRATIONS[1]:   # a genuinely v1-only store (no schema_version table at all)
                ac0.execute(stmt)
        ac0.close()
        os.chmod(adb, 0o600)
        qd = d / "q"; qd.mkdir(); (qd / "q.json").write_bytes(queue_bytes)
        (d / "state" / "forms").mkdir(parents=True)
        proj = lc.execute("SELECT project FROM owner_projects WHERE label=?", (KB,)).fetchone()[0]
        return d, lc, lease_db, adb, qd, roots, proj

    def decision(d, proj, over=None, answers=None, status="answered", answered_at=None, html_extra=b""):
        rec = {"protocol": odi.STANDING_PROTOCOL, "owner_label": KB, "project": proj, "expected_holder": dict(HOLD),
               "expected_generation": 1, "queue_sha256": queue_sha, "queue_items": [dict(it) for it in canon_items],
               "item_cap": 5, "spend_cap_cents": 100, "auth_id": f"standing-auth-{n[0]}", "standing_window_s": 1800}
        rec.update(over or {})
        emb = odi.approval_bytes(rec)
        fid = f"20261024T1300{n[0] % 100:02d}-91{n[0] % 100:02d}"
        html = odi.render_standing_form(rec) + html_extra
        ans = {"decision": "approve", "approval_sha256": hashlib.sha256(emb).hexdigest()} if answers is None else answers
        row = {"id": fid, "status": status, "answers": ans, "answered_at": int((now - 60) * 1000) if answered_at is None else answered_at}
        (d / "state" / "forms" / f"{fid}.html").write_bytes(html)
        (d / "state" / "forms" / f"{fid}.json").write_text(json.dumps(row))
        return fid, rec, hashlib.sha256(emb).hexdigest()

    KEYS_ENV = ("HERDR_OWNER_DISPATCH_ISSUE", "HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DELIVERY",
                "HERDR_OWNER_LEASE_DB", "HERDR_OWNER_DISPATCH_AUTH_DB")
    real_root = odi.STATE_ROOT

    def run(d, lease_db, adb, qd, fid, resolve=reg_ok, flags=True, t=None):
        E = {"HERDR_OWNER_DISPATCH_ISSUE": "1", "HERDR_OWNER_LEASE_WRITER": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
             "HERDR_OWNER_LEASE_DB": lease_db, "HERDR_OWNER_DISPATCH_AUTH_DB": str(adb)} if flags else {}
        odi.STATE_ROOT = os.path.realpath(d / "state")
        saved = {k: os.environ.get(k) for k in KEYS_ENV}
        for k in saved: os.environ.pop(k, None)
        os.environ.update(E)
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = odi.main(["issue-standing", "--form-id", fid, "--queue-dir", str(qd), "--queue-name", "q.json"],
                              resolve=resolve, now=now if t is None else t)
        finally:
            odi.STATE_ROOT = real_root
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return rc, buf.getvalue().strip()

    def q(adb, sql, params=()):
        c = sqlite3.connect(str(adb)); r = c.execute(sql, params).fetchall(); c.close(); return r

    def lease_rows(lc):
        return lc.execute("SELECT COUNT(*) FROM owner_leases").fetchone()[0]

    # happy path: standing row + immutable issuance record in ONE transaction, NO lease claim; replay refused
    d, lc, ldb, adb, qd, roots, proj = setup()
    before_leases = lease_rows(lc)
    fid, rec, asha = decision(d, proj)
    first = run(d, ldb, adb, qd, fid)
    again = run(d, ldb, adb, qd, fid)
    g = q(adb, "SELECT kind, status, queue_sha256, item_cap, spend_cap_cents, used_count, spent_cents,"
              " pane_id, pane_birth, session_digest, lease_generation FROM owner_dispatch_auth WHERE auth_id=?",
          (rec["auth_id"],))
    iss = q(adb, "SELECT auth_id, approval_sha256, form_id FROM owner_dispatch_issuance WHERE auth_id=?", (rec["auth_id"],))
    case("STANDING ISSUE: answered standing form -> one kind='standing' row + issuance record; NO lease claimed; replay refused",
         first == (0, f"issued:{rec['auth_id']}") and again == (2, "refused:approval_already_used")
         and g == [("standing", "granted", queue_sha, 5, 100, 0, 0, *PANE[KB], SESS[KB], 1)]
         and iss == [(rec["auth_id"], asha, fid)]
         and lease_rows(lc) == before_leases)
    lc.close()

    # the issued standing row is then consumable by consume_standing, exactly like any other standing grant
    d, lc, ldb, adb, qd, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    run(d, ldb, adb, qd, fid)
    ac = sqlite3.connect(str(adb), isolation_level=None)
    child = oda.consume_standing(ac, rec["auth_id"], label=KB, project=proj, holder=(*PANE[KB], SESS[KB], 1),
                                 request_id="i2", body_sha256="b" * 64, manifest=["result.md"], now=now,
                                 queue_sha256=queue_sha, cost_cents=40)
    case("STANDING ISSUE -> CONSUME: the real issued row dispatches a child through the real consume_standing",
         isinstance(child, dict) and child["request_id"] == "i2" and child["lease_generation"] == 1)
    ac.close(); lc.close()

    other = hashlib.sha256(b"other").hexdigest()
    for name, kw, want in [
        ("flags off", {"flags": False}, (4, "refused:flags_off")),
        ("form still open", {"status": "open"}, (2, "refused:form_not_answered")),
        ("answer declines", {"answers": {"decision": "decline"}}, (2, "refused:form_not_approved")),
        ("answer echoes a different record sha (tampered approval_sha256)",
         {"answers": {"decision": "approve", "approval_sha256": other}},
         (2, "refused:form_answer_not_bound_to_displayed_record")),
        ("page carries two embedded records (tampered HTML)",
         {"html_extra": b'<script type="application/json" id="owner-dispatch-approval">{}</script>'},
         (2, "refused:form_html_no_single_embedded_approval")),
        ("approval older than its own standing window", {"answered_at": int((now - 1801) * 1000)},
         (2, "refused:approval_expired")),
        ("standing window over its own cap (86400s)", {"over": {"standing_window_s": 86401}},
         (2, "refused:standing_approval_field_standing_window_s")),
        ("spend_cap_cents negative", {"over": {"spend_cap_cents": -1}},
         (2, "refused:standing_approval_field_spend_cap_cents")),
        ("item_cap not a positive int", {"over": {"item_cap": 0}}, (2, "refused:standing_approval_field_item_cap")),
        ("extra field", {"over": {"note": "x"}}, (2, "refused:standing_approval_schema")),
        ("holder digest differs", {"over": {"expected_holder": {**HOLD, "session_digest": other}}},
         (2, "refused:identity_mismatch")),
        ("project differs", {"over": {"project": "tntpgh/other"}}, (2, "refused:owner_project_mismatch")),
        ("registry has no session", {"resolve": lambda l: None}, (2, "refused:identity_mismatch")),
    ]:
        d, lc, ldb, adb, qd, roots, proj = setup()
        fid, rec, asha = decision(d, proj, over=kw.get("over"), answers=kw.get("answers"), status=kw.get("status", "answered"),
                                  answered_at=kw.get("answered_at"), html_extra=kw.get("html_extra", b""))
        got = run(d, ldb, adb, qd, fid, resolve=kw.get("resolve", reg_ok), flags=kw.get("flags", True))
        case(f"STANDING ISSUE refused before any write: {name}", got == want
             and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)]
             and lease_rows(lc) == 1)
        lc.close()

    # spend_cap_cents REQUIRED, not defaulted: a literal missing key is refused, never treated as 0/unbounded
    d, lc, ldb, adb, qd, roots, proj = setup()
    fid, rec, asha = decision(d, proj)
    del_rec = dict(rec); del del_rec["spend_cap_cents"]
    emb = odi.approval_bytes(del_rec)
    fid2 = f"20261024T1301{n[0] % 100:02d}-92{n[0] % 100:02d}"
    html2 = odi.render_standing_form(del_rec)
    ans2 = {"decision": "approve", "approval_sha256": hashlib.sha256(emb).hexdigest()}
    row2 = {"id": fid2, "status": "answered", "answers": ans2, "answered_at": int((now - 60) * 1000)}
    (d / "state" / "forms" / f"{fid2}.html").write_bytes(html2)
    (d / "state" / "forms" / f"{fid2}.json").write_text(json.dumps(row2))
    got_missing = run(d, ldb, adb, qd, fid2)
    case("STANDING ISSUE: spend_cap_cents REQUIRED -- a literally missing key is refused, never defaulted",
         got_missing == (2, "refused:standing_approval_schema")
         and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)])
    lc.close()

    # queue sha mismatch: the REAL queue bytes on disk differ from what the approval named
    d, lc, ldb, adb, qd, roots, proj = setup()
    (qd / "q.json").write_bytes(json.dumps(items + [{"id": "i3", "request": "three\n", "auth_id": "standing-auth"}]).encode())
    fid, rec, asha = decision(d, proj)   # approval still names the ORIGINAL 2-item queue_sha256
    got_sha = run(d, ldb, adb, qd, fid)
    case("STANDING ISSUE: the live queue file no longer matches the approved queue_sha256 -> refused, nothing written",
         got_sha == (2, "refused:queue_sha_mismatch") and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)])
    lc.close()

    # (1) the signed queue_items must EQUAL the canonical derivation from the EXACT queue bytes -- a
    # caller cannot show one queue (hash matches) and sign a record naming different displayed items.
    d, lc, ldb, adb, qd, roots, proj = setup()
    tampered = [dict(canon_items[0]), {**canon_items[1], "cost_cents": 999}]
    fid, rec, asha = decision(d, proj, over={"queue_items": tampered})
    got_items = run(d, ldb, adb, qd, fid)
    case("STANDING ISSUE: signed queue_items differs from the canonical derivation of the EXACT queue bytes "
         "(queue_sha256 still matches) -> refused, nothing written",
         got_items == (2, "refused:queue_items_mismatch") and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)])
    lc.close()

    # (2) issue-standing NEVER migrates: a v1 store is refused with a typed config refusal, BEFORE any
    # write; the store's schema is byte-identical before and after (migration stays a separate setup step).
    d, lc, ldb, adb, qd, roots, proj = setup(migrated=False)
    fid, rec, asha = decision(d, proj)
    before_schema = q(adb, "SELECT type, name, sql FROM sqlite_master ORDER BY name")
    got_v1 = run(d, ldb, adb, qd, fid)
    after_schema = q(adb, "SELECT type, name, sql FROM sqlite_master ORDER BY name")
    case("STANDING ISSUE: a v1 (unmigrated) store is refused with a typed config refusal before any write; "
         "sqlite_master (incl. no version table) is byte-identical before and after",
         got_v1 == (4, "refused:auth_store_not_migrated")
         and before_schema == after_schema
         and not any(r[1] == "owner_dispatch_auth_schema_version" for r in before_schema)
         and q(adb, "SELECT COUNT(*) FROM owner_dispatch_auth") == [(0,)])
    lc.close()

    # (3) atomicity: a failure injected BETWEEN the parent-row insert and the issuance-record insert
    # rolls back BOTH (neither present); standing_grant_state reports present/absent correctly either way.
    d, lc, ldb, adb, qd, roots, proj = setup()
    ac = sqlite3.connect(str(adb), isolation_level=None)
    oda.migrate(ac)

    def fixture_dec(fid, rec):
        eb = odi.approval_bytes(rec)
        return {"rec": rec, "approval_bytes": eb, "approval_sha256": hashlib.sha256(eb).hexdigest(),
               "form_id": fid, "answered_at": now - 60, "form_record_sha256": "f" * 64, "form_html_sha256": "h" * 64}

    n[0] += 1
    rec_ok = {"protocol": odi.STANDING_PROTOCOL, "owner_label": KB, "project": proj, "expected_holder": dict(HOLD),
              "expected_generation": 1, "queue_sha256": queue_sha, "queue_items": [dict(it) for it in canon_items],
              "item_cap": 5, "spend_cap_cents": 100, "auth_id": f"standing-atomic-ok-{n[0]}", "standing_window_s": 1800}
    dec_ok = fixture_dec(f"fid-atomic-ok-{n[0]}", rec_ok)
    odi.insert_standing_grant(ac, dec_ok, now + 1800)
    case("ATOMICITY baseline: a normal insert_standing_grant succeeds; standing_grant_state reports 'present'",
         odi.standing_grant_state(str(adb), dec_ok, now + 1800) == "present")

    n[0] += 1
    rec_bad = {**rec_ok, "auth_id": f"standing-atomic-bad-{n[0]}"}
    fid_bad = f"fid-atomic-bad-{n[0]}"
    dec_bad = fixture_dec(fid_bad, rec_bad)
    # pre-occupy the UNIQUE(form_id) slot in owner_dispatch_issuance with a DIFFERENT auth_id: the
    # parent-row insert into owner_dispatch_auth still succeeds; the issuance insert then collides.
    ac.execute("INSERT INTO owner_dispatch_issuance(auth_id, approval_sha256, approval_bytes, form_id,"
              " form_record_sha256, form_html_sha256, answered_at, issued_at) VALUES (?,?,?,?,?,?,?,?)",
              ("someone-else", "a" * 64, b"x", fid_bad, "b" * 64, "c" * 64, now - 100, "2026-01-01T00:00:00Z"))
    raised = None
    try:
        odi.insert_standing_grant(ac, dec_bad, now + 1800)
    except Exception as exc:  # noqa: BLE001
        raised = exc
    gcount = ac.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE auth_id=?", (rec_bad["auth_id"],)).fetchone()[0]
    icount = ac.execute("SELECT COUNT(*) FROM owner_dispatch_issuance WHERE auth_id=?", (rec_bad["auth_id"],)).fetchone()[0]
    case("ATOMICITY: a failure injected between the parent-row insert and the issuance-record insert "
         "rolls back BOTH inserts (one transaction, neither row present)",
         raised is not None and gcount == 0 and icount == 0)
    case("ATOMICITY: standing_grant_state correctly reports 'unknown' after the rolled-back attempt "
         "(another issuance row with the same form_id still exists)",
         odi.standing_grant_state(str(adb), dec_bad, now + 1800) == "unknown")
    ac.close(); lc.close()



if __name__ == "__main__":
    sys.exit(main())
