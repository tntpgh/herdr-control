#!/usr/bin/env python3
"""Offline proofs for lib/queue_supervisor.py and queue-supervisor.py.

Fake project conductors behind an injected fake dispatcher that, like the real
owner_dispatch.Dispatcher, journals a rid before reporting it; a fake
result_availability `accepted` set; fake owner events. Temp dirs only: no herdr,
no pane, no network, no registry, no real stores."""
from __future__ import annotations

import fcntl
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import queue_supervisor as qs  # noqa: E402

ON = {qs.ENV_FLAG: "1"}
fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


class FakeConductors:
    def __init__(self):
        self.sent: list[tuple[str, str, str]] = []
        self.calls: list[tuple[str, str]] = []
        self.outcome: dict[str, str] = {}
        self.acc: set[str] = set()
        self.ev: dict[str, dict] = {}
        self.jr: dict[str, str] = {}  # rid -> journal verdict
        self.notes: list[tuple[str, str, str]] = []

    def dispatch(self, label, rid, request_text, manifest, auth_id):
        self.calls.append((label, rid))
        out = self.outcome.get(label, "dispatched")
        if out in ("dispatched", "registered"):
            self.jr[rid] = "settled"
        elif out.startswith("held:not_dispatched:") and out.split(":", 2)[2] in qs.RETRY_SAFE:
            pass  # refused before any journal file exists
        elif out.startswith("held:"):
            self.jr[rid] = "refused"
        else:
            self.jr[rid] = "uncertain"
        if not out.startswith("held:"):
            self.sent.append((label, rid, auth_id))
        return out

    def accepted(self, label, rid):
        return rid in self.acc

    def events(self, label, rid):
        return self.ev.get(rid)

    def journal(self, label, rid):
        return self.jr.get(rid)

    def notify(self, label, item, reason):
        self.notes.append((label, item, reason))


def item(i, lb, **kw):
    return {"id": i, "request": f"{lb} {i}", "auth_id": f"g-{lb}-{i}", **kw}


def mkroot(base, name, lanes):
    root = Path(base) / name
    root.mkdir()
    for lb in lanes:
        (root / f"{lb}.queue.json").write_text(json.dumps([item("i1", lb), item("i2", lb, hold=True), item("i3", lb)]))
    return root


LANES = ["kb", "model", "monthly", "farm"]
with tempfile.TemporaryDirectory() as t:
    root = mkroot(t, "q", LANES)
    fc = FakeConductors()

    def tick(env=ON, r=None, lanes=LANES):
        return qs.tick(r or root, lanes, fc, fc.accepted, fc.events, fc.notify, fc.journal, environ=env)

    def resume(lb, r=None):
        with ((r or root) / f"{lb}.ledger.jsonl").open("a") as f:
            f.write(json.dumps({"kind": "resume"}) + "\n")

    check("default off: no flag -> off, nothing called, no ledger",
          tick({}) == {"_": "off"} and not fc.calls and not list(root.glob("*.ledger.jsonl")))

    fc.outcome["farm"] = "held:not_dispatched:registry_lease_mismatch"
    r = tick()
    check("4 lanes: three dispatch i1 with their own grant; farm held pre-grant",
          [r[x] for x in LANES[:3]] == ["dispatched:i1"] * 3 and r["farm"].startswith("held:i1")
          and fc.sent == [("kb", "q-kb-i1", "g-kb-i1"), ("model", "q-model-i1", "g-model-i1"),
                          ("monthly", "q-monthly-i1", "g-monthly-i1")])
    fc.outcome.pop("farm")
    r = tick()
    check("pre-grant hold (nothing journaled) retried once cleared", r["farm"] == "dispatched:i1")
    check("pre-grant hold escalated exactly once", sum(n[0] == "farm" for n in fc.notes) == 1)
    n = len(fc.calls)
    tick()
    check("no duplicate execution while in flight", len(fc.calls) == n)

    fc.acc.update({"q-kb-i3", "q-other-i1"})  # accepted for a different item / a different owner label
    check("acceptance of another item/owner does not complete this one", tick()["kb"] == "waiting:i1")
    fc.acc.difference_update({"q-kb-i3", "q-other-i1"})
    fc.acc.add("q-kb-i1")
    fc.ev["q-model-i1"] = {"event": "queue_blocked", "rid": "q-model-i1", "reason": "needs-harness"}
    fc.ev["q-monthly-i1"] = {"event": "queue_cancelled", "rid": "q-monthly-i1", "reason": "superseded"}
    r = tick()
    check("result_availability accepted -> done", r["kb"] == "done:i1")
    check("queue_blocked freezes + escalates", r["model"] == "frozen:blocked:i1"
          and ("model", "i1", "blocked:needs-harness") in fc.notes)
    check("FORGED owner-written queue_cancelled does NOT advance", r["monthly"] == "waiting:i1")
    with (root / "monthly.ledger.jsonl").open("a") as f:  # conductor/operator receipt, 0600 private ledger
        f.write(json.dumps({"kind": "cancelled", "item": "i1", "by": "operator"}) + "\n")
    r_cancel = tick()
    check("operator cancel in the private ledger advances, no escalation", r_cancel["monthly"] == "dispatched:i3"
          and not any(x[0] == "monthly" for x in fc.notes))
    r = r_cancel
    check("intentional hold i2 never dispatched; next is i3",
          r["kb"] == "dispatched:i3" and not any(c[1].endswith("-i2") for c in fc.calls))
    check("blocked lane stays frozen", r["model"].startswith("frozen:blocked"))

    resume("model")
    fc.outcome["model"] = "held:not_dispatched:auth_envelope_mismatch"
    check("post-grant hold freezes (no retry, no re-grant)", tick()["model"] == "frozen:held_consumed:i3")
    fc.outcome.pop("model")
    n = len(fc.calls)
    tick()
    check("consumed-hold lane makes no further dispatch call", len(fc.calls) == n)
    resume("model")
    r = tick()
    check("after resume the consumed item is NOT retried", r["model"] == "idle:empty"
          and fc.calls.count(("model", "q-model-i3")) == 1)

    # --- crash between dispatch() and the ledger append -------------------------
    c = mkroot(t, "crash", ["c"])
    fc.jr["q-c-i1"] = "settled"  # the Dispatcher journaled + sent; our append never happened
    r = tick(r=c, lanes=["c"])
    check("crash window, journal settled: reconciled, dispatch() NOT called again",
          r["c"] == "dispatched:i1:reconciled" and ("c", "q-c-i1") not in fc.calls)
    fc.jr["q-c-i3"] = "intent_only"
    fc.acc.add("q-c-i1")
    tick(r=c, lanes=["c"])
    r = tick(r=c, lanes=["c"])
    check("crash window, intent without outcome: frozen uncertain, never dispatched",
          r["c"] == "frozen:uncertain:i3" and ("c", "q-c-i3") not in fc.calls
          and ("c", "i3", "uncertain:journal_intent_only") in fc.notes)

    u = mkroot(t, "u", ["u"])
    fc.outcome["u"] = "dispatched:unregistered"
    r = tick(r=u, lanes=["u"])
    check("dispatched:unregistered is uncertain: frozen + escalated", r["u"] == "frozen:uncertain:i1")
    fc.outcome.pop("u")
    tick(r=u, lanes=["u"])
    resume("u", u)
    for _ in range(2):  # "restart": fresh passes read only durable state
        tick(r=u, lanes=["u"])
    check("uncertain item never redispatched across resume/restart", fc.calls.count(("u", "q-u-i1")) == 1)

    with (root / "farm.ledger.jsonl").open("a") as f:
        f.write('{"kind": "dispa')
    r1, r2 = tick()["farm"], tick()["farm"]
    check("malformed ledger line FREEZES the lane (no guessing)", r1 == r2 == "frozen:ledger_corrupt")
    check("ledger corruption escalated exactly once", sum(x == ("farm", "", "ledger_corrupt") for x in fc.notes) == 1)

    fd = os.open(root / ".tick.lock", os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    check("concurrent pass refused (busy)", tick() == {"_": "busy"})
    os.close(fd)
    check("ledger files private 0600", all((p.stat().st_mode & 0o777) == 0o600 for p in root.glob("*.ledger.jsonl")))

    # --- lane ceiling, priority order, bounded sends ----------------------------
    six = ["revenue", "p1", "p2", "p3", "p4", "p5"]
    check("more than 5 canonical lanes refused", tick(lanes=six) == {"_": "refused:lanes"})
    check("duplicate lane labels refused", tick(lanes=["kb", "kb"]) == {"_": "refused:lanes"})
    five = six[:5]
    p = mkroot(t, "prio", five)
    r = tick(r=p, lanes=five)
    check("at most 4 sends per pass, in operator order (revenue first)",
          [r[x] for x in five] == ["dispatched:i1"] * 4 + ["deferred:i1"])
    r = tick(r=p, lanes=five)
    n_before = sum(c[0] in five for c in fc.calls)
    for x in five:  # every lane settles and offers its next item
        fc.acc.add(f"q-{x}-i1")
    r2 = tick(r=p, lanes=five)
    check("total in-flight never exceeds 5 across passes",
          r["p4"] == "dispatched:i1" and n_before == 5
          and sum(v.startswith("dispatched:") for v in r2.values()) == 0)
    r3 = tick(r=p, lanes=five)
    check("capacity freed by acceptance is reused on the next pass, still <=4 sends",
          sum(v.startswith("dispatched:") for v in r3.values()) == 4 and r3["p4"] == "deferred:i3")

    # --- strict queue schema ----------------------------------------------------
    bad = {
        "unknown field": [{**item("i1", "s"), "priority": 1}],
        "duplicate id": [item("i1", "s"), item("i1", "s")],
        "manifest as string": [{**item("i1", "s"), "manifest": "result.md"}],
        "manifest path escape": [{**item("i1", "s"), "manifest": ["../x"]}],
        "manifest duplicate": [{**item("i1", "s"), "manifest": ["a.md", "a.md"]}],
        "manifest too long": [{**item("i1", "s"), "manifest": [f"f{i}.md" for i in range(9)]}],
        "non-bool hold": [{**item("i1", "s"), "hold": "yes"}],
        "non-string request": [{**item("i1", "s"), "request": 5}],
        "missing auth_id": [{"id": "i1", "request": "x"}],
        "bad id chars": [item("../i1", "s")],
    }
    for name, q in bad.items():
        try:
            qs.validate_queue(q)
            ok = False
        except ValueError:
            ok = True
        check(f"schema rejects {name}", ok)
    s = mkroot(t, "schema", ["s"])
    (s / "s.queue.json").write_text(json.dumps(bad["manifest as string"]))
    r = tick(r=s, lanes=["s"])
    check("invalid queue never dispatches", r["s"].startswith("error:") and not any(c[0] == "s" for c in fc.calls))

    ev = Path(t) / "events.jsonl"
    ev.write_text('{"event":"queue_blocked","rid":"r1","reason":"a"}\nnot json\n'
                  '{"event":"x_done","rid":"r1"}\n{"event":"queue_cancelled","rid":"r1"}\n')
    check("events adapter: last queue_* line for rid; ignores *_done",
          qs.latest_queue_event(ev, "r1")["event"] == "queue_cancelled"
          and qs.latest_queue_event(ev, "r2") is None and qs.latest_queue_event(Path(t) / "nope", "r1") is None)

with tempfile.TemporaryDirectory() as t:
    fc = FakeConductors()
    lb = "l" * 48  # owner_lease LABEL_RE max
    lr = Path(t)
    (lr / f"{lb}.queue.json").write_text(json.dumps([{"id": "x" * 49, "request": "r", "auth_id": "g"},
                                                     {"id": "y" * 50, "request": "r", "auth_id": "g"}]))
    r = qs.tick(lr, [lb], fc, fc.accepted, fc.events, fc.notify, fc.journal, environ=ON)
    check("RID boundary: q-<48>-<49> = 100 chars is dispatched", len(qs.rid_for(lb, "x" * 49)) == 100
          and r[lb] == f"dispatched:{'x' * 49}")
    fc.acc.add(qs.rid_for(lb, "x" * 49))
    qs.tick(lr, [lb], fc, fc.accepted, fc.events, fc.notify, fc.journal, environ=ON)
    n = len(fc.calls)
    r = qs.tick(lr, [lb], fc, fc.accepted, fc.events, fc.notify, fc.journal, environ=ON)
    check("RID 101 chars: frozen BEFORE journal read, grant or dispatch", r[lb] == f"frozen:invalid_rid:{'y' * 50}"
          and len(fc.calls) == n and (lb, "y" * 50, "invalid_rid") in fc.notes)

clock = [0.0]
runner = qs.TickRunner([sys.executable, "-c", "import time; time.sleep(30)"], 120, 5, clock=lambda: clock[0])
t0 = time.monotonic()
states = [runner.poll()]
for step in (1, 6, 200):  # attention passes while the supervisor child hangs
    clock[0] = step
    states.append(runner.poll())
elapsed = time.monotonic() - t0
check("hung supervisor tick never blocks the attention loop; one child, no overlap, no kill",
      states == ["started", "running", "stuck", "stuck"] and elapsed < 2 and runner.proc.poll() is None)
runner.proc.kill()  # test cleanup only
runner.proc.wait()
clock[0] = 400
fast = qs.TickRunner([sys.executable, "-c", "print('{}')"], 120, 5, clock=lambda: clock[0])
fast.poll()
fast.proc.wait()
clock[0] = 401
check("finished child reaped; next start waits for the interval", fast.poll().startswith("finished rc=0")
      and fast.poll() == "waiting")

spec = importlib.util.spec_from_file_location("qs_cli", HERE / "queue-supervisor.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

with tempfile.TemporaryDirectory() as t:
    j = Path(t)
    (j / "kb" / "r-settled").mkdir(parents=True)
    (j / "kb" / "r-settled" / "intent.json").write_text("{}")
    (j / "kb" / "r-settled" / "settled.json").write_text("{}")
    (j / "kb" / "r-intent").mkdir()
    (j / "kb" / "r-intent" / "intent.json").write_text("{}")
    (j / "kb" / "r-unc").mkdir()
    (j / "kb" / "r-unc" / "uncertain.json").write_text("{}")
    (j / "kb" / "r-link").symlink_to(j / "kb" / "r-settled")
    check("journal adapter maps real Dispatcher outcome files",
          [cli.journal_state(j, "kb", x) for x in ("r-none", "r-settled", "r-intent", "r-unc", "r-link")]
          == [None, "settled", "intent_only", "uncertain", "uncertain"])


def run(env):
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = cli.main(environ=env, send=lambda *a: False, resolve=lambda lb: None)
    return rc, buf.getvalue().strip()


check("CLI default off", run({}) == (0, "off"))
check("CLI refuses without owner-dispatch flags", run(ON) == (4, "refused:flags_off"))
check("CLI refuses when stores/lanes unconfigured",
      run({**ON, "HERDR_OWNER_DISPATCH": "1", "HERDR_OWNER_LEASE_DELIVERY": "1"}) == (4, "refused:not_configured"))
with tempfile.TemporaryDirectory() as t:
    env = {**ON, "HERDR_OWNER_DISPATCH": "1", "HERDR_OWNER_LEASE_DELIVERY": "1",
           "HERDR_QUEUE_SUPERVISOR_ROOT": t, "HERDR_QUEUE_SUPERVISOR_LANES": "kb",
           "HERDR_OWNER_LEASE_DB": f"{t}/lease.db", "HERDR_OWNER_DISPATCH_AUTH_DB": f"{t}/missing-auth.db"}
    rc, out = run(env)
    check("CLI never creates a missing auth store", rc == 4 and out.startswith("refused:")
          and not Path(f"{t}/missing-auth.db").exists())

print(f"{'PASS' if not fails else 'FAIL'}: {fails} failure(s)")
sys.exit(1 if fails else 0)
