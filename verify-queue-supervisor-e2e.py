#!/usr/bin/env python3
"""End-to-end offline proof: lib/queue_supervisor.tick driving the REAL
owner_dispatch.Dispatcher, owner_lease_delivery.DeliveryGate,
owner_dispatch_auth.consume and result_availability, via queue-supervisor.py's
GrantDispatch + journal_state adapters.

Disposable temp stores only (lease/auth/ra sqlite, roots, journal). The sender is
an in-process recorder: no herdr, no pane, no network, no provider. Grants are
issued by a TEST-ONLY issuer into the disposable auth store (production has none),
exactly like verify-owner-dispatch.py's insert_grant."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_dispatch_auth as oda  # noqa: E402
import owner_lease as ol  # noqa: E402
import owner_lease_delivery as old  # noqa: E402
import queue_supervisor as qs  # noqa: E402
import result_availability as ra  # noqa: E402

spec = importlib.util.spec_from_file_location("qs_cli", HERE / "queue-supervisor.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

ON = {qs.ENV_FLAG: "1"}
TTL = 3600
LANES = ["proj-kb", "proj-model", "proj-monthly", "proj-farm"]
fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


class Sender:
    def __init__(self):
        self.calls: list[tuple[str, tuple, bytes]] = []
        self.raise_for: set[str] = set()

    def __call__(self, label, holder, text):
        self.calls.append((label, tuple(holder), text))
        if label in self.raise_for:
            raise OSError("fixture: delivery crashed mid-send")
        return True

    def count(self, label):
        return sum(c[0] == label for c in self.calls)


base = Path(os.path.realpath(tempfile.mkdtemp()))
roots = {lb: base / f"root-{lb}" for lb in LANES}
for r in roots.values():
    r.mkdir()
(base / "journal").mkdir()
qroot = base / "queue"
lease_db = str(base / "lease.db")
lc = ol.connect(lease_db)
ol.migrate(lc)
PANE = {lb: (f"wQ:p{i}", f"term_{lb.replace('-', '')}") for i, lb in enumerate(LANES)}
now = time.time()
SESS = {lb: hashlib.sha256(f"session-{lb}".encode()).hexdigest() for lb in LANES}
for lb in LANES:
    ol.register_owner(lc, lb, f"tntpgh/{lb}", now=now)
    if lb != "proj-farm":  # farm starts WITHOUT a live owner lease (missing prerequisite)
        ol.acquire(lc, lb, *PANE[lb], TTL, now, session_digest=SESS[lb])
REG = {lb: (*PANE[lb], SESS[lb]) for lb in LANES}
av = ra.Availability(str(base / "ra.db"), {k: str(v) for k, v in roots.items()}, str(base / "journal"))
gate = old.DeliveryGate(lease_db)
store = sqlite3.connect(str(base / "auth.db"), isolation_level=None, timeout=10)
oda.migrate(store)
send = Sender()


def project(lb):
    return lc.execute("SELECT project FROM owner_projects WHERE label=?", (lb,)).fetchone()[0]


def grant(lb, item_id, request, manifest, body=None):
    """TEST-ONLY issuer, bound to the exact (label, project, holder, rid, body sha, manifest)."""
    holder = ol.holder_tuple(lc, lb, time.time())
    aid = f"g-{lb}-{item_id}"
    pane, birth, sess, gen = holder
    store.execute(
        "INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,session_digest,"
        "lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,decided_at,expires_at)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,'fixture-prompt','fixture-approval','granted','2026-10-23T00:00:00Z',?)",
        (aid, oda.PROTOCOL, lb, project(lb), pane, birth, sess, gen, qs.rid_for(lb, item_id),
         hashlib.sha256((body or request).encode()).hexdigest(), oda.manifest_key(manifest), time.time() + 3600))
    return aid


def queue(lb, items):
    (qroot / f"{lb}.queue.json").write_text(json.dumps(items))


qroot.mkdir(mode=0o700)
M = ["result.md"]
queue("proj-kb", [{"id": "i1", "request": "kb one\n", "manifest": M, "auth_id": grant("proj-kb", "i1", "kb one\n", M)},
                  {"id": "i2", "request": "kb two\n", "manifest": M, "auth_id": grant("proj-kb", "i2", "kb two\n", M)}])
queue("proj-model", [{"id": "i1", "request": "model one\n", "manifest": M,
                      "auth_id": grant("proj-model", "i1", "model one\n", M, body="DIFFERENT BODY\n")}])
queue("proj-monthly", [{"id": "i1", "request": "monthly one\n", "manifest": M,
                        "auth_id": grant("proj-monthly", "i1", "monthly one\n", M)}])
queue("proj-farm", [{"id": "i1", "request": "farm one\n", "manifest": M, "auth_id": "g-proj-farm-i1-not-yet"}])

notes: list[tuple[str, str, str]] = []


def tick():
    # A fresh Dispatcher per item each pass (GrantDispatch), state only in durable stores.
    return qs.tick(qroot, LANES, cli.GrantDispatch(gate, av, send, REG.get, store),
                   lambda lb, rid: "accepted" in av.stages(rid),
                   lambda lb, rid: qs.latest_queue_event(roots[lb] / "events.jsonl", rid),
                   lambda lb, item, reason: notes.append((lb, item, reason)),
                   lambda lb, rid: cli.journal_state(base / "journal", lb, rid), environ=ON)

# NOTE: item 9 (SPEC.md) supersedes item 8's auth-ref design entirely and
# retires result-availability-accept.py (removed). This e2e suite's
# acceptance calls are reverted to DIRECT av.verify_pinned/
# record_reply_authenticated/accept calls (the OLD pipeline, which still
# exists unchanged in lib/result_availability.py and still writes the SAME
# "accepted" stage queue_supervisor's lane-completion check reads) rather
# than left pointing at a deleted file. Routing this suite through the NEW
# submit-owner-result.py/accept-owner-result.py receipt pipeline is flagged
# as follow-up: it needs synthesizing a caller_pane + Holder matching this
# suite's own dispatch flow's real (pane, birth, session, generation), which
# this revert does not attempt.
def accept_via_cli(rid, pins, auth_ref="fixture-oex", by="conductor"):
    return (av.verify_pinned(rid, pins) and av.record_reply_authenticated(rid, auth_ref)
           and av.accept(rid, by))





r = tick()
print("pass1", json.dumps(r, sort_keys=True))
check("four distinct fake-project identities each got their own outcome", set(r) == set(LANES))
check("kb + monthly dispatched through the real fences, to their OWN pane/session",
      r["proj-kb"] == "dispatched:i1" and r["proj-monthly"] == "dispatched:i1"
      and [c[1][:3] for c in send.calls] == [REG["proj-kb"], REG["proj-monthly"]])
check("real journal settled + request.txt written for each send",
      cli.journal_state(base / "journal", "proj-kb", "q-proj-kb-i1") == "settled"
      and (roots["proj-kb"] / "q-proj-kb-i1" / "request.txt").read_text() == "kb one\n")
check("model: grant bound to a different body is refused by the real oda.consume, nothing sent; frozen",
      r["proj-model"].startswith("frozen:held_consumed:i1") and send.count("proj-model") == 0)
check("farm: no live lease -> retry-safe held, nothing journaled, nothing sent",
      r["proj-farm"] == "held:i1:held:not_dispatched:registry_lease_mismatch"
      and cli.journal_state(base / "journal", "proj-farm", "q-proj-farm-i1") is None and send.count("proj-farm") == 0)

r = tick()
check("no duplicate dispatch on the next pass (in flight)", len(send.calls) == 2 and r["proj-kb"] == "waiting:i1")

# crash: the Dispatcher sent + journaled, but our ledger append was lost
led = qroot / "proj-monthly.ledger.jsonl"
led.write_text("".join(x for x in led.read_text().splitlines(keepends=True) if '"dispatched"' not in x))
r = tick()
check("restart after lost ledger append: reconciled from the REAL journal, no resend",
      r["proj-monthly"] == "dispatched:i1:reconciled" and send.count("proj-monthly") == 1)

# acceptance through the real result_availability stages
(roots["proj-kb"] / "q-proj-kb-i1" / "result.md").write_text("ACK kb i1")
holder = lambda lb: ol.holder_tuple(lc, lb, time.time())  # noqa: E731
for _ in range(3):
    av.tick(holder, lambda text: True)
check("worker result observed+noticed is NOT accepted -> lane still waiting",
      av.state("q-proj-kb-i1")[0] == "notified" and tick()["proj-kb"] == "waiting:i1")
pins = {"result.md": hashlib.sha256(b"ACK kb i1").hexdigest()}
check("wrong pin does not verify (through the real public entrypoint)",
      not accept_via_cli("q-proj-kb-i1", {"result.md": "0" * 64}) and "accepted" not in av.stages("q-proj-kb-i1"))
ok = accept_via_cli("q-proj-kb-i1", pins)
r = tick()
check("independently verified + authenticated + accepted -> done; next item sent with ITS grant",
      ok and r["proj-kb"] == "done:i1" and tick()["proj-kb"] == "dispatched:i2" and send.count("proj-kb") == 2)

# blocked via the owner's own events.jsonl
(roots["proj-monthly"] / "events.jsonl").write_text(
    json.dumps({"event": "queue_blocked", "rid": "q-proj-monthly-i1", "reason": "needs-harness"}) + "\n")
r = tick()
check("owner queue_blocked -> frozen + one escalation", r["proj-monthly"] == "frozen:blocked:i1"
      and ("proj-monthly", "i1", "blocked:needs-harness") in notes)

# farm prerequisite resolved: live lease + a grant bound to that holder
ol.acquire(lc, "proj-farm", *PANE["proj-farm"], TTL, time.time(), session_digest=SESS["proj-farm"])
send.raise_for.add("proj-farm")
queue("proj-farm", [{"id": "i1", "request": "farm one\n", "manifest": M,
                     "auth_id": grant("proj-farm", "i1", "farm one\n", M)}])
r = tick()
check("prerequisite resolved -> sent; delivery crashed mid-send -> real uncertain.json, lane frozen",
      r["proj-farm"].startswith("frozen:uncertain:i1") and send.count("proj-farm") == 1
      and cli.journal_state(base / "journal", "proj-farm", "q-proj-farm-i1") == "uncertain")
send.raise_for.clear()
with (qroot / "proj-farm.ledger.jsonl").open("a") as f:
    f.write(json.dumps({"kind": "resume"}) + "\n")
for _ in range(2):
    tick()
check("uncertain send never repeated across resume + restarts", send.count("proj-farm") == 1)

check("grant consumed exactly once per sent item; refused grant untouched by retries",
      store.execute("SELECT count(*) FROM owner_dispatch_auth WHERE status!='granted'").fetchone()[0] == 4)
check("escalations: model refused, farm held(lease), monthly blocked, farm uncertain",
      {n[0] for n in notes} == set(LANES) - {"proj-kb"})

# ===== M9: standing lane grant (default OFF; wired via cli.StandingDispatch) =====
# Same real stores, same real Dispatcher/DeliveryGate fences as above; only the
# grant each dispatch consumes differs (oda.consume_standing minting a
# single-use child under one parent, instead of oda.consume burning a
# one-time row). New lane labels, kept OUT of LANES/tick(), so none of the
# assertions above (which pin exact escalation/store counts) are disturbed.
STANDING_LANES = ["proj-standing", "proj-standing-cap", "proj-standing-sha"]
for i, lb in enumerate(STANDING_LANES):
    PANE[lb] = (f"wS:p{i}", f"term_{lb.replace('-', '')}")
    SESS[lb] = hashlib.sha256(f"session-{lb}".encode()).hexdigest()
    ol.register_owner(lc, lb, f"tntpgh/{lb}", now=time.time())
    ol.acquire(lc, lb, *PANE[lb], TTL, time.time(), session_digest=SESS[lb])
    REG[lb] = (*PANE[lb], SESS[lb])
    roots[lb] = base / f"root-{lb}"
    roots[lb].mkdir()
    av.roots[lb] = str(roots[lb])


def grant_standing(lb, item_cap, queue_sha, spend_cap=None):
    """TEST-ONLY issuer of a standing PARENT row, bound to the lane's current
    holder (the floor) and the exact bytes of its queue.json at signing time.
    Production has no such issuer; fixtures insert directly, like grant()."""
    holder = ol.holder_tuple(lc, lb, time.time())
    aid = f"standing-{lb}"
    pane, birth, sess, gen = holder
    store.execute(
        "INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,session_digest,"
        "lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,decided_at,expires_at,"
        "kind,queue_sha256,item_cap,spend_cap_cents) VALUES (?,?,?,?,?,?,?,?,'','','[]','fixture-prompt',"
        "'fixture-approval','granted','2026-10-23T00:00:00Z',?,'standing',?,?,?)",
        (aid, oda.PROTOCOL, lb, project(lb), pane, birth, sess, gen, time.time() + 3600, queue_sha, item_cap, spend_cap))
    return aid


def tick_standing(labels):
    return qs.tick(qroot, labels, cli.StandingDispatch(gate, av, send, REG.get, store, lc, qroot),
                   lambda lb, rid: "accepted" in av.stages(rid),
                   lambda lb, rid: qs.latest_queue_event(roots[lb] / "events.jsonl", rid),
                   lambda lb, item, reason: notes.append((lb, item, reason)),
                   lambda lb, rid: cli.journal_state(base / "journal", lb, rid), environ=ON)


def settle(lb, rid, text):
    (roots[lb] / rid / "result.md").write_text(text)
    holder_fn = lambda l: ol.holder_tuple(lc, l, time.time())  # noqa: E731
    for _ in range(3):
        av.tick(holder_fn, lambda t: True)  # noqa: E731
    pins = {"result.md": hashlib.sha256(text.encode()).hexdigest()}
    return accept_via_cli(rid, pins, auth_ref="oex_fixture_standing")


# ---- (1) one standing grant -> 3 successive items, each child consumed once, zero further issuance ----
LB_OK = "proj-standing"
items_ok = [{"id": f"i{n}", "request": f"standing {n}\n", "manifest": M, "auth_id": f"standing-{LB_OK}"}
           for n in (1, 2, 3)]
queue(LB_OK, items_ok)
qsha_ok = hashlib.sha256((qroot / f"{LB_OK}.queue.json").read_bytes()).hexdigest()
grant_standing(LB_OK, item_cap=5, queue_sha=qsha_ok)

r = tick_standing([LB_OK])
check("STANDING: item1 dispatched under the one signed grant", r[LB_OK] == "dispatched:i1")
ok1 = settle(LB_OK, "q-proj-standing-i1", "ACK standing i1")
r = tick_standing([LB_OK])
check("STANDING: item1 settles", ok1 and r[LB_OK] == "done:i1")
r = tick_standing([LB_OK])
check("STANDING: item2 dispatched under the SAME grant, no new issuance", r[LB_OK] == "dispatched:i2")
ok2 = settle(LB_OK, "q-proj-standing-i2", "ACK standing i2")
r = tick_standing([LB_OK])
check("STANDING: item2 settles", ok2 and r[LB_OK] == "done:i2")
r = tick_standing([LB_OK])
check("STANDING: item3 dispatched under the SAME grant, no new issuance", r[LB_OK] == "dispatched:i3")
ok3 = settle(LB_OK, "q-proj-standing-i3", "ACK standing i3")
r = tick_standing([LB_OK])
check("STANDING: item3 settles; queue drains with ZERO further issuance the whole time",
      ok3 and r[LB_OK] == "done:i3" and tick_standing([LB_OK])[LB_OK] == "idle:empty"
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE parent=?", (f"standing-{LB_OK}",)).fetchone()[0] == 3
      and store.execute("SELECT used_count, status FROM owner_dispatch_auth WHERE auth_id=?",
                        (f"standing-{LB_OK}",)).fetchone() == (3, "granted"))

# ---- (2) item cap+1 -> held standing_cap ----
LB_CAP = "proj-standing-cap"
items_cap = [{"id": f"i{n}", "request": f"cap {n}\n", "manifest": M, "auth_id": f"standing-{LB_CAP}"}
            for n in (1, 2, 3)]
queue(LB_CAP, items_cap)
qsha_cap = hashlib.sha256((qroot / f"{LB_CAP}.queue.json").read_bytes()).hexdigest()
grant_standing(LB_CAP, item_cap=2, queue_sha=qsha_cap)  # cap BELOW the 3 items actually queued

tick_standing([LB_CAP])
settle(LB_CAP, "q-proj-standing-cap-i1", "ACK cap i1")
tick_standing([LB_CAP])  # done:i1
tick_standing([LB_CAP])  # dispatched:i2
settle(LB_CAP, "q-proj-standing-cap-i2", "ACK cap i2")
tick_standing([LB_CAP])  # done:i2
r = tick_standing([LB_CAP])
check("STANDING CAP: item cap+1 -> held standing_cap, i3 never sent, lane frozen",
      r[LB_CAP].startswith("frozen:held_consumed:i3") and send.count(LB_CAP) == 2
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE parent=?", (f"standing-{LB_CAP}",)).fetchone()[0] == 2)

# ---- (3) edited queue.json -> held queue_sha_mismatch ----
LB_SHA = "proj-standing-sha"
items_sha = [{"id": "i1", "request": "sha one\n", "manifest": M, "auth_id": f"standing-{LB_SHA}"},
            {"id": "i2", "request": "sha two\n", "manifest": M, "auth_id": f"standing-{LB_SHA}"}]
queue(LB_SHA, items_sha)
qsha_before = hashlib.sha256((qroot / f"{LB_SHA}.queue.json").read_bytes()).hexdigest()
grant_standing(LB_SHA, item_cap=5, queue_sha=qsha_before)

tick_standing([LB_SHA])
settle(LB_SHA, "q-proj-standing-sha-i1", "ACK sha i1")
tick_standing([LB_SHA])  # done:i1
queue(LB_SHA, [items_sha[0], {**items_sha[1], "request": "sha two EDITED\n"}])  # operator edit after signing
r = tick_standing([LB_SHA])
check("STANDING QUEUE SHA: an edit after signing -> held queue_sha_mismatch, i2 never sent",
      r[LB_SHA].startswith("frozen:held_consumed:i2") and send.count(LB_SHA) == 1)

check("STANDING: the default per-item path (GrantDispatch, LANES above) is untouched by any of this",
      store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE kind='standing'").fetchone()[0] == 3)

# ---- (4) cost_cents threading through the REAL qs.tick/validate_queue pipeline
# (never calling StandingDispatch.dispatch() directly): a validated cost, a
# missing cost under a real spend cap, a validated cost that overruns the
# cap, and an operator's malformed cost_cents rejected by the shared queue
# schema (lib/queue_supervisor.validate_queue) before any dispatch at all. ----
COST_LANES = ["proj-standing-cost", "proj-standing-budget", "proj-standing-malformed"]
for i, lb in enumerate(COST_LANES):
    PANE[lb] = (f"wC:p{i}", f"term_{lb.replace('-', '')}")
    SESS[lb] = hashlib.sha256(f"session-{lb}".encode()).hexdigest()
    ol.register_owner(lc, lb, f"tntpgh/{lb}", now=time.time())
    ol.acquire(lc, lb, *PANE[lb], TTL, time.time(), session_digest=SESS[lb])
    REG[lb] = (*PANE[lb], SESS[lb])
    roots[lb] = base / f"root-{lb}"
    roots[lb].mkdir()
    av.roots[lb] = str(roots[lb])

LB_COST = "proj-standing-cost"
queue(LB_COST, [{"id": "i1", "request": "cost 1\n", "manifest": M, "auth_id": f"standing-{LB_COST}", "cost_cents": 40},
               {"id": "i2", "request": "cost 2\n", "manifest": M, "auth_id": f"standing-{LB_COST}", "cost_cents": 40},
               {"id": "i3", "request": "cost 3\n", "manifest": M, "auth_id": f"standing-{LB_COST}"}])
qsha_cost = hashlib.sha256((qroot / f"{LB_COST}.queue.json").read_bytes()).hexdigest()
grant_standing(LB_COST, item_cap=5, queue_sha=qsha_cost, spend_cap=100)

r = tick_standing([LB_COST])
check("STANDING COST: a validated cost_cents item dispatches through the real validate_queue + adapter",
      r[LB_COST] == "dispatched:i1"
      and store.execute("SELECT spent_cents FROM owner_dispatch_auth WHERE auth_id=?",
                        (f"standing-{LB_COST}",)).fetchone()[0] == 40)
ok_c1 = settle(LB_COST, "q-proj-standing-cost-i1", "ACK cost i1")
r = tick_standing([LB_COST])
check("STANDING COST: item1 settles", ok_c1 and r[LB_COST] == "done:i1")
r = tick_standing([LB_COST])
check("STANDING COST: item2's validated cost accumulates spend through the real pipeline",
      r[LB_COST] == "dispatched:i2"
      and store.execute("SELECT spent_cents FROM owner_dispatch_auth WHERE auth_id=?",
                        (f"standing-{LB_COST}",)).fetchone()[0] == 80)
ok_c2 = settle(LB_COST, "q-proj-standing-cost-i2", "ACK cost i2")
r = tick_standing([LB_COST])
check("STANDING COST: item2 settles", ok_c2 and r[LB_COST] == "done:i2")
r = tick_standing([LB_COST])
check("STANDING COST: a queued item with NO cost_cents against a REAL spend cap is held, never spent as free",
      r[LB_COST].startswith("frozen:held_consumed:i3")
      and store.execute("SELECT spent_cents FROM owner_dispatch_auth WHERE auth_id=?",
                        (f"standing-{LB_COST}",)).fetchone()[0] == 80)

LB_BUDGET = "proj-standing-budget"
queue(LB_BUDGET, [{"id": "j1", "request": "budget 1\n", "manifest": M, "auth_id": f"standing-{LB_BUDGET}", "cost_cents": 90},
                 {"id": "j2", "request": "budget 2\n", "manifest": M, "auth_id": f"standing-{LB_BUDGET}", "cost_cents": 30}])
qsha_budget = hashlib.sha256((qroot / f"{LB_BUDGET}.queue.json").read_bytes()).hexdigest()
grant_standing(LB_BUDGET, item_cap=5, queue_sha=qsha_budget, spend_cap=100)
check("STANDING: the cost and budget parents land alongside the original 3 standing grants",
      store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE kind='standing'").fetchone()[0] == 5)

r = tick_standing([LB_BUDGET])
check("STANDING BUDGET: first item's validated cost (90) dispatches under the 100 cap",
      r[LB_BUDGET] == "dispatched:j1"
      and store.execute("SELECT spent_cents FROM owner_dispatch_auth WHERE auth_id=?",
                        (f"standing-{LB_BUDGET}",)).fetchone()[0] == 90)
ok_b1 = settle(LB_BUDGET, "q-proj-standing-budget-j1", "ACK budget j1")
r = tick_standing([LB_BUDGET])
check("STANDING BUDGET: item1 settles", ok_b1 and r[LB_BUDGET] == "done:j1")
r = tick_standing([LB_BUDGET])
check("STANDING BUDGET: a validated cost (30) that would push spend past the cap (90+30>100) is held, nothing inserted",
      r[LB_BUDGET].startswith("frozen:held_consumed:j2")
      and store.execute("SELECT spent_cents FROM owner_dispatch_auth WHERE auth_id=?",
                        (f"standing-{LB_BUDGET}",)).fetchone()[0] == 90
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE parent=?",
                        (f"standing-{LB_BUDGET}",)).fetchone()[0] == 1)

LB_MALFORMED = "proj-standing-malformed"
queue(LB_MALFORMED, [{"id": "k1", "request": "bad cost\n", "manifest": M,
                     "auth_id": f"standing-{LB_MALFORMED}", "cost_cents": "forty"}])
r = tick_standing([LB_MALFORMED])
check("STANDING MALFORMED: a non-int cost_cents is rejected by the shared queue schema before any dispatch",
      r[LB_MALFORMED] == "error:ValueError"
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE owner_label=?",
                        (LB_MALFORMED,)).fetchone()[0] == 0)

# ===== recovery scoping (queue-supervisor.py main()), through the REAL CLI
# entrypoint -- not lib/queue_supervisor.tick() in isolation -- since that is
# the actual process boundary the hub drives (hub.py's TickRunner argv). =====
ISO_A, ISO_B = "proj-isoa", "proj-isob"
for i, lb in enumerate((ISO_A, ISO_B)):
    PANE[lb] = (f"wI:p{i}", f"term_{lb.replace('-', '')}")
    SESS[lb] = hashlib.sha256(f"session-{lb}".encode()).hexdigest()
    ol.register_owner(lc, lb, f"tntpgh/{lb}", now=time.time())
    ol.acquire(lc, lb, *PANE[lb], TTL, time.time(), session_digest=SESS[lb])
    REG[lb] = (*PANE[lb], SESS[lb])
    roots[lb] = base / f"root-{lb}"
    roots[lb].mkdir()
    av.roots[lb] = str(roots[lb])
queue(ISO_A, [{"id": "i1", "request": "isoA one\n", "manifest": M, "auth_id": grant(ISO_A, "i1", "isoA one\n", M)}])
queue(ISO_B, [{"id": "i1", "request": "isoB one\n", "manifest": M, "auth_id": grant(ISO_B, "i1", "isoB one\n", M)}])
env_iso = {**ON, "HERDR_OWNER_DISPATCH": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
           "HERDR_QUEUE_SUPERVISOR_ROOT": str(qroot), "HERDR_QUEUE_SUPERVISOR_LANES": f"{ISO_A},{ISO_B}",
           "HERDR_OWNER_LEASE_DB": lease_db, "HERDR_OWNER_DISPATCH_AUTH_DB": str(base / "auth.db"),
           "HERDR_RESULT_AVAILABILITY": "1", "HERDR_RESULT_AVAILABILITY_DB": str(base / "ra.db"),
           "HERDR_RESULT_AVAILABILITY_JOURNAL": str(base / "journal"),
           "HERDR_RESULT_AVAILABILITY_ROOTS": os.pathsep.join(f"{lb}={roots[lb]}" for lb in (ISO_A, ISO_B))}
for private_path in (lease_db, str(base / "auth.db")):
    os.chmod(private_path, 0o600)  # private_sqlite.open_private requires no group/other bits
    for sfx in ("-wal", "-shm", "-journal"):
        if os.path.exists(private_path + sfx):
            os.chmod(private_path + sfx, 0o600)


def run_cli(env):
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = cli.main(environ=env, send=send, resolve=REG.get)
    return rc, buf.getvalue().strip()


# --- shared-store failure FIRST (before either lane has dispatched, so an
# otherwise-eligible proj-isob is genuinely blocked, not merely in-flight).
# A REAL admitted (gate state 'queued') request whose journal intent.json is
# malformed: recover()'s crash-recovery path cannot even read it to decide
# whether it was pre- or post-send -- genuine shared uncertainty (a corrupt
# journal), not scoped to one label's effects. Uses the gate directly (no
# grant consumed, no auth store involved) so it disturbs nothing else.
sent_before = len(send.calls)
bad_rid = qs.rid_for(ISO_A, "corrupt")
adm = gate.admit(ISO_A, *PANE[ISO_A], bad_rid, time.time())
bad_j = base / "journal" / ISO_A / bad_rid
bad_j.mkdir(parents=True)
(bad_j / "intent.json").write_bytes(b"{not json")
rc_fail, out_fail = run_cli(env_iso)
check("SHARED-STORE FAILURE through the real CLI: a corrupt journal entry fails closed GLOBALLY, nothing sent",
      adm.ok and rc_fail == 4 and out_fail.startswith("refused:recovery_needs_operator shared_store=")
      and len(send.calls) == sent_before)
shutil.rmtree(bad_j)  # clear the corrupt entry: recover() would otherwise re-raise on every later pass

# --- lane isolation: proj-isoa carries a PRE-EXISTING bad journal entry
# (settled.json with no matching gate row -> recover() reports
# "unrecorded:settled.json"), independent of proj-isob (distinct label,
# project and auth rows) ---
bad_dir = base / "journal" / ISO_A / "q-isoa-stale"
bad_dir.mkdir(parents=True)
(bad_dir / "intent.json").write_text("{}")
(bad_dir / "settled.json").write_text("{}")
rc_iso, out_iso = run_cli(env_iso)
result = json.loads(out_iso)
check("LANE ISOLATION through the real CLI: independent lane B ticks while A's bad journal entry holds only A",
      rc_iso == 0 and result[ISO_B] == "dispatched:i1"
      and result[ISO_A].startswith("refused:recovery_needs_operator") and f"{ISO_A}/q-isoa-stale" in result[ISO_A]
      and len(send.calls) == sent_before + 1 and send.calls[-1][0] == ISO_B)

# ===== item 9b (SPEC.md): wired production chain, public entrypoints =====
# LABELING: every "crash" below is SIMULATED -- an injected exception in a
# test-only seam (crashing_waker / crashing_post_accept), observed from a
# FRESH main() call afterward (new argv parse, new ra.Availability and
# owner_lease connections constructed inside that call -- no shared
# in-memory state with the call that "crashed"). No OS process is ever
# killed here; that would need a real subprocess + SIGKILL, which this
# offline suite does not attempt. Do not read "simulated crash" as a real
# crash test.
#
# Chain, named by file:line:
#   1. owner submit:        submit-owner-result.py:main()
#                            -> lib/result_availability.py:274 submit_owner_result()
#   2. wake to Main:         submit-owner-result.py:77 wake_main()
#                            -> send-to-agent.sh (existing, unmodified),
#                               $HERDR_MAIN_PANE_ID target (attention-tick.sh:216's
#                               own pattern), gated by lib/pane-guard.sh:41 pane_is_agent()
#   3. independent verification: accept-owner-result.py's --pin (the reviewer's
#                            OWN values, never the receipt's)
#                            -> lib/result_availability.py:369-374 reviewer-pins check
#   4. acceptance consumer:  accept-owner-result.py:main()
#                            -> lib/result_availability.py:325 accept_receipt()
#                            -> lib/result_availability.py:375 _stage(rid, "accepted", ...)
#   5. next tick dispatches the successor: queue-supervisor.py:211-212 accepted()
#                            (reads avail.stages(rid), unchanged by this task)
#                            -> lib/queue_supervisor.py:234-236 done transition
#                            -> lib/queue_supervisor.py:246-254,272 successor dispatch
#                               on the NEXT tick() call
import importlib.util as _ilu

_sub_spec = _ilu.spec_from_file_location("submit_owner_result_cli", HERE / "submit-owner-result.py")
sub_cli = _ilu.module_from_spec(_sub_spec)
_sub_spec.loader.exec_module(sub_cli)
_acc_spec = _ilu.spec_from_file_location("accept_owner_result_cli", HERE / "accept-owner-result.py")
acc_cli = _ilu.module_from_spec(_acc_spec)
_acc_spec.loader.exec_module(acc_cli)

RA_ENVIRON = {"HERDR_RESULT_AVAILABILITY": "1", "HERDR_RESULT_AVAILABILITY_DB": str(base / "ra.db"),
             "HERDR_RESULT_AVAILABILITY_JOURNAL": str(base / "journal"), "HERDR_OWNER_LEASE_DB": lease_db}


def ra_environ_for(labels):
    return {**RA_ENVIRON, "HERDR_RESULT_AVAILABILITY_ROOTS": os.pathsep.join(f"{lb}={roots[lb]}" for lb in labels)}


def run_main(mod, args, **kw):
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = mod.main(args, **kw)
    return rc, buf.getvalue().strip()


def tick9(labels):
    return qs.tick(qroot, labels, cli.GrantDispatch(gate, av, send, REG.get, store),
                   lambda lb, rid: "accepted" in av.stages(rid),
                   lambda lb, rid: qs.latest_queue_event(roots[lb] / "events.jsonl", rid),
                   lambda lb, item, reason: notes.append((lb, item, reason)),
                   lambda lb, rid: cli.journal_state(base / "journal", lb, rid), environ=ON)


def new_lane(lb, n):
    PANE[lb] = (f"w9:p{n}", f"term_{lb.replace('-', '')}")
    SESS[lb] = hashlib.sha256(f"session-{lb}".encode()).hexdigest()
    ol.register_owner(lc, lb, f"tntpgh/{lb}", now=time.time())
    ol.acquire(lc, lb, *PANE[lb], TTL, time.time(), session_digest=SESS[lb])
    REG[lb] = (*PANE[lb], SESS[lb])
    roots[lb] = base / f"root-{lb}"
    roots[lb].mkdir()
    av.roots[lb] = str(roots[lb])
    queue(lb, [{"id": "i1", "request": f"{lb} one\n", "manifest": M, "auth_id": grant(lb, "i1", f"{lb} one\n", M)},
              {"id": "i2", "request": f"{lb} two\n", "manifest": M, "auth_id": grant(lb, "i2", f"{lb} two\n", M)}])


def ok_waker(rid, receipt_id, caller_pane):
    ok_waker.calls.append((rid, receipt_id, caller_pane))
    return "wake:sent"


ok_waker.calls = []

# --- fixture: a dedicated item-9 lane with 2 queued items, so acceptance of
# item 1 (through the real CLI chain) can prove a real successor dispatch ---
LB9 = "proj-item9"
new_lane(LB9, 0)
r = tick9([LB9])
check("item9 setup: i1 dispatched normally through the EXISTING production dispatcher (no change needed)",
      r[LB9] == "dispatched:i1")

rid9 = qs.rid_for(LB9, "i1")
(roots[LB9] / rid9 / "result.md").write_text("item9 ACK i1")
owner9_pane = ol.holder_tuple(lc, LB9, time.time())[0]
env9 = ra_environ_for([LB9])


def crashing_waker(rid, receipt_id, caller_pane):
    raise RuntimeError("fixture: SIMULATED crash in the wake step (injected exception, not a real process kill)")


try:
    run_main(sub_cli, ["--rid", rid9], caller_pane_resolver=lambda: owner9_pane, waker=crashing_waker, environ=env9)
    submit_crashed = False
except RuntimeError:
    submit_crashed = True
check("9b SIMULATED CRASH (submit, injected exception in the wake step): "
     "the receipt is ALREADY durably written despite the crash",
      submit_crashed
      and av.conn.execute("SELECT COUNT(*) FROM ra_submit_receipts WHERE rid=?", (rid9,)).fetchone()[0] == 1)

rc9a, out9a = run_main(sub_cli, ["--rid", rid9], caller_pane_resolver=lambda: owner9_pane,
                       waker=ok_waker, environ=env9)
receipt9 = out9a.split(":")[1] if out9a.startswith("submitted:") else None
check("9b RETRY after the simulated crash (FRESH main() call: new argv parse, new Availability/"
     "owner_lease connections -- no shared in-memory state with the crashed call): "
     "exactly one receipt, SAME receipt_id, retry itself succeeds and wakes Main",
      rc9a == 0 and receipt9 is not None
      and av.conn.execute("SELECT COUNT(*) FROM ra_submit_receipts WHERE rid=?", (rid9,)).fetchone()[0] == 1
      and ok_waker.calls == [(rid9, receipt9, owner9_pane)])

pins9 = {"result.md": hashlib.sha256(b"item9 ACK i1").hexdigest()}


def crashing_post_accept():
    raise RuntimeError("fixture: SIMULATED crash after accept_receipt's durable write, before the caller or"
                       " the next queue tick observes it (injected exception, not a real process kill)")


try:
    run_main(acc_cli, ["--receipt-id", receipt9, "--by", "reviewer9", "--pin", f"result.md={pins9['result.md']}"],
            post_accept=crashing_post_accept, environ=env9)
    accept_crashed = False
except RuntimeError:
    accept_crashed = True
check("9b SIMULATED CRASH (accept, injected exception AFTER the durable write): "
     "the 'accepted' stage is ALREADY durably written despite the crash",
      accept_crashed and "accepted" in av.stages(rid9))

rc9b, out9b = run_main(acc_cli, ["--receipt-id", receipt9, "--by", "reviewer9",
                                 "--pin", f"result.md={pins9['result.md']}"], environ=env9)
check("9b RETRY after the simulated accept-side crash (FRESH main() call): idempotent, exactly one accepted row",
      rc9b == 0 and out9b == "accepted"
      and av.conn.execute("SELECT COUNT(*) FROM ra_stages WHERE rid=? AND stage='accepted'",
                          (rid9,)).fetchone()[0] == 1)

r9a, r9b, r9c = tick9([LB9]), tick9([LB9]), tick9([LB9])
check("9b CHAIN COMPLETE through the public entrypoints named above: queue-supervisor.py's accepted() "
     "predicate reads the SAME stage lib/queue_supervisor.py's done-transition consumes -> "
     "the successor dispatches EXACTLY ONCE across a repeat tick, never twice",
      r9a[LB9] == "done:i1" and r9b[LB9] == "dispatched:i2" and r9c[LB9] == "waiting:i2" and send.count(LB9) == 2)

# ===== item 9b scenario: 4-5 project-owner lanes, ONE held, the others'
# successor dispatch (or pre-existing state) unaffected =====
LB9B, LB9C = "proj-item9-ok2", "proj-item9-held"
new_lane(LB9B, 1)
new_lane(LB9C, 2)
SCENARIO_LANES = [LB9B, LB9C, "proj-kb", "proj-monthly", LB9]  # 5 lanes total
env_scn = ra_environ_for(SCENARIO_LANES)
r = tick9(SCENARIO_LANES)
check("scenario setup: both fresh item9 lanes dispatched i1; the two UNRELATED pre-existing "
     "lanes (proj-kb still mid-flight on i2, proj-monthly still frozen since earlier in this file) "
     "are completely untouched by sharing one tick() call with the item9 lanes",
      r[LB9B] == "dispatched:i1" and r[LB9C] == "dispatched:i1"
      and r["proj-kb"] == "waiting:i2" and r["proj-monthly"] == "frozen:blocked:i1" and r[LB9] == "waiting:i2")

rid9b = qs.rid_for(LB9B, "i1")
(roots[LB9B] / rid9b / "result.md").write_text(f"{LB9B} ACK i1")
owner9b_pane = ol.holder_tuple(lc, LB9B, time.time())[0]
rc, out = run_main(sub_cli, ["--rid", rid9b], caller_pane_resolver=lambda: owner9b_pane, waker=ok_waker, environ=env_scn)
receipt9b = out.split(":")[1]
pins9b = {"result.md": hashlib.sha256(f"{LB9B} ACK i1".encode()).hexdigest()}
rc, out = run_main(acc_cli, ["--receipt-id", receipt9b, "--by", "reviewer",
                             "--pin", f"result.md={pins9b['result.md']}"], environ=env_scn)
check("scenario: the ok item9 lane's acceptance succeeded through the real CLI chain", out == "accepted")

rid9c = qs.rid_for(LB9C, "i1")
(roots[LB9C] / rid9c / "result.md").write_text(f"{LB9C} ACK i1")
rc_held, out_held = run_main(sub_cli, ["--rid", rid9c], caller_pane_resolver=lambda: "pane-IMPOSTER",
                             waker=ok_waker, environ=env_scn)
check("scenario: a NON-OWNER caller's submit is HELD -- never a receipt, never reaching accept or dispatch",
      rc_held == 2 and out_held == "held:not_submitted:bindings_did_not_match"
      and av.conn.execute("SELECT COUNT(*) FROM ra_submit_receipts WHERE rid=?", (rid9c,)).fetchone()[0] == 0)

r2 = tick9(SCENARIO_LANES)
r3 = tick9(SCENARIO_LANES)
check("SCENARIO (5 lanes, ONE held): the ok item9 lane's successor dispatches exactly once; "
     "the held lane never advances past i1 (no accepted stage ever exists for it); the two "
     "unrelated pre-existing lanes' outcomes are byte-identical before and after, across BOTH ticks",
      r2[LB9B] == "done:i1" and r3[LB9B] == "dispatched:i2" and send.count(LB9B) == 2
      and r2[LB9C] == "waiting:i1" and r3[LB9C] == "waiting:i1"
      and r2["proj-kb"] == "waiting:i2" and r3["proj-kb"] == "waiting:i2"
      and r2["proj-monthly"] == "frozen:blocked:i1" and r3["proj-monthly"] == "frozen:blocked:i1"
      and r2[LB9] == "waiting:i2" and r3[LB9] == "waiting:i2")


print("send.calls", [(c[0], c[2].decode().strip()) for c in send.calls])
print(f"{'PASS' if not fails else 'FAIL'}: {fails} failure(s)")
sys.exit(1 if fails else 0)
