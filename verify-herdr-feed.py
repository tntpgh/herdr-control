#!/usr/bin/env python3
"""verify-herdr-feed.py — the feed's quiet-by-construction rules, against needs_you()/changes()."""
import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location("herdr_feed", pathlib.Path(__file__).with_name("herdr-feed.py"))
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)

NOW, GRACE = 10_000.0, 90.0
SUMMARY = {"live_connected": True, "open_decisions": 0}


def pane(pid, since, birth="b1"):
    return {"pane_id": pid, "birth": birth, "since": since, "label": "implement:x", "workspace": "kb"}


fails = []


def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


# Grace: a prompt the conductor clears within the grace window never surfaces.
check("blocked under grace is hidden", feed.needs_you(SUMMARY, [pane("p1", NOW - 89)], NOW, GRACE) == {})
check("blocked at grace is shown", len(feed.needs_you(SUMMARY, [pane("p1", NOW - 90)], NOW, GRACE)) == 1)

# A ticking age must not re-announce the same blocked pane every poll.
a = feed.needs_you(SUMMARY, [pane("p1", NOW - 100)], NOW, GRACE)
b = feed.needs_you(SUMMARY, [pane("p1", NOW - 100)], NOW + 600, GRACE)
check("same pane, older age -> no change line", feed.changes(a, b) == [])

# A recycled pane id (new birth) is a different item: old clears, new appears.
c = feed.needs_you(SUMMARY, [pane("p1", NOW - 100, birth="b2")], NOW, GRACE)
check("recycled pane -> one clear + one new", [s for s, _ in feed.changes(a, c)] == ["-", "+"])

# A new decision id set re-announces; the same set does not.
d1 = feed.needs_you({**SUMMARY, "open_decisions": 1, "open_ids": "A"}, [], NOW, GRACE)
d2 = feed.needs_you({**SUMMARY, "open_decisions": 1, "open_ids": "A"}, [], NOW + 60, GRACE)
d3 = feed.needs_you({**SUMMARY, "open_decisions": 2, "open_ids": "A,B"}, [], NOW, GRACE)
check("same open decisions -> quiet", feed.changes(d1, d2) == [])
check("new decision -> announced", ("+", d3["decisions:A,B"]) in feed.changes(d1, d3))

# Hub down is itself the one item, not a silent empty set.
check("hub down -> single hub item", list(feed.needs_you(None, None, NOW, GRACE)) == ["hub:down"])

# A failing controller surfaces even when nothing is blocked.
h = feed.needs_you({**SUMMARY, "stall_watchdog": {"last_error": "boom"}}, [], NOW, GRACE)
check("watchdog error surfaces", "health:stall_watchdog" in h)

raise SystemExit(1 if fails else 0)
