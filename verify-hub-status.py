#!/usr/bin/env python3
"""hub.py's status derivation must satisfy the SAME truth table as the shell.

tests/status-cases.json is the single source. Two implementations exist because
one serves shell callers and the other an HTTP view, but a case may not pass in
one and fail in the other — that divergence is the bug this whole change is
about, one layer up.
"""
from __future__ import annotations

import json
import os
import sys
import time
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import hub  # noqa: E402

CASES = json.loads((ROOT / "status-cases.json").read_text())["cases"]
PANE = "wH:pA"
NOW = time.time()


def run() -> int:
    ok = bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        for i, c in enumerate(CASES):
            wt = Path(tmp) / f"c{i}"
            (wt / ".handoffs").mkdir(parents=True)
            ev = wt / ".handoffs/events.jsonl"
            de = c["done_event"]
            ev.write_text('{"event":"implement:x_done","commit":"abc"}\n' if de else "")
            # `asked_at` is the brief delivery time; "stale" evidence predates it.
            asked = None
            if de == "stale":
                os.utime(ev, (NOW - 600, NOW - 600)); asked = NOW - 300
            elif de == "fresh":
                os.utime(ev, (NOW, NOW)); asked = NOW - 300
            if c["pane"] == "__down__":
                panes = None                      # herdr unreachable
            elif c["pane"] is None:
                panes = {"wOTHER:p1": "working"}  # herdr up, this pane unknown
            else:
                panes = {PANE: c["pane"]}
            got = hub.derived_state(
                {"state": c["stored"], "pane_id": PANE, "worktree": str(wt)}, panes, asked)
            if got == c["want"]:
                ok += 1
                print(f"  ok   {c['name']}")
            else:
                bad += 1
                print(f"  FAIL {c['name']}\n     want={c['want']} got={got}")

        # Cases the table cannot express, because they are about the shape of
        # herdr's own output rather than the derivation.
        wt = Path(tmp) / "shape"
        (wt / ".handoffs").mkdir(parents=True)
        (wt / ".handoffs/events.jsonl").write_text("")
        checks = [
            ("no worktree recorded + idle pane -> stalled", "stalled",
             hub.derived_state({"state": "running", "pane_id": PANE, "worktree": None},
                               {PANE: "idle"})),
            ("empty pane list is NOT herdr being down", "gone",
             hub.derived_state({"state": "running", "pane_id": PANE, "worktree": str(wt)}, {})),
            ("unrecognised agent_status passes through", "reviewing",
             hub.derived_state({"state": "running", "pane_id": PANE, "worktree": str(wt)},
                               {PANE: "reviewing"})),
        ]
        for name, want, got in checks:
            if got == want:
                ok += 1
                print(f"  ok   {name}")
            else:
                bad += 1
                print(f"  FAIL {name}\n     want={want} got={got}")

        # `stalled` must be something a person is actually shown.
        if "stalled" in hub.ATTENTION:
            ok += 1
            print("  ok   stalled is an attention state")
        else:
            bad += 1
            print("  FAIL stalled is an attention state\n     want=in ATTENTION got=absent")

    print(f"\nverify-hub-status.py: {ok} passed, {bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(run())
