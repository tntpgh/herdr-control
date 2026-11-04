#!/usr/bin/env python3
"""Offline proof of the WEEKLY PROJECT ENVELOPE (owner-dispatch-approval-weekly/1,
default OFF): lib/owner_dispatch_auth.consume_envelope / revoke_envelope,
queue-supervisor.py EnvelopeDispatch + the pending-approval race fix,
owner-dispatch-issue.py build-weekly-form / issue-weekly / consume-pending /
revoke-envelope, factory-status.py's envelope view.

Disposable temp stores only; the REAL Dispatcher / DeliveryGate / result_availability
fences run, the sender is an in-process recorder. No herdr, no pane, no network.
Every control is proven on a real NEGATIVE (the refused input) next to the
positive that shows the same path works; tmp/red-mutations.py additionally
disables each control in a copy of the source and shows these checks go red."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import approval_pending  # noqa: E402
import kill_switch  # noqa: E402
import owner_dispatch_auth as oda  # noqa: E402
import owner_lease as ol  # noqa: E402
import owner_lease_delivery as old  # noqa: E402
import queue_supervisor as qs  # noqa: E402
import result_availability as ra  # noqa: E402


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, HERE / fname)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cli = _load("qs_cli", "queue-supervisor.py")
odi = _load("odi_weekly", "owner-dispatch-issue.py")
FS = _load("fs_weekly", "factory-status.py")

fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


ON = {qs.ENV_FLAG: "1"}
TTL = 7200
M = ["result.md"]
base = Path(os.path.realpath(tempfile.mkdtemp()))
os.chmod(base, 0o700)
kill_switch.ENVELOPE_REVOKE_DIR = str(base / "envelope-revoked")
cli.FORMS_DIR = str(base / "forms-qs")
(base / "forms-qs").mkdir()
NOW = time.time()
WEEK = 7 * 86400

lease_db = str(base / "lease.db")
lc = ol.connect(lease_db)
ol.migrate(lc)
os.chmod(lease_db, 0o600)
auth_db = str(base / "auth.db")
store = sqlite3.connect(auth_db, isolation_level=None, timeout=10)
oda.migrate(store)
os.chmod(auth_db, 0o600)
(base / "journal").mkdir()
qroot = base / "queue"
qroot.mkdir(mode=0o700)
roots: dict = {}
PANE: dict = {}
SESS: dict = {}
REG: dict = {}
(base / "root-seed").mkdir()
av = ra.Availability(str(base / "ra.db"), {"seed": str(base / "root-seed")}, str(base / "journal"))
gate = old.DeliveryGate(lease_db)


class Sender:
    def __init__(self):
        self.calls = []

    def __call__(self, label, holder, text):
        self.calls.append((label, tuple(holder), text))
        return True

    def count(self, label):
        return sum(c[0] == label for c in self.calls)


send = Sender()
notes: list = []


def lane(lb, n):
    """A fresh live lane: registered owner, live lease, result root, registry identity."""
    PANE[lb] = (f"wE:p{n}", f"term_{lb.replace('-', '')}")
    SESS[lb] = hashlib.sha256(f"session-{lb}".encode()).hexdigest()
    ol.register_owner(lc, lb, f"tntpgh/{lb}", now=time.time())
    ol.acquire(lc, lb, *PANE[lb], TTL, time.time(), session_digest=SESS[lb])
    REG[lb] = (*PANE[lb], SESS[lb])
    roots[lb] = base / f"root-{lb}"
    roots[lb].mkdir()
    av.roots[lb] = str(roots[lb])


def project(lb):
    return lc.execute("SELECT project FROM owner_projects WHERE label=?", (lb,)).fetchone()[0]


def holder(lb):
    return ol.holder_tuple(lc, lb, time.time())


POLICY = {"templates": [{"name": "kb-report", "request_prefix": "WEEKLY-KB: ", "manifest_allow": M,
                          "max_request_bytes": 2000}],
          "max_per_day": 10, "max_per_week": 50, "per_item_cap_cents": 100, "total_cap_cents": 10000}
_n = [0]


def mk_dec(lb, aid, policy, window=WEEK, hold=None, answered=None):
    pane, birth, sess, gen = hold or holder(lb)
    rec = {"protocol": odi.WEEKLY_PROTOCOL, "owner_label": lb, "project": project(lb),
           "expected_holder": {"pane_id": pane, "pane_birth": birth, "session_digest": sess},
           "expected_generation": gen, "auth_id": aid, "policy": policy, "envelope_window_s": window}
    odi.validate_weekly_approval(rec)
    eb = odi.approval_bytes(rec)
    _n[0] += 1
    return {"rec": rec, "approval_bytes": eb, "approval_sha256": hashlib.sha256(eb).hexdigest(),
            "form_id": f"20261104T1200{_n[0] % 100:02d}-91{_n[0] % 100:02d}-{_n[0]}",
            "answered_at": (answered or NOW) - 60, "form_record_sha256": "f" * 64, "form_html_sha256": "e" * 64}


def envelope(lb, aid, policy=None, window=WEEK, exp=None):
    """Issue an envelope through the REAL writer (odi.insert_weekly_grant)."""
    dec = mk_dec(lb, aid, policy or POLICY, window)
    odi.insert_weekly_grant(store, dec, exp if exp is not None else dec["answered_at"] + window)
    return aid


def consume(aid, lb, rid, text, *, cost=10, man=M, now=None, hold=None, revoked=kill_switch.envelope_revoked,
            label=None, lease=None):
    return oda.consume_envelope(store, aid, label=label or lb, project=project(lb), holder=hold or holder(lb),
                                request_id=rid, request_text=text.encode(), manifest=man,
                                now=NOW if now is None else now, lease_conn=lease or lc, cost_cents=cost,
                                revoked=revoked)


def refused_with(fn):
    try:
        fn()
    except Exception as exc:  # noqa: BLE001  a crash is a distinct, non-matching answer, never a pass
        return str(exc) if isinstance(exc, odi.Refused) else f"crash:{type(exc).__name__}"
    return None

def standing_rec(lb, aid, window=1800):
    pane, birth, sess, gen = holder(lb)
    return {"protocol": odi.STANDING_PROTOCOL, "owner_label": lb, "project": project(lb),
            "expected_holder": {"pane_id": pane, "pane_birth": birth, "session_digest": sess},
            "expected_generation": gen, "queue_sha256": "0" * 64, "queue_items": [], "item_cap": 1,
            "spend_cap_cents": 0, "auth_id": aid, "standing_window_s": window}

def n_children(aid):
    return store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE parent=?", (aid,)).fetchone()[0]


# ===== A. consume_envelope: policy, caps, expiry, kill switch (unit) =====
UL = "proj-unit"
lane(UL, 0)
A1 = envelope(UL, "env-unit-1")
c1 = consume(A1, UL, "r1", "WEEKLY-KB: summarise week 1\n")
row = store.execute("SELECT kind,parent,request_id,body_sha256,status,spent_cents,approval_id FROM owner_dispatch_auth"
                    " WHERE auth_id=?", (c1["auth_id"],)).fetchone() if isinstance(c1, dict) else None
check("POSITIVE: an on-policy item mints a CHILD bound to (item rid, request sha, envelope parent, cost)",
      isinstance(c1, dict) and c1["auth_id"].startswith("env-unit-1:")
      and row == ("single", "env-unit-1", "r1", hashlib.sha256(b"WEEKLY-KB: summarise week 1\n").hexdigest(),
                  "consumed", 10, store.execute("SELECT approval_id FROM owner_dispatch_envelope WHERE auth_id='env-unit-1'"
                                                ).fetchone()[0]))
check("DUPLICATE: the same item rid twice -> envelope_consumed, still one child",
      consume(A1, UL, "r1", "WEEKLY-KB: summarise week 1\n") == "envelope_consumed" and n_children(A1) == 1)

# --- off-policy items are refused (never run) ---
before = n_children(A1)
check("OFF-POLICY: request text matching no template prefix -> policy_template",
      consume(A1, UL, "bad1", "rm -rf /; WEEKLY-KB: sneaky\n") == "policy_template")
check("OFF-POLICY: prefix must be a PREFIX, not a substring -> policy_template",
      consume(A1, UL, "bad1b", "please WEEKLY-KB: x\n") == "policy_template")
check("OFF-POLICY: manifest outside the template's allow-list -> policy_manifest",
      consume(A1, UL, "bad2", "WEEKLY-KB: x\n", man=["secrets.env"]) == "policy_manifest")
check("OFF-POLICY: request bigger than the template's max_request_bytes -> policy_size",
      consume(A1, UL, "bad3", "WEEKLY-KB: " + "x" * 3000) == "policy_size")
check("OFF-POLICY: unpriced item is never treated as free -> policy_cost_missing",
      consume(A1, UL, "bad4", "WEEKLY-KB: x\n", cost=None) == "policy_cost_missing")
check("OFF-POLICY: cost above the per-item cap -> policy_item_cap",
      consume(A1, UL, "bad5", "WEEKLY-KB: x\n", cost=101) == "policy_item_cap")
check("OFF-POLICY: invalid utf-8 request -> refused, not a crash",
      oda.consume_envelope(store, A1, label=UL, project=project(UL), holder=holder(UL), request_id="bad6",
                           request_text=b"\xff\xfe WEEKLY-KB: ", manifest=M, now=NOW, lease_conn=lc, cost_cents=1,
                           revoked=kill_switch.envelope_revoked) == "policy_template")
check("OFF-POLICY: every refusal above wrote NOTHING (children unchanged)", n_children(A1) == before)

# --- identity binding ---
check("BINDING: unknown envelope id -> envelope_missing", consume("env-nope", UL, "x1", "WEEKLY-KB: x\n") == "envelope_missing")
lane("proj-unit-other", 1)
check("BINDING: an envelope for one lane refuses another label -> envelope_mismatch",
      consume(A1, "proj-unit-other", "x2", "WEEKLY-KB: x\n", label="proj-unit-other") == "envelope_mismatch")
check("ENGAGED: any lstat error but ENOENT reads as engaged (an unreadable dir is never 'off')",
      kill_switch.engaged(str(base / "not-a-dir-x" / "y" / "z")) is False
      and kill_switch.engaged(str(base / "ra.db" / "child")) is True)
check("BINDING: a different live holder (session) than the one approved -> envelope_holder_changed",
      consume(A1, UL, "x3", "WEEKLY-KB: x\n", hold=(*PANE[UL], hashlib.sha256(b"other").hexdigest(), 1))
      == "envelope_holder_changed")
check("BINDING: a lower lease generation than the floor -> envelope_holder_changed",
      consume(A1, UL, "x4", "WEEKLY-KB: x\n", hold=(*PANE[UL], SESS[UL], 0)) == "envelope_holder_changed")

# --- expiry ---
AE = envelope(UL, "env-unit-exp", window=3600)
exp_at = store.execute("SELECT expires_at FROM owner_dispatch_envelope WHERE auth_id=?", (AE,)).fetchone()[0]
check("EXPIRY: one second before expires_at the envelope still dispatches",
      isinstance(consume(AE, UL, "e1", "WEEKLY-KB: x\n", now=exp_at - 1), dict))
check("EXPIRY: at expires_at -> envelope_expired, nothing minted",
      consume(AE, UL, "e2", "WEEKLY-KB: x\n", now=exp_at) == "envelope_expired" and n_children(AE) == 1)
check("EXPIRY: long after -> envelope_expired",
      consume(AE, UL, "e3", "WEEKLY-KB: x\n", now=exp_at + 10 * 86400) == "envelope_expired")
try:
    mk_dec(UL, "env-8d", POLICY, window=WEEK + 1)
    window_ceiling = False
except odi.Refused as exc:
    window_ceiling = str(exc) == "weekly_approval_field_envelope_window_s"
check("EXPIRY: an 8-day window is refused by the form validator (ceiling 7 days)", window_ceiling)

# --- daily cap (rolling 24h) ---
P_DAY = {**POLICY, "max_per_day": 2, "max_per_week": 50}
AD = envelope(UL, "env-unit-day", P_DAY)
t0 = NOW
ok_d = [consume(AD, UL, f"d{i}", "WEEKLY-KB: x\n", now=t0 + i) for i in (1, 2)]
check("DAILY CAP: the first two items inside 24h dispatch", all(isinstance(x, dict) for x in ok_d))
check("DAILY CAP: the third inside 24h -> envelope_day_cap, nothing minted",
      consume(AD, UL, "d3", "WEEKLY-KB: x\n", now=t0 + 10) == "envelope_day_cap" and n_children(AD) == 2)
check("DAILY CAP: 24h later the window has rolled and dispatch resumes (cap is per rolling day, not per envelope)",
      isinstance(consume(AD, UL, "d3", "WEEKLY-KB: x\n", now=t0 + 86400 + 2), dict) and n_children(AD) == 3)

# --- weekly cap (per envelope lifetime) ---
P_WK = {**POLICY, "max_per_day": 10, "max_per_week": 3}
AW = envelope(UL, "env-unit-wk", P_WK)
ok_w = [consume(AW, UL, f"w{i}", "WEEKLY-KB: x\n", now=t0 + i * (86400 + 5)) for i in (0, 1, 2)]
check("WEEKLY CAP: three items on three different days dispatch (daily cap never trips)",
      all(isinstance(x, dict) for x in ok_w))
check("WEEKLY CAP: the fourth, on a fresh day, -> envelope_week_cap",
      consume(AW, UL, "w3", "WEEKLY-KB: x\n", now=t0 + 3 * (86400 + 5)) == "envelope_week_cap" and n_children(AW) == 3)

# --- spend cap ---
P_B = {**POLICY, "per_item_cap_cents": 60, "total_cap_cents": 100}
AB = envelope(UL, "env-unit-budget", P_B)
check("BUDGET: 60c fits a 100c total cap", isinstance(consume(AB, UL, "b1", "WEEKLY-KB: x\n", cost=60), dict))
check("BUDGET: a second 60c item would exceed the total -> envelope_budget, nothing minted",
      consume(AB, UL, "b2", "WEEKLY-KB: x\n", cost=60) == "envelope_budget" and n_children(AB) == 1)
check("BUDGET: a 40c item still fits exactly (spent+cost == cap is allowed)",
      isinstance(consume(AB, UL, "b3", "WEEKLY-KB: x\n", cost=40), dict))
check("BUDGET: at the cap even 1c is refused", consume(AB, UL, "b4", "WEEKLY-KB: x\n", cost=1) == "envelope_budget")

# --- kill switch: marker file, DB row, hostile ids ---
AK = envelope(UL, "env-unit-kill")
check("KILL SWITCH baseline: a live envelope dispatches", isinstance(consume(AK, UL, "k1", "WEEKLY-KB: x\n"), dict))
os.makedirs(kill_switch.ENVELOPE_REVOKE_DIR, mode=0o700, exist_ok=True)
(Path(kill_switch.ENVELOPE_REVOKE_DIR) / "env-unit-kill.revoked").write_text("")
check("KILL SWITCH: the marker file alone stops dispatch at once (DB row still 'granted')",
      consume(AK, UL, "k2", "WEEKLY-KB: x\n") == "envelope_revoked"
      and store.execute("SELECT status FROM owner_dispatch_envelope WHERE auth_id='env-unit-kill'").fetchone()[0] == "granted"
      and n_children(AK) == 1)
check("KILL SWITCH: a marker for one envelope does not stop another",
      isinstance(consume(A1, UL, "k3", "WEEKLY-KB: x\n"), dict))
AK2 = envelope(UL, "env-unit-kill2")
check("KILL SWITCH: revoke_envelope() denies the row and the next dispatch is refused with no marker present",
      oda.revoke_envelope(store, AK2, operator="terrence", decision_ref="form-x", note="test") == "revoked"
      and consume(AK2, UL, "k4", "WEEKLY-KB: x\n") == "envelope_revoked")
op = store.execute("SELECT kind, operator, decision_ref, outcome, envelope_sha256 FROM owner_dispatch_operator"
                   " WHERE auth_id=?", (AK2,)).fetchone()
check("KILL SWITCH AUDIT: revocation wrote an append-only operator row (who, why, envelope sha)",
      op is not None and op[:4] == ("revoked", "terrence", "form-x", "revoked") and len(op[4]) == 64)
check("KILL SWITCH: revoking twice is refused as revoke_denied, no second audit row",
      oda.revoke_envelope(store, AK2, operator="terrence", decision_ref="form-y") == "revoke_denied"
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_operator WHERE auth_id=?", (AK2,)).fetchone()[0] == 1)
check("KILL SWITCH: revoke needs an operator and a reference",
      oda.revoke_envelope(store, AK2, operator="", decision_ref="x") == "revoke_invalid"
      and oda.revoke_envelope(store, "nope", operator="o", decision_ref="x") == "revoke_missing")
check("KILL SWITCH: an auth id that is not a safe name reads as revoked (fail closed, never joined into a path)",
      kill_switch.envelope_revoked("../../etc/passwd") and kill_switch.envelope_revoked("") and kill_switch.envelope_revoked(None)
      and kill_switch.envelope_marker("a/b") is None)
try:
    oda.consume_envelope(store, A1, label=UL, project=project(UL), holder=holder(UL), request_id="z", request_text=b"x",
                         manifest=M, now=NOW, lease_conn=lc, cost_cents=1)
    required_kw = False
except TypeError:
    required_kw = True
check("KILL SWITCH: revoked is a REQUIRED keyword of consume_envelope", required_kw)

# --- the envelope row itself is immutable except granted -> denied ---
def _sql_fails(sql):
    try:
        store.execute(sql)
        return False
    except sqlite3.Error:
        return True


check("IMMUTABLE: policy / expiry / DELETE on an envelope row are refused by trigger",
      _sql_fails("UPDATE owner_dispatch_envelope SET policy='{}' WHERE auth_id='env-unit-1'")
      and _sql_fails("UPDATE owner_dispatch_envelope SET expires_at=expires_at+999999 WHERE auth_id='env-unit-1'")
      and _sql_fails("DELETE FROM owner_dispatch_envelope WHERE auth_id='env-unit-1'")
      and _sql_fails("UPDATE owner_dispatch_envelope SET status='granted' WHERE auth_id='env-unit-kill2'"))

tamper = sqlite3.connect(auth_db, isolation_level=None)
tamper.execute("DROP TRIGGER owner_dispatch_envelope_revoke_only")
tamper.execute("UPDATE owner_dispatch_envelope SET policy=? WHERE auth_id='env-unit-1'",
               (oda.canonical_policy({**POLICY, "max_per_day": 1000}),))
tamper.close()
check("TAMPER: a policy edited behind the trigger no longer matches its sha256 -> envelope_policy_invalid",
      consume(A1, UL, "t1", "WEEKLY-KB: x\n") == "envelope_policy_invalid")

# ===== B. real Dispatcher + queue_supervisor.tick through EnvelopeDispatch =====


def tick(labels, dispatcher=None):
    d = dispatcher or cli.EnvelopeDispatch(gate, av, send, REG.get, store, lc, qroot)
    return qs.tick(qroot, labels, d,
                   lambda lb, rid: "accepted" in av.stages(rid),
                   lambda lb, rid: qs.latest_queue_event(roots[lb] / "events.jsonl", rid),
                   lambda lb, item, reason: notes.append((lb, item, reason)),
                   lambda lb, rid: cli.journal_state(base / "journal", lb, rid), environ=ON)


def queue(lb, items):
    (qroot / f"{lb}.queue.json").write_text(json.dumps(items))


def item(aid, iid, text, cost=10, man=M):
    return {"id": iid, "request": text, "manifest": man, "auth_id": aid, "cost_cents": cost}


def settle(lb, rid, text):
    (roots[lb] / rid / "result.md").write_text(text)
    for _ in range(3):
        av.tick(lambda x: ol.holder_tuple(lc, x, time.time()), lambda t: True)
    pins = {"result.md": hashlib.sha256(text.encode()).hexdigest()}
    return (av.verify_pinned(rid, pins) and av.record_reply_authenticated(rid, "oex_fixture_weekly")
            and av.accept(rid, "conductor"))


def ledger_kinds(lb):
    p = qroot / f"{lb}.ledger.jsonl"
    return [json.loads(x)["kind"] for x in p.read_text().splitlines()] if p.exists() else []


# --- B1: one approval, queue appended while live, off-policy appended item refused ---
LB = "proj-wk"
lane(LB, 10)
EA = envelope(LB, "env-wk")
queue(LB, [item(EA, "i1", "WEEKLY-KB: one\n"), item(EA, "i2", "WEEKLY-KB: two\n")])
check("ENVELOPE: i1 dispatches under the envelope", tick([LB])[LB] == "dispatched:i1")
check("ENVELOPE: i1 accepted", settle(LB, "q-proj-wk-i1", "ACK i1"))
check("ENVELOPE: i1 done, i2 dispatches", tick([LB])[LB] == "done:i1" and tick([LB])[LB] == "dispatched:i2")
check("ENVELOPE: i2 accepted", settle(LB, "q-proj-wk-i2", "ACK i2"))
check("ENVELOPE: i2 done", tick([LB])[LB] == "done:i2")
issuance_before = store.execute("SELECT COUNT(*) FROM owner_dispatch_issuance").fetchone()[0]
env_rows_before = store.execute("SELECT COUNT(*) FROM owner_dispatch_envelope").fetchone()[0]
q_before = (qroot / f"{LB}.queue.json").read_bytes()
queue(LB, json.loads(q_before) + [item(EA, "i3", "WEEKLY-KB: three, appended while live\n")])
check("APPEND: the queue file changed while the envelope is live", (qroot / f"{LB}.queue.json").read_bytes() != q_before)
r = tick([LB])
check("APPEND: the appended item dispatches with NO new approval (no new issuance, no new envelope row)",
      r[LB] == "dispatched:i3"
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_issuance").fetchone()[0] == issuance_before
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_envelope").fetchone()[0] == env_rows_before
      and n_children(EA) == 3)
jd = base / "journal" / LB / "q-proj-wk-i3"
intent = json.loads((jd / "intent.json").read_text())
check("AUDIT: the existing per-item journal intent carries the child envelope (child id under the envelope, rid, request sha)",
      intent["auth"]["auth_id"].startswith("env-wk:") and intent["auth"]["request_id"] == "q-proj-wk-i3"
      and intent["auth"]["body_sha256"] == hashlib.sha256(b"WEEKLY-KB: three, appended while live\n").hexdigest())
check("AUDIT: oda.unsent() accounts for every child of the envelope (none is consumed-but-unsent)",
      not [a for a in oda.unsent(store, str(base / "journal")) if a.startswith("env-wk:")])
check("APPEND: i3 accepted", settle(LB, "q-proj-wk-i3", "ACK i3") and tick([LB])[LB] == "done:i3")
sent_before = send.count(LB)
queue(LB, json.loads((qroot / f"{LB}.queue.json").read_text()) + [item(EA, "i4", "rm -rf ~ # WEEKLY-KB: not a prefix\n")])
r = tick([LB])
check("OFF-POLICY APPEND: an appended item that fails the policy is refused, lane frozen, NEVER sent",
      r[LB] == "frozen:held_consumed:i4" and send.count(LB) == sent_before
      and cli.journal_state(base / "journal", LB, "q-proj-wk-i4") is None and n_children(EA) == 3)
check("OFF-POLICY APPEND: the refusal is escalated with its typed reason",
      (LB, "i4", "held_consumed:held:not_dispatched:policy_template") in notes)
check("OFF-POLICY APPEND: a later on-policy item behind it does not run while the lane is frozen",
      tick([LB])[LB] == "frozen:held_consumed:i4" and send.count(LB) == sent_before)

# --- B2: kill switch stops a live lane immediately and the item stays pending ---
LK = "proj-wk-kill"
lane(LK, 11)
EK = envelope(LK, "env-wk-kill")
queue(LK, [item(EK, "i1", "WEEKLY-KB: one\n"), item(EK, "i2", "WEEKLY-KB: two\n")])
tick([LK])
settle(LK, "q-proj-wk-kill-i1", "ACK k1")
tick([LK])
rc_k = None
buf = io.StringIO()
state = base / "state-kill"
ORIG_STATE = odi.STATE_ROOT
odi.STATE_ROOT = str(state)
with contextlib.redirect_stdout(buf):
    rc_k = odi.main(["revoke-envelope", "--auth-id", EK, "--operator", "terrence", "--reason", "kill drill"],
                    now=NOW)
sent_k = send.count(LK)
r = tick([LK])
check("KILL SWITCH (CLI): revoke-envelope exits 1 only when the DB step is missing; here no DB env -> marker only",
      rc_k == 1 and "marker=created" in buf.getvalue() and "db_skipped" in buf.getvalue())
check("KILL SWITCH (live lane): with the marker present the NEXT tick holds i2 (retry-safe), nothing sent",
      r[LK] == f"held:i2:held:not_dispatched:envelope_revoked" and send.count(LK) == sent_k
      and "held_consumed" not in ledger_kinds(LK))
os.environ["HERDR_OWNER_DISPATCH_AUTH_DB"] = auth_db
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc_k2 = odi.main(["revoke-envelope", "--auth-id", EK, "--operator", "terrence", "--reason", "kill drill"], now=NOW)
os.environ.pop("HERDR_OWNER_DISPATCH_AUTH_DB")
audit_lines = [json.loads(x) for x in (state / "owner-dispatch" / "revoke.jsonl").read_text().splitlines()]
check("KILL SWITCH (CLI): with the store reachable the row is denied + operator row written; exit 0; marker kept",
      rc_k2 == 0 and "marker=existed" in buf.getvalue()
      and store.execute("SELECT status FROM owner_dispatch_envelope WHERE auth_id=?", (EK,)).fetchone()[0] == "denied"
      and store.execute("SELECT operator FROM owner_dispatch_operator WHERE auth_id=? AND kind='revoked'",
                        (EK,)).fetchone() == ("terrence",))
check("KILL SWITCH AUDIT: every revocation attempt appended to revoke.jsonl (marker + db lines, who and why)",
      [a["action"] for a in audit_lines] == ["marker", "db", "marker", "db"]
      and all(a["operator"] == "terrence" and a["auth_id"] == EK for a in audit_lines)
      and audit_lines[0]["reason"] == "kill drill" and audit_lines[3]["result"] == "revoked")
(Path(kill_switch.ENVELOPE_REVOKE_DIR) / f"{EK}.revoked").unlink()
check("KILL SWITCH: deleting the marker does NOT resume dispatch -- the DB denial is sticky",
      tick([LK])[LK] == "held:i2:held:not_dispatched:envelope_revoked" and send.count(LK) == sent_k)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc_bad = odi.main(["revoke-envelope", "--auth-id", "../evil", "--operator", "t", "--reason", "x"], now=NOW)
check("KILL SWITCH (CLI): a path-escaping auth id is refused, no file created",
      rc_bad == 2 and not (base / "evil.revoked").exists())
odi.STATE_ROOT = ORIG_STATE

# --- F2: a marker that cannot be written must NOT skip the sticky DB denial or the audit line ---
EF = envelope(UL, "env-unit-f2")
blocker = base / "not-a-dir"
blocker.write_text("x")
ORIG_DIR = kill_switch.ENVELOPE_REVOKE_DIR
kill_switch.ENVELOPE_REVOKE_DIR = str(blocker / "sub")        # makedirs -> NotADirectoryError
os.environ["HERDR_OWNER_DISPATCH_AUTH_DB"] = auth_db
odi.STATE_ROOT = str(state)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    try:
        rc_f2 = odi.main(["revoke-envelope", "--auth-id", EF, "--operator", "terrence", "--reason", "f2 drill"], now=NOW)
    except Exception as exc:  # noqa: BLE001
        rc_f2 = f"crash:{type(exc).__name__}"
os.environ.pop("HERDR_OWNER_DISPATCH_AUTH_DB")
kill_switch.ENVELOPE_REVOKE_DIR = ORIG_DIR
odi.STATE_ROOT = ORIG_STATE
audit_f2 = [json.loads(x) for x in (state / "owner-dispatch" / "revoke.jsonl").read_text().splitlines()
            if json.loads(x)["auth_id"] == EF]
check("KILL SWITCH (marker write fails): the DB row is still denied + operator row written, rc 1, no traceback",
      rc_f2 == 1 and "marker=error:" in buf.getvalue() and "db=revoked" in buf.getvalue()
      and store.execute("SELECT status FROM owner_dispatch_envelope WHERE auth_id=?", (EF,)).fetchone()[0] == "denied"
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_operator WHERE auth_id=? AND kind='revoked'", (EF,)).fetchone() == (1,))
check("KILL SWITCH (marker write fails): the audit line names the marker error and the dispatch is refused",
      [a["action"] for a in audit_f2] == ["marker", "db"] and audit_f2[0]["marker_error"] == "NotADirectoryError"
      and consume(EF, UL, "f2x", "WEEKLY-KB: x\n") == "envelope_revoked")

# --- F4: auth_id / approval_id uniqueness is cross-table in BOTH directions, for every issuer ---
SD = mk_dec(UL, "env-unit-day", POLICY)                      # an id that is already an ENVELOPE
SD["rec"] = {**standing_rec(UL, "env-unit-day"), "queue_sha256": "0" * 64, "item_cap": 1}
check("ID UNIQUENESS: a standing grant reusing an envelope's auth_id is refused (no row, no children hijack)",
      refused_with(lambda: odi.insert_standing_grant(store, SD, NOW + 600)) == "approval_already_used"
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE auth_id='env-unit-day'").fetchone() == (0,))
SD2 = mk_dec(UL, "std-f4", POLICY)
SD2["rec"] = {**standing_rec(UL, "std-f4"), "queue_sha256": "1" * 64, "item_cap": 1}
odi.insert_standing_grant(store, SD2, NOW + 600)
check("ID UNIQUENESS: a weekly envelope reusing a standing grant's auth_id is refused",
      refused_with(lambda: odi.insert_weekly_grant(store, mk_dec(UL, "std-f4", POLICY), NOW + 600)) == "approval_already_used")
SD3 = mk_dec(UL, "std-f4-new", POLICY)
SD3["rec"] = {**standing_rec(UL, "std-f4-new"), "queue_sha256": "2" * 64, "item_cap": 1}
SD3["form_id"] = store.execute("SELECT approval_id FROM owner_dispatch_envelope WHERE auth_id='env-unit-day'").fetchone()[0]
check("ID UNIQUENESS: a standing grant reusing an envelope's approval (form) id is refused",
      refused_with(lambda: odi.insert_standing_grant(store, SD3, NOW + 600)) == "approval_already_used")

# --- F5: project binding on consume_envelope ---
check("BINDING: a lane whose project differs from the envelope's is refused envelope_mismatch (project, not just label)",
      oda.consume_envelope(store, A1, label=UL, project="some-other-project", holder=holder(UL), request_id="pj1",
                           request_text=b"WEEKLY-KB: x\n", manifest=M, now=NOW, lease_conn=lc, cost_cents=10,
                           revoked=kill_switch.envelope_revoked) == "envelope_mismatch")

# --- B3: expiry and caps hold the item, retry-safe (no freeze) ---
LX = "proj-wk-exp"
lane(LX, 12)
EX = envelope(LX, "env-wk-exp", exp=time.time() - 5)
queue(LX, [item(EX, "i1", "WEEKLY-KB: one\n")])
r = tick([LX])
check("EXPIRY (live lane): an expired envelope holds the item retry-safe, nothing sent, lane not frozen",
      r[LX] == "held:i1:held:not_dispatched:envelope_expired" and send.count(LX) == 0 and ledger_kinds(LX) == ["escalated"])

LC = "proj-wk-cap"
lane(LC, 13)
EC = envelope(LC, "env-wk-cap", {**POLICY, "max_per_day": 1})
queue(LC, [item(EC, "i1", "WEEKLY-KB: one\n"), item(EC, "i2", "WEEKLY-KB: two\n")])
tick([LC])
settle(LC, "q-proj-wk-cap-i1", "ACK c1")
tick([LC])
r = tick([LC])
check("DAILY CAP (live lane): the second item inside 24h is held retry-safe (not frozen), not sent",
      r[LC] == "held:i2:held:not_dispatched:envelope_day_cap" and send.count(LC) == 1
      and "held_consumed" not in ledger_kinds(LC))
store.execute("UPDATE owner_dispatch_auth SET decided_at='2020-01-01T00:00:00Z' WHERE parent=?", (EC,))
check("DAILY CAP (live lane): once the first dispatch is older than 24h the held item dispatches, no new approval",
      tick([LC])[LC] == "dispatched:i2")

# ===== C. race fix: a missing grant with a matching pending approval stays PENDING =====
FORMS = Path(cli.FORMS_DIR)


def put_form(fid, rec, kind, status="open", answered_at=None, decision="approve", expires_ms=None):
    html = (odi.render_weekly_form(rec) if kind == "weekly" else odi.render_standing_form(rec))
    row = {"id": fid, "status": status, "expires_at": expires_ms}
    if status == "answered":
        row["answers"] = {"decision": decision}
        row["answered_at"] = answered_at
    (FORMS / f"{fid}.html").write_bytes(html)
    (FORMS / f"{fid}.json").write_text(json.dumps(row))



def weekly_rec(lb, aid, window=WEEK):
    return mk_dec(lb, aid, POLICY, window)["rec"]


def clear_forms():
    for p in FORMS.iterdir():
        p.unlink()


def std_tick(lb):
    return tick([lb], cli.StandingDispatch(gate, av, send, REG.get, store, lc, qroot))


def env_tick(lb):
    return tick([lb])


check("RACE: the protocol string pending() matches on equals the issuer's STANDING_PROTOCOL",
      approval_pending.STANDING_PROTOCOL == odi.STANDING_PROTOCOL and approval_pending.WEEKLY_PROTOCOL == odi.WEEKLY_PROTOCOL)

# negative (existing behaviour kept): no matching form -> standing_missing still freezes, fail closed
LR0 = "proj-race-none"
lane(LR0, 20)
queue(LR0, [item("standing-race-none", "i1", "anything\n")])
r = std_tick(LR0)
check("RACE NEGATIVE: standing_missing with NO matching pending approval still freezes held_consumed (unchanged)",
      r[LR0].startswith("frozen:held_consumed:i1"))
LR1 = "proj-race-open"
lane(LR1, 21)
queue(LR1, [item("standing-race-open", "i1", "anything\n")])
exp_ms = int((time.time() + 3600) * 1000)
put_form("20261104T120001-9001", standing_rec(LR1, "standing-race-open"), "standing", expires_ms=exp_ms)
r = std_tick(LR1)
check("RACE: standing_missing while a matching approval form is OPEN -> held pending, NOT held_consumed",
      r[LR1] == "held:i1:held:not_dispatched:approval_pending" and "held_consumed" not in ledger_kinds(LR1)
      and send.count(LR1) == 0)
r = std_tick(LR1)
check("RACE: still pending on the next tick (never burned while the approval is outstanding)",
      r[LR1] == "held:i1:held:not_dispatched:approval_pending" and "held_consumed" not in ledger_kinds(LR1))
# the approval lands: the same item (unchanged) dispatches, nothing was lost
pane, birth, sess, gen = holder(LR1)
qsha = hashlib.sha256((qroot / f"{LR1}.queue.json").read_bytes()).hexdigest()
store.execute(
    "INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,session_digest,"
    "lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,decided_at,expires_at,kind,"
    "queue_sha256,item_cap,spend_cap_cents) VALUES (?,?,?,?,?,?,?,?,'','','[]','p','a','granted',"
    "'2026-11-04T00:00:00Z',?,'standing',?,5,100)",
    ("standing-race-open", oda.PROTOCOL, LR1, project(LR1), pane, birth, sess, gen, time.time() + 3600, qsha))
check("RACE: once the grant is issued the very same item dispatches (it was left pending, not burned)",
      std_tick(LR1)[LR1] == "dispatched:i1" and send.count(LR1) == 1)

# which forms do NOT count as pending (each must still freeze)
def frozen_with(form_fn, lb, n, aid, tickfn=std_tick):
    lane(lb, n)
    queue(lb, [item(aid, "i1", "anything\n")])
    clear_forms()
    form_fn(lb, aid)
    return tickfn(lb)[lb]


check("RACE NEGATIVE: a form for a DIFFERENT grant id does not defer",
      frozen_with(lambda lb, aid: put_form("20261104T120002-9002", standing_rec(lb, "some-other-id"), "standing",
                                           expires_ms=exp_ms), "proj-race-a", 22, "standing-ra").startswith("frozen:held_consumed"))
check("RACE NEGATIVE: a form for a DIFFERENT label does not defer",
      frozen_with(lambda lb, aid: put_form("20261104T120003-9003", standing_rec("proj-race-open", aid), "standing",
                                           expires_ms=exp_ms), "proj-race-b", 23, "standing-rb").startswith("frozen:held_consumed"))
check("RACE NEGATIVE: an EXPIRED open form (still unanswered) does not defer",
      frozen_with(lambda lb, aid: put_form("20261104T120004-9004", standing_rec(lb, aid), "standing",
                                           expires_ms=int((time.time() - 5) * 1000)), "proj-race-c", 24,
                  "standing-rc").startswith("frozen:held_consumed"))
check("RACE NEGATIVE: a DECLINED form does not defer",
      frozen_with(lambda lb, aid: put_form("20261104T120005-9005", standing_rec(lb, aid), "standing", status="answered",
                                           answered_at=int(time.time() * 1000), decision="decline"),
                  "proj-race-d", 25, "standing-rd").startswith("frozen:held_consumed"))
check("RACE NEGATIVE: a form row whose status is 'declined' does not defer",
      frozen_with(lambda lb, aid: put_form("20261104T120015-9015", standing_rec(lb, aid), "standing", status="declined"),
                  "proj-race-dd", 40, "standing-rdd").startswith("frozen:held_consumed"))
check("RACE NEGATIVE (envelope): an answered-DECLINE weekly form does not defer",
      frozen_with(lambda lb, aid: put_form("20261104T120016-9016", weekly_rec(lb, aid), "weekly", status="answered",
                                           answered_at=int(time.time() * 1000), decision="decline"),
                  "proj-race-de", 41, "env-race-de", env_tick).startswith("frozen:held_consumed"))
check("RACE NEGATIVE: an approved form whose own window has passed does not defer",
      frozen_with(lambda lb, aid: put_form("20261104T120006-9006", standing_rec(lb, aid, 60), "standing", status="answered",
                                           answered_at=int((time.time() - 3600) * 1000)),
                  "proj-race-e", 26, "standing-re").startswith("frozen:held_consumed"))
check("RACE: an approved-but-not-yet-issued form inside its window DOES defer",
      frozen_with(lambda lb, aid: put_form("20261104T120007-9007", standing_rec(lb, aid), "standing", status="answered",
                                           answered_at=int((time.time() - 30) * 1000)),
                  "proj-race-f", 27, "standing-rf") == "held:i1:held:not_dispatched:approval_pending")
check("RACE (envelope): envelope_missing while its weekly form is open -> pending, not frozen",
      frozen_with(lambda lb, aid: put_form("20261104T120008-9008", weekly_rec(lb, aid), "weekly", expires_ms=exp_ms),
                  "proj-race-g", 28, "env-race-g", env_tick) == "held:i1:held:not_dispatched:approval_pending")
check("RACE (envelope): envelope_missing with no form still freezes (fail closed)",
      frozen_with(lambda lb, aid: None, "proj-race-h", 29, "env-race-h", env_tick).startswith("frozen:held_consumed"))
clear_forms()

# ===== D. issuer pipeline: build-weekly-form -> answered form -> consume-pending -> issued =====
DL = "proj-issue"
lane(DL, 40)
dstate = base / "state-issue"
(dstate / "forms").mkdir(parents=True)
tpl_dir = base / "tpl"
tpl_dir.mkdir(mode=0o700)
(tpl_dir / "t.json").write_text(json.dumps(POLICY["templates"]))
os.chmod(tpl_dir / "t.json", 0o600)
KEYS_ENV = ("HERDR_OWNER_DISPATCH_ISSUE", "HERDR_OWNER_LEASE_WRITER", "HERDR_OWNER_LEASE_DELIVERY",
            "HERDR_OWNER_LEASE_DB", "HERDR_OWNER_DISPATCH_AUTH_DB", "HERDR_OWNER_DISPATCH_CONSUMER")
real = (odi.STATE_ROOT, odi.DISPATCH_KILL_SWITCH, odi.MERGE_KILL_SWITCH)


def run_odi(argv, flags=True, consumer=False, dks=None, db=None):
    E = {"HERDR_OWNER_DISPATCH_ISSUE": "1", "HERDR_OWNER_LEASE_WRITER": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
         "HERDR_OWNER_LEASE_DB": lease_db, "HERDR_OWNER_DISPATCH_AUTH_DB": db or auth_db} if flags else {}
    if consumer:
        E["HERDR_OWNER_DISPATCH_CONSUMER"] = "1"
    odi.STATE_ROOT = os.path.realpath(dstate)
    odi.DISPATCH_KILL_SWITCH = str(dks or os.path.join(odi.STATE_ROOT, "owner-dispatch.revoked"))
    odi.MERGE_KILL_SWITCH = os.path.join(odi.STATE_ROOT, "merge-delegation.revoked")
    saved = {k: os.environ.get(k) for k in KEYS_ENV}
    for k in saved:
        os.environ.pop(k, None)
    os.environ.update(E)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            rc = odi.main(argv, resolve=REG.get, now=time.time())
    finally:
        odi.STATE_ROOT, odi.DISPATCH_KILL_SWITCH, odi.MERGE_KILL_SWITCH = real
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    return rc, out.getvalue().strip()


BUILD = ["build-weekly-form", "--label", DL, "--project", project(DL), "--templates-dir", str(tpl_dir),
         "--templates-name", "t.json", "--lease-db", lease_db, "--max-per-day", "5", "--max-per-week", "20",
         "--per-item-cap-cents", "100", "--total-cap-cents", "1000"]
out_html = base / "weekly.html"
rc, out = run_odi(BUILD + ["--auth-id", "env-issue-1", "--out", str(out_html)], flags=False)
check("BUILD: build-weekly-form writes the deterministic page (rc 0)", rc == 0 and out.startswith("built:") and out_html.exists())
html = out_html.read_bytes()
embedded = odi.EMBED.findall(html)[0]
rec_built = json.loads(embedded)
check("BUILD: the page shows every cap, the exact prefix as a JSON string, the 7-day window, and that the queue is NOT pinned",
      b"WEEKLY-KB: " in html and b"queue is NOT pinned" in html and b"604800" in html
      and rec_built["policy"]["max_per_day"] == 5 and rec_built["policy"]["total_cap_cents"] == 1000
      and rec_built["envelope_window_s"] == WEEK)
rc2, out2 = run_odi(BUILD + ["--auth-id", "env-issue-1", "--out", str(out_html)], flags=False)
check("BUILD: --out is O_EXCL (a second build refuses)", rc2 == 2 and out2 == "refused:out_exists")

FID = "20261104T130001-9101"


def serve(fid, html_bytes, sha=None, decision="approve", answered_at=None, status="answered"):
    sha = sha or hashlib.sha256(odi.EMBED.findall(html_bytes)[0]).hexdigest()
    (dstate / "forms" / f"{fid}.html").write_bytes(html_bytes)
    (dstate / "forms" / f"{fid}.json").write_text(json.dumps({
        "id": fid, "status": status, "answers": {"decision": decision, "approval_sha256": sha},
        "answered_at": answered_at or int((time.time() - 60) * 1000)}))


def count(sql, *a, db=None):
    c = sqlite3.connect(db or auth_db)
    try:
        return c.execute(sql, a).fetchall()
    finally:
        c.close()


serve(FID, html)
rc, out = run_odi(["issue-weekly", "--form-id", FID])
envrow = count("SELECT status, protocol, owner_label, expires_at FROM owner_dispatch_envelope WHERE auth_id='env-issue-1'")
check("ISSUE: an answered+approved weekly form issues ONE envelope row + issuance record",
      rc == 0 and out == "issued:env-issue-1" and envrow and envrow[0][:3] == ("granted", oda.ENVELOPE_PROTOCOL, DL)
      and count("SELECT COUNT(*) FROM owner_dispatch_issuance WHERE auth_id='env-issue-1'") == [(1,)]
      and abs(envrow[0][3] - ((time.time() - 60) + WEEK)) < 5)
rc, out = run_odi(["issue-weekly", "--form-id", FID])
check("ISSUE: replaying the same form is refused approval_already_used (one approval, one envelope)",
      rc == 2 and out == "refused:approval_already_used"
      and count("SELECT COUNT(*) FROM owner_dispatch_envelope WHERE auth_id='env-issue-1'") == [(1,)])
rc, out = run_odi(["issue-weekly", "--form-id", FID], flags=False)
check("ISSUE: flags off -> refused before reading anything", rc == 4 and out == "refused:flags_off")

# negatives on the answered record
FID2 = "20261104T130002-9102"
rc, _ = run_odi(BUILD + ["--auth-id", "env-issue-2", "--out", str(base / "w2.html")], flags=False)
html2 = (base / "w2.html").read_bytes()
serve(FID2, html2, sha="0" * 64)
rc, out = run_odi(["issue-weekly", "--form-id", FID2])
check("ISSUE NEGATIVE: an answer not bound to the displayed record's sha256 -> refused",
      rc == 2 and out == "refused:form_answer_not_bound_to_displayed_record")
serve(FID2, html2, decision="decline")
check("ISSUE NEGATIVE: a declined form -> refused", run_odi(["issue-weekly", "--form-id", FID2]) == (2, "refused:form_not_approved"))
serve(FID2, html2, answered_at=int((time.time() - 8 * 86400) * 1000))
check("ISSUE NEGATIVE: answered longer ago than the window -> approval_expired",
      run_odi(["issue-weekly", "--form-id", FID2]) == (2, "refused:approval_expired"))
serve(FID2, html2.replace(b"WEEKLY-KB: ", b"ANYTHING: ", 1))
rc, out = run_odi(["issue-weekly", "--form-id", FID2])
check("ISSUE NEGATIVE: a page whose visible policy was edited (not the canonical rendering) -> refused",
      rc == 2 and out in ("refused:form_answer_not_bound_to_displayed_record", "refused:form_html_not_canonical_rendering"))
serve(FID2, html2)
dks = dstate / "owner-dispatch.revoked"
dks.write_text("x")
rc, out = run_odi(["issue-weekly", "--form-id", FID2], dks=dks)
check("ISSUE NEGATIVE: the global kill switch blocks issuance", rc == 4 and out.startswith("refused:kill_switch"))
dks.unlink()
old_db = base / "auth-v2.db"
oc = sqlite3.connect(str(old_db), isolation_level=None)
for v in (1, 2):
    for stmt in oda.MIGRATIONS[v]:
        oc.execute(stmt)
oc.execute("CREATE TABLE owner_dispatch_auth_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
oc.execute("INSERT INTO owner_dispatch_auth_schema_version VALUES (2, 'x')")
oc.close()
os.chmod(old_db, 0o600)
rc, out = run_odi(["issue-weekly", "--form-id", FID2], db=str(old_db))
check("ISSUE NEGATIVE: an unmigrated (v2) store is refused before any write",
      (rc, out) == (4, "refused:auth_store_not_migrated")
      and not count("SELECT name FROM sqlite_master WHERE name='owner_dispatch_envelope'", db=str(old_db)))

# validator negatives: what a human can be shown / sign

bad_rec = lambda **ov: {**weekly_rec(DL, "env-v"), **ov}  # noqa: E731
pol_with = lambda **ov: {**POLICY, **ov}  # noqa: E731
tpl0 = POLICY["templates"][0]
check("VALIDATE: a one-letter (catch-all) prefix is refused",
      refused_with(lambda: odi.validate_weekly_approval(bad_rec(policy=pol_with(templates=[{**tpl0, "request_prefix": "a"}]))))
      == "weekly_approval_policy_template_prefix")
check("VALIDATE: a prefix that could close the page's <script> is refused",
      refused_with(lambda: odi.validate_weekly_approval(bad_rec(policy=pol_with(templates=[{**tpl0, "request_prefix": "WEEKLY</script>"}]))))
      == "weekly_approval_policy_markup")
check("VALIDATE: zero daily cap / bool cap / extra key are refused",
      refused_with(lambda: odi.validate_weekly_approval(bad_rec(policy=pol_with(max_per_day=0)))) == "weekly_approval_policy_caps"
      and refused_with(lambda: odi.validate_weekly_approval(bad_rec(policy=pol_with(max_per_week=True)))) == "weekly_approval_policy_caps"
      and refused_with(lambda: odi.validate_weekly_approval(bad_rec(policy={**POLICY, "extra": 1}))) == "weekly_approval_policy_keys")
check("VALIDATE: a standing record is not a weekly record and vice versa (disjoint kinds)",
      refused_with(lambda: odi.validate_weekly_approval(standing_rec(DL, "x"))) == "weekly_approval_schema"
      and refused_with(lambda: odi.validate_standing_approval(weekly_rec(DL, "x"))) == "standing_approval_schema")

# consume-pending issues weekly forms alongside standing ones
DL2 = "proj-issue2"
lane(DL2, 41)
BUILD2 = [x if x != DL else DL2 for x in BUILD]
BUILD2[BUILD2.index("--project") + 1] = project(DL2)
rc, _ = run_odi(BUILD2 + ["--auth-id", "env-issue-cp", "--out", str(base / "w3.html")], flags=False)
html3 = (base / "w3.html").read_bytes()
serve("20261104T130003-9103", html3)
rc, out = run_odi(["consume-pending", "--queue-root", str(qroot)], consumer=True)
check("CONSUME-PENDING: an approved weekly form is issued by the periodic pass (no queue needed)",
      rc == 0 and "candidates=" in out and count("SELECT status FROM owner_dispatch_envelope WHERE auth_id='env-issue-cp'") == [("granted",)])

# the envelope issued through the REAL pipeline dispatches through the real Dispatcher
queue(DL2, [item("env-issue-cp", "i1", "WEEKLY-KB: from the real issuer\n")])
check("E2E: an envelope issued through build -> serve -> issue-weekly dispatches an on-policy item",
      tick([DL2])[DL2] == "dispatched:i1" and send.count(DL2) == 1)

# ===== E. factory-status shows the envelope, remaining caps, expiry =====
fs_dir = base / "fs"
fs_dir.mkdir()
FS.QSUP.KILL_SWITCH = base / "fs-no-killswitch"
env_plist = {"HERDR_QUEUE_SUPERVISOR": "1", "HERDR_OWNER_DISPATCH": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
             "HERDR_RESULT_AVAILABILITY": "1", "HERDR_QUEUE_SUPERVISOR_ROOT": str(qroot),
             "HERDR_QUEUE_SUPERVISOR_LANES": f"{LC},{DL2},{LK}", "HERDR_OWNER_LEASE_DB": lease_db,
             "HERDR_OWNER_DISPATCH_AUTH_DB": auth_db, "HERDR_QUEUE_SUPERVISOR_ENVELOPE": "1"}
hub, remote = fs_dir / "hub.plist", fs_dir / "remote.plist"
hub.write_bytes(plistlib.dumps({"EnvironmentVariables": env_plist}))
remote.write_bytes(plistlib.dumps({"EnvironmentVariables": {}}))
st = FS.status(hub, remote, time.time())
lanes = {x["label"]: x for x in st["lanes"]}
g = lanes[LC]["grant"]
check("STATUS: the envelope is shown with status, expiry, templates and caps used/remaining",
      st["envelope"] is True and g["mode"] == "envelope" and g["auth_id"] == EC and g["status"] == "granted"
      and g["expires_at"] > time.time() and g["used_day"] == 1 and g["max_per_day"] == 1
      and g["remaining"] == {"day": 0, "week": 48, "cents": 9980} and g["templates"] == ["kb-report"])
g2 = lanes[DL2]["grant"]
check("STATUS: an in-flight lane still shows its envelope but is judged RUNNING",
      lanes[DL2]["verdict"] == "RUNNING" and g2["auth_id"] == "env-issue-cp" and g2["remaining"]["day"] == 4)
check("STATUS: a revoked envelope (DB denied) is reported blocked:envelope_revoked",
      "envelope_revoked" in lanes[LK]["blockers"] and lanes[LK]["verdict"] == "BLOCKED"
      and lanes[LK]["grant"]["status"] == "denied")

txt = io.StringIO()
with contextlib.redirect_stdout(txt):
    FS.main(["--hub-plist", str(hub), "--remote-mcp-plist", str(remote)], now=time.time())
check("STATUS (text): prints envelope id, expiry and remaining caps",
      "envelope=on" in txt.getvalue() and f"envelope {EC}: granted expires_at=" in txt.getvalue()
      and "remaining day=0 week=48 cents=9980" in txt.getvalue())
v_item = FS.envelope_view(auth_db, LC, item(EC, "z1", "totally unrelated request\n"), time.time())
check("STATUS: the NEXT item failing the policy is reported before the tick refuses it",
      "next_item_policy_template" in v_item[1])

# --- F5: the issuer's SECOND window() recheck (between the in-txn checks and the insert) is a real gate ---
out2_html = base / "weekly2.html"
rc, out = run_odi(BUILD + ["--auth-id", "env-issue-w2", "--out", str(out2_html)], flags=False)
FID2W = "20261104T130009-9109"
serve(FID2W, out2_html.read_bytes())
_win, _calls = odi.window, [0]


def _second_call_expires(dec, now, key="grant_window_s"):
    _calls[0] += 1
    if _calls[0] >= 2:
        raise odi.Refused("approval_expired")
    return _win(dec, now, key=key)


odi.window = _second_call_expires
try:
    rc, out = run_odi(["issue-weekly", "--form-id", FID2W])
finally:
    odi.window = _win
check("ISSUE: the window rechecked right before insert refuses when it has lapsed meanwhile; no row written",
      rc == 2 and out == "refused:approval_expired" and _calls[0] == 2
      and count("SELECT COUNT(*) FROM owner_dispatch_envelope WHERE auth_id='env-issue-w2'") == [(0,)])
rc, out = run_odi(["issue-weekly", "--form-id", FID2W])
check("ISSUE: the same form issues once the recheck passes (the refusal above burned nothing)",
      rc == 0 and out == "issued:env-issue-w2")

# --- F5: standing and envelope modes are mutually exclusive in the supervisor ---
(base / "root-b").mkdir(exist_ok=True)
(base / "journal-both").mkdir(exist_ok=True)
env_both = {qs.ENV_FLAG: "1", "HERDR_OWNER_DISPATCH": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
            "HERDR_QUEUE_SUPERVISOR_ROOT": str(qroot), "HERDR_QUEUE_SUPERVISOR_LANES": DL,
            "HERDR_OWNER_LEASE_DB": lease_db, "HERDR_OWNER_DISPATCH_AUTH_DB": auth_db,
            "HERDR_RESULT_AVAILABILITY": "1", "HERDR_RESULT_AVAILABILITY_DB": str(base / "ra-both.db"),
            "HERDR_RESULT_AVAILABILITY_JOURNAL": str(base / "journal-both"),
            "HERDR_RESULT_AVAILABILITY_ROOTS": f"{DL}={base / 'root-b'}",
            cli.STANDING_ENV_FLAG: "1", cli.ENVELOPE_ENV_FLAG: "1"}


def run_main(env):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = cli.main(environ=env, send=send, resolve=REG.get)
    return rc, buf.getvalue().strip()


_ks = cli.KILL_SWITCH
cli.KILL_SWITCH = base / "no-such-kill-switch"
try:
    rc_both, out_both = run_main(env_both)
finally:
    cli.KILL_SWITCH = _ks
check("FLAGS: standing and envelope both on -> refused:standing_and_envelope_both_on, rc 4, nothing dispatched",
      (rc_both, out_both) == (4, "refused:standing_and_envelope_both_on"))

print(f"{'PASS' if not fails else 'FAIL'}: {fails} failure(s)")
sys.exit(1 if fails else 0)
