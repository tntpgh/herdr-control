#!/usr/bin/env python3
"""hub.py's status derivation must satisfy the truth table it claims to.

status-cases.json (next to this file) is the single source, and hub.py's
`derived_state` is the single implementation. There were two until 2026-09-15 —
a shell half in lib/live-status.sh that had already drifted in two ways no row
could see — and this file exists because a table nothing asserts is a comment.
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
            if de == "trailing":
                ev.write_text('{"event":"implement:x_done","commit":"abc"}\n'
                              '{"event":"note","text":"still thinking"}\n')
            elif de == "no_newline":
                # No trailing newline on the LAST line. A reader using a
                # line-at-a-time loop that drops an unterminated final line
                # sees no evidence and derives `stalled`.
                ev.write_text('{"event":"note","text":"working"}\n'
                              '{"event":"implement:x_done","commit":"abc"}')
            elif de in ("undatable", "undatable_no_ask"):
                # A `_done` that CARRIES a timestamp which cannot be parsed,
                # followed by a later line so mtime cannot stand in for it.
                # This is the only input that actually reaches the `undatable`
                # branch — the `trailing` fixture has no timestamp at all and
                # takes the earlier "no evidence" path.
                ev.write_text('{"event":"implement:x_done","ts":"yesterday-ish"}\n'
                              '{"event":"note","text":"still thinking"}\n')
            # `asked_at` is the brief delivery time; "stale" evidence predates it.
            asked = None
            if de == "stale":
                os.utime(ev, (NOW - 600, NOW - 600)); asked = NOW - 300
            elif de == "fresh":
                os.utime(ev, (NOW, NOW)); asked = NOW - 300
            elif de == "undatable":
                asked = NOW - 300
            if c["pane"] in ("__down__", "__noshape__"):
                panes = None                      # herdr unreachable / no panes array
            elif c["pane"] == "__unhashable__":
                panes = {PANE: {"agent_status": "idle", "birth": "term-1"}}
            elif c["pane"] is None:
                panes = {"wOTHER:p1": {"agent_status": "working", "birth": "term-x"}}
            else:
                # The subscription's projected record shape, which is what
                # hub.pane_statuses() now returns.
                # `birth: unknown` is herdr_live's synthesised record for a
                # status change on a pane it has no snapshot for: present,
                # answering, but not IDENTIFIED.
                live_birth = "" if c.get("birth") == "unknown" else "term-live"
                panes = {PANE: {"pane_id": PANE, "agent_status": c["pane"], "birth": live_birth}}
            pid = [PANE] if c["pane"] == "__unhashable__" else PANE
            # The REGISTRY's recorded fingerprint. `unknown` means the task
            # registered one and the LIVE record has none — the case that
            # silently disabled the guard.
            birth = {"mismatch": "term-OLD", "match": "term-live",
                     "unknown": "term-live"}.get(c.get("birth"), "")
            if de == "trailing":
                os.utime(ev, (NOW, NOW)); asked = NOW - 300   # mtime NEWER than the ask
            try:
                got = hub.derived_state(
                    {"state": c["stored"], "pane_id": pid, "worktree": str(wt),
                     "pane_birth": birth}, panes, asked)
            except Exception as e:  # noqa: BLE001 — a raiser here IS the defect
                got = f"{type(e).__name__}: {e}"
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
                               {PANE: {"agent_status": "idle", "birth": "t"}})),
            ("empty pane list is NOT herdr being down", "gone",
             hub.derived_state({"state": "running", "pane_id": PANE, "worktree": str(wt)}, {})),
            ("unrecognised agent_status falls back to the stored state", "running",
             hub.derived_state({"state": "running", "pane_id": PANE, "worktree": str(wt)},
                               {PANE: {"agent_status": "reviewing", "birth": "t"}})),
        ]
        for name, want, got in checks:
            if got == want:
                ok += 1
                print(f"  ok   {name}")
            else:
                bad += 1
                print(f"  FAIL {name}\n     want={want} got={got}")

        # ---- the three review blockers, tested where they actually live ----
        # A worker that echoes one non-UTF8 byte into its own log must not
        # blank the entire attention surface (Cached swallows the exception
        # into an error dict, and every surface then shows zero tasks).
        badbus = Path(tmp) / "badbytes"
        (badbus / ".handoffs").mkdir(parents=True)
        (badbus / ".handoffs/events.jsonl").write_bytes(
            b'{"event":"implement:x_done","n":"\xff\xfe"}\n')
        try:
            got = hub.derived_state({"state": "running", "pane_id": PANE,
                                     "worktree": str(badbus)}, {PANE: {"agent_status": "idle", "birth": "t"}})
            checks2 = [("non-UTF8 byte in the bus does not raise", "completed", got)]
        except Exception as e:  # noqa: BLE001
            checks2 = [("non-UTF8 byte in the bus does not raise", "completed",
                        f"{type(e).__name__}: {e}")]

        # HERDR_HANDOFF_DIR is a supported override the shell honours; hub
        # hardcoding .handoffs made every finished worker derive `stalled`.
        alt = Path(tmp) / "altbus"
        (alt / ".bus").mkdir(parents=True)
        (alt / ".bus/events.jsonl").write_text('{"event":"implement:x_done"}\n')
        os.environ["HERDR_HANDOFF_DIR"] = ".bus"
        try:
            got = hub.derived_state({"state": "running", "pane_id": PANE,
                                     "worktree": str(alt)}, {PANE: {"agent_status": "idle", "birth": "t"}})
        except Exception as e:  # noqa: BLE001
            got = f"{type(e).__name__}: {e}"
        finally:
            del os.environ["HERDR_HANDOFF_DIR"]
        checks2.append(("HERDR_HANDOFF_DIR is honoured", "completed", got))

        # The liveness source is the subscription now, not `herdr pane list`.
        # What must hold is unchanged and is the same class of bug: anything
        # other than a real, connected snapshot must read as "herdr cannot be
        # asked" (None) and NEVER as "no panes exist" ({}), which would mark
        # every live task `gone`. Non-object JSON used to reach .get() and
        # raise AttributeError, which Cached turned into a truthy dict.
        class _FakeLive:
            def __init__(self, payload):
                self._p = payload

            def data(self):
                return self._p

        real_live = hub.LIVE
        for label, payload in (
            ("subscription not started", None),
            ("connected:false", {"connected": False, "panes": [{"pane_id": PANE}]}),
            ("connected but no panes key", {"connected": True}),
            ("panes is not a list", {"connected": True, "panes": "x"}),
        ):
            hub.LIVE = None if payload is None else _FakeLive(payload)
            try:
                got = hub.pane_statuses()
            except Exception as e:  # noqa: BLE001 — a raiser here is the bug
                got = f"{type(e).__name__}: {e}"
            finally:
                hub.LIVE = real_live
            want = None if label != "connected but no panes key" else {}
            checks2.append((f"{label} -> {'no panes' if want == {} else 'herdr unreachable'}", want, got))
        # And the shape that MUST produce usable records.
        hub.LIVE = _FakeLive({"connected": True,
                              "panes": [{"pane_id": PANE, "agent_status": "blocked", "birth": "t"}]})
        try:
            got = hub.pane_statuses()
        finally:
            hub.LIVE = real_live
        checks2.append(("a connected snapshot yields {pane: record}",
                        {PANE: {"pane_id": PANE, "agent_status": "blocked", "birth": "t"}}, got))
        for name, want, got in checks2:
            if got == want:
                ok += 1
                print(f"  ok   {name}")
            else:
                print(f"  FAIL {name}\n     want={want} got={got}")
                bad += 1

        # `stalled` must be something a person is actually shown.
        if "stalled" in hub.ATTENTION:
            ok += 1
            print("  ok   stalled is an attention state")
        else:
            bad += 1
            print("  FAIL stalled is an attention state\n     want=in ATTENTION got=absent")

        # ---- the SOURCE of each verdict ---------------------------------
        # Every fallback path returns the STORED state, so `state_stale` is
        # False exactly when the row is least trustworthy. `derive` reports
        # where the answer came from so the page can say `unconfirmed`; a
        # renderer cannot invent that distinction from the state alone.
        src_wt = Path(tmp) / "src"
        (src_wt / ".handoffs").mkdir(parents=True)
        (src_wt / ".handoffs/events.jsonl").write_text("")
        base = {"state": "blocked", "pane_id": PANE, "worktree": str(src_wt)}
        for label, task, live, want in (
            ("herdr confirms blocked -> live", base,
             {PANE: {"agent_status": "blocked", "birth": ""}}, "live"),
            ("herdr unreachable -> stored", base, None, "stored"),
            ("herdr has no opinion -> stored", base,
             {PANE: {"agent_status": "unknown", "birth": ""}}, "stored"),
            ("unrecognised status -> stored", base,
             {PANE: {"agent_status": "reviewing", "birth": ""}}, "stored"),
            ("unidentified pane -> stored", dict(base, pane_birth="term-A"),
             {PANE: {"agent_status": "working", "birth": ""}}, "stored"),
            ("recycled pane -> live (gone is a live fact)", dict(base, pane_birth="term-A"),
             {PANE: {"agent_status": "working", "birth": "term-B"}}, "live"),
            ("a terminal state -> registry", dict(base, state="completed"),
             {PANE: {"agent_status": "working", "birth": ""}}, "registry"),
        ):
            got = hub.derive(task, live)[1]
            if got == want:
                ok += 1
                print(f"  ok   source: {label}")
            else:
                bad += 1
                print(f"  FAIL source: {label}\n     want={want} got={got}")

        # ---- the ask anchor: only a BRIEF re-asks ----------------------
        # PR #313 lost five review findings because a finished worker read
        # `completed` off an older round. The fix anchored "did it do what I
        # last asked?" to the last delivery — and then every delivery counted
        # as an ask, so answering a formserve prompt re-asked the question the
        # answer was answering, and the worker sat in Needs-attention as
        # `stalled` forever (a finished worker never writes another `_done`).
        # Both halves have to hold: a reply must not move the anchor, and a
        # real new brief must.
        anchor_wt = Path(tmp) / "anchor"
        (anchor_wt / ".handoffs").mkdir(parents=True)
        done_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - 600))
        (anchor_wt / ".handoffs/events.jsonl").write_text(
            '{"event":"implement:x_done","ts":"%s"}\n' % done_at)
        task = {"state": "running", "pane_id": PANE, "worktree": str(anchor_wt),
                "pane_birth": "term-live"}
        live = {PANE: {"agent_status": "idle", "birth": "term-live"}}
        for label, asked_ago, want in (
            ("round-one brief, then the worker finished", 1200, "completed"),
            ("a reply delivered after it finished does NOT re-ask", 1200, "completed"),
            ("a NEW brief after it finished DOES re-ask", 0, "stalled"),
        ):
            got = hub.derived_state(task, live, NOW - asked_ago)
            if got == want:
                ok += 1
                print(f"  ok   {label}")
            else:
                bad += 1
                print(f"  FAIL {label}\n     want={want} got={got}")
        # And the query itself: the anchor reads brief_delivered ONLY. If this
        # ever widens, the middle case above stops being reachable.
        src = Path(__file__).with_name("hub.py").read_text()
        if "WHERE type='brief_delivered' " in src:
            ok += 1
            print("  ok   the asked_at query is scoped to brief_delivered")
        else:
            bad += 1
            print("  FAIL the asked_at query is scoped to brief_delivered")

    print(f"\nverify-hub-status.py: {ok} passed, {bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(run())
