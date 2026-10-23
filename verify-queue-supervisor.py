#!/usr/bin/env python3
"""Offline proofs for lib/queue_supervisor.py and queue-supervisor.py.

Four fake project conductors (kb, model, monthly, farm) behind an injected fake
dispatcher, a fake result_availability `accepted` set and fake owner events.
Temp dirs only: no herdr, no pane, no network, no registry, no real stores."""
from __future__ import annotations

import fcntl
import importlib.util
import io
import json
import os
import sys
import tempfile
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
        self.sent: list[tuple[str, str, str]] = []  # (label, rid, auth_id) that crossed a send
        self.calls: list[tuple[str, str]] = []
        self.outcome: dict[str, str] = {}
        self.acc: set[str] = set()
        self.ev: dict[str, dict] = {}
        self.notes: list[tuple[str, str, str]] = []

    def dispatch(self, label, rid, request_text, manifest, auth_id):
        self.calls.append((label, rid))
        out = self.outcome.get(label, "dispatched")
        if not out.startswith("held:"):
            self.sent.append((label, rid, auth_id))
        return out

    def accepted(self, label, rid):
        return rid in self.acc

    def events(self, label, rid):
        return self.ev.get(rid)

    def notify(self, label, item, reason):
        self.notes.append((label, item, reason))


LANES = ["kb", "model", "monthly", "farm"]
with tempfile.TemporaryDirectory() as t:
    root = Path(t) / "q"
    root.mkdir()
    for lb in LANES:
        (root / f"{lb}.queue.json").write_text(json.dumps(
            [{"id": "i1", "request": f"{lb} one", "auth_id": f"g-{lb}-1"},
             {"id": "i2", "request": f"{lb} two", "auth_id": f"g-{lb}-2", "hold": True},
             {"id": "i3", "request": f"{lb} three", "auth_id": f"g-{lb}-3"}]))
    fc = FakeConductors()

    def tick(env=ON):
        return qs.tick(root, LANES, fc, fc.accepted, fc.events, fc.notify, environ=env)

    def resume(lb):
        with (root / f"{lb}.ledger.jsonl").open("a") as f:
            f.write(json.dumps({"kind": "resume"}) + "\n")

    check("default off: no flag -> off, nothing called, no ledger",
          tick({}) == {"_": "off"} and not fc.calls and not list(root.glob("*.ledger.jsonl")))

    fc.outcome["farm"] = "held:not_dispatched:registry_lease_mismatch"
    r = tick()
    check("4 lanes: three dispatch i1 with their own grant; farm held pre-grant",
          [r[x] for x in LANES[:3]] == ["dispatched:i1"] * 3 and r["farm"].startswith("held:i1")
          and fc.sent == [("kb", "q-kb-i1", "g-kb-1"), ("model", "q-model-i1", "g-model-1"),
                          ("monthly", "q-monthly-i1", "g-monthly-1")])
    fc.outcome.pop("farm")
    r = tick()
    check("retry-safe hold (grant not consumed) is retried once cleared", r["farm"] == "dispatched:i1")
    check("retry-safe hold escalated exactly once", sum(n[0] == "farm" for n in fc.notes) == 1)
    n_calls = len(fc.calls)
    tick()
    check("no duplicate execution while in flight", len(fc.calls) == n_calls)

    fc.ev["q-kb-i1"] = {"event": "kb_done", "rid": "q-kb-i1", "commit": "a" * 40}
    r = tick()
    check("worker done event + hex commit is NOT completion", r["kb"] == "waiting:i1")
    fc.acc.add("q-kb-i1")
    fc.ev["q-model-i1"] = {"event": "queue_blocked", "rid": "q-model-i1", "reason": "needs-harness"}
    fc.ev["q-monthly-i1"] = {"event": "queue_cancelled", "rid": "q-monthly-i1", "reason": "superseded"}
    r = tick()
    check("result_availability accepted -> done", r["kb"] == "done:i1")
    check("queue_blocked freezes + escalates", r["model"] == "frozen:blocked:i1"
          and ("model", "i1", "blocked:needs-harness") in fc.notes)
    check("queue_cancelled advances without escalation", r["monthly"] == "cancelled:i1"
          and not any(n[0] == "monthly" for n in fc.notes))
    r = tick()
    check("intentional hold i2 never dispatched; next is i3",
          r["kb"] == "dispatched:i3" and not any(c[1].endswith("-i2") for c in fc.calls))
    check("blocked lane stays frozen", r["model"].startswith("frozen:blocked"))

    resume("model")
    fc.outcome["model"] = "held:not_dispatched:auth_envelope_mismatch"
    r = tick()
    check("post-consumption hold freezes (no retry, no re-grant)", r["model"] == "frozen:held_consumed:i3")
    fc.outcome.pop("model")
    calls = len(fc.calls)
    tick()
    check("consumed-hold lane makes no further dispatch call", len(fc.calls) == calls)
    resume("model")
    r = tick()
    check("after operator resume the consumed item is NOT retried", r["model"] == "idle:empty"
          and fc.calls.count(("model", "q-model-i3")) == 1)

    uroot = Path(t) / "u"
    uroot.mkdir()
    (uroot / "u.queue.json").write_text(json.dumps([{"id": "i1", "request": "u", "auth_id": "g-u-1"}]))
    fc.outcome["u"] = "dispatched:unregistered"
    r = qs.tick(uroot, ["u"], fc, fc.accepted, fc.events, fc.notify, environ=ON)
    check("dispatched:unregistered is uncertain: frozen + escalated", r["u"] == "frozen:uncertain:i1"
          and ("u", "i1", "uncertain:dispatched:unregistered") in fc.notes)
    with (uroot / "u.ledger.jsonl").open("a") as f:
        f.write(json.dumps({"kind": "resume"}) + "\n")
    fc.outcome.pop("u")
    r = qs.tick(uroot, ["u"], fc, fc.accepted, fc.events, fc.notify, environ=ON)
    check("uncertain item NEVER redispatched after resume", fc.calls.count(("u", "q-u-i1")) == 1
          and r["u"] == "idle:empty")

    with (root / "farm.ledger.jsonl").open("a") as f:
        f.write('{"kind": "dispa')
    check("torn ledger line tolerated", tick()["farm"] == "waiting:i1")

    (root / "kb.queue.json").write_text("{not json")
    fc.acc.add("q-kb-i3")
    tick()
    r = tick()
    check("malformed queue isolates to its lane", r["kb"].startswith("error:") and r["farm"] == "waiting:i1")

    fd = os.open(root / ".tick.lock", os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    check("concurrent pass refused (busy)", tick() == {"_": "busy"})
    os.close(fd)
    check("ledger files private 0600", all((p.stat().st_mode & 0o777) == 0o600 for p in root.glob("*.ledger.jsonl")))

    ev = Path(t) / "events.jsonl"
    ev.write_text('{"event":"queue_blocked","rid":"r1","reason":"a"}\nnot json\n'
                  '{"event":"x_done","rid":"r1"}\n{"event":"queue_cancelled","rid":"r1"}\n')
    check("events adapter: last queue_* line for rid; skips malformed and *_done",
          qs.latest_queue_event(ev, "r1")["event"] == "queue_cancelled"
          and qs.latest_queue_event(ev, "r2") is None and qs.latest_queue_event(Path(t) / "nope", "r1") is None)

spec = importlib.util.spec_from_file_location("qs_cli", HERE / "queue-supervisor.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


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
