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
import json
import os
import sqlite3
import sys
import tempfile
import time
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
check("wrong pin does not verify", not av.verify_pinned("q-proj-kb-i1", {"result.md": "0" * 64}))
ok = (av.verify_pinned("q-proj-kb-i1", pins) and av.record_reply_authenticated("q-proj-kb-i1", "inbox:fixture-oex")
      and av.accept("q-proj-kb-i1", "conductor"))
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

print("send.calls", [(c[0], c[2].decode().strip()) for c in send.calls])
print(f"{'PASS' if not fails else 'FAIL'}: {fails} failure(s)")
sys.exit(1 if fails else 0)
