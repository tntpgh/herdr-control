#!/usr/bin/env python3
"""Offline proofs for lib/queue_supervisor.py.

Four fake project conductors (one per lane) behind an injected fake dispatcher
and evidence source. Temp dirs only: no herdr, no pane, no network, no registry."""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import queue_supervisor as qs

ON = {qs.ENV_FLAG: "1"}
SHA = "a" * 40
fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


class FakeConductors:
    """Dispatcher + evidence for N fake project conductors."""

    def __init__(self):
        self.sent: list[tuple[str, str]] = []
        self.outcome: dict[str, str] = {}  # label -> forced dispatch outcome
        self.ev: dict[tuple[str, str], dict] = {}
        self.notes: list[tuple[str, str, str]] = []

    def dispatch(self, label, rid, request_text, manifest):
        out = self.outcome.get(label, "dispatched")
        if out in ("dispatched", "registered") or out.startswith(("ambiguous", "dispatched:")):
            self.sent.append((label, rid))
        return out

    def evidence(self, label, item):
        return self.ev.get((label, item))

    def notify(self, label, item, reason):
        self.notes.append((label, item, reason))


def setup(root: Path, labels):
    for lb in labels:
        (root / f"{lb}.queue.json").write_text(json.dumps(
            [{"id": "i1", "request": f"{lb} one"}, {"id": "i2", "request": f"{lb} two", "hold": True},
             {"id": "i3", "request": f"{lb} three"}]))


def ledger(root, lb):
    return [json.loads(x)["kind"] for x in (root / f"{lb}.ledger.jsonl").read_text().splitlines()]


LANES = ["kb", "model", "monthly", "farm"]
with tempfile.TemporaryDirectory() as t:
    root = Path(t) / "q"
    root.mkdir()
    setup(root, LANES)
    fc = FakeConductors()
    tick = lambda env=ON: qs.tick(root, LANES, fc, fc.evidence, fc.notify, environ=env)

    check("default off: no flag -> off, nothing sent, no ledger", tick({}) == {"_": "off"} and not fc.sent
          and not list(root.glob("*.ledger.jsonl")))

    fc.outcome["farm"] = "held:not_dispatched:auth_missing"
    r = tick()
    check("4 lanes: three dispatch i1, farm held (nothing sent)",
          [r[x] for x in LANES[:3]] == ["dispatched:i1"] * 3 and r["farm"].startswith("held:i1")
          and len(fc.sent) == 3)
    check("held escalated once", sum(n[0] == "farm" for n in fc.notes) == 1)
    tick()
    check("no duplicate execution while in flight", len(fc.sent) == 3)
    check("held not re-escalated for same reason", sum(n[0] == "farm" for n in fc.notes) == 1)

    fc.ev[("kb", "i1")] = {"state": "done", "proof": SHA}
    fc.ev[("model", "i1")] = {"state": "blocked", "reason": "needs-harness"}
    fc.ev[("monthly", "i1")] = {"state": "cancelled", "reason": "superseded"}
    r = tick()
    check("done with proof advances", r["kb"] == "done:i1")
    check("blocked freezes + escalates", r["model"] == "frozen:blocked:i1"
          and ("model", "i1", "blocked:needs-harness") in fc.notes)
    check("cancelled advances without escalation", r["monthly"] == "cancelled:i1"
          and not any(n[0] == "monthly" for n in fc.notes))
    r = tick()
    check("intentional hold i2 skipped; next is i3", r["kb"] == "dispatched:i3" and r["monthly"] == "dispatched:i3"
          and ("kb", "q-kb-i2") not in fc.sent)
    check("blocked lane stays frozen, no dispatch", r["model"].startswith("frozen:blocked")
          and not any(s[0] == "model" and s[1] != "q-model-i1" for s in fc.sent))

    fc.ev[("kb", "i3")] = {"state": "done", "proof": "trust-me"}
    r = tick()
    check("done without proof -> done_unproven, frozen, escalated", r["kb"] == "frozen:done_unproven:i3"
          and ("kb", "i3", "done_without_proof") in fc.notes)

    (root / "model.ledger.jsonl").open("a").write(json.dumps({"kind": "resume"}) + "\n")
    r = tick()
    check("operator resume unfreezes; blocked item not redispatched, next item sent",
          r["model"] == "dispatched:i3" and fc.sent.count(("model", "q-model-i1")) == 1)

    fc.outcome.pop("farm")
    fc.outcome["farm"] = "ambiguous"
    r = tick()
    check("uncertain dispatch freezes + escalates", r["farm"] == "frozen:uncertain:i1"
          and ("farm", "i1", "uncertain:ambiguous") in fc.notes)
    fc.outcome.pop("farm")
    (root / "farm.ledger.jsonl").open("a").write(json.dumps({"kind": "resume"}) + "\n")
    r = tick()
    check("uncertain item NEVER redispatched after resume", fc.sent.count(("farm", "q-farm-i1")) == 1
          and r["farm"] == "dispatched:i3")

    (root / "farm.ledger.jsonl").open("a").write('{"kind": "dispa')
    check("torn ledger line tolerated", tick()["farm"] == "waiting:i3")

    (root / "kb.queue.json").write_text("{not json")
    r = tick()
    check("one malformed lane does not stall others", r["kb"].startswith(("error:", "frozen:"))
          and r["monthly"] == "waiting:i3")

    import fcntl
    import os
    fd = os.open(root / ".tick.lock", os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    check("concurrent tick refused (busy), no double dispatch", tick() == {"_": "busy"})
    os.close(fd)

    check("ledger is append-only history", ledger(root, "kb")[:2] == ["dispatched", "done"])
    check("ledger files private 0600", all((p.stat().st_mode & 0o777) == 0o600 for p in root.glob("*.ledger.jsonl")))

print(f"{'PASS' if not fails else 'FAIL'}: {fails} failure(s)")
sys.exit(1 if fails else 0)
