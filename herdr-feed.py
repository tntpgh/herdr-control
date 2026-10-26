#!/usr/bin/env python3
"""herdr-feed.py — a quiet notification tab: only what needs a person, only when it changes.

The conductor pane receives every [HERDR-PEER-SIGNAL] wake (648 in the 24h to
2026-10-26, nearly all answered by the conductor within seconds). Those wakes
are the conductor's working input, not human notifications, so they are left
alone. This feed is the human side: it reads the hub (127.0.0.1:8600) and
prints one line when a needs-you item APPEARS and one when it CLEARS. A
blocked pane only counts once it has stayed blocked past --grace seconds, so
prompts the conductor clears on its own never show up here.

Read-only. Sources, both already served by hub.py:
  /api/blocked/wait?since=V&timeout=S  long-poll on herdr agent_status changes
  /api/summary                         decisions, deploy drift, handoff debt,
                                       controller/watchdog health

  herdr-feed.py                 # run forever in a tab
  herdr-feed.py --once          # print the current needs-you set and exit
  herdr-feed.py --grace 120     # blocked must persist 120s before it shows
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

HUB = os.environ.get("HERDR_HUB_URL", "http://127.0.0.1:8600")
DECISIONS_URL = f"{HUB}/decisions"


def _age(seconds: float) -> str:
    s = int(max(0, seconds))
    return f"{s}s" if s < 90 else f"{s // 60}m" if s < 5400 else f"{s // 3600}h"


def needs_you(summary: dict | None, blocked: list[dict] | None, now: float, grace: float,
              prev: dict[str, str] | None = None) -> dict[str, str]:
    """Current needs-you set: stable key -> display text.

    Keys carry identity (pane birth, decision ids, drift target sha), so an item
    that is replaced by a different one of the same kind reads as clear + new.
    Display text never feeds the key, so a ticking age never re-announces.

    blocked=None means the blocked set is UNKNOWN (hub down, or the hub lost its
    herdr subscription and serves an empty list). The previous blocked items are
    carried forward unchanged: an outage must never read as "cleared".
    """
    items: dict[str, str] = {}
    if blocked is None:
        items.update({k: v for k, v in (prev or {}).items() if k.startswith("blocked:")})
    for b in blocked or []:
        since = b.get("since")
        if since is None or now - float(since) < grace:
            continue
        label = b.get("label") if b.get("label") not in (None, "", b.get("pane_id")) else "(no task)"
        items[f"blocked:{b.get('pane_id')}@{b.get('birth')}"] = (
            f"blocked {_age(now - float(since))}  {b.get('pane_id')}  {label}  [{b.get('workspace', '?')}]")
    if summary is None:
        items["hub:down"] = f"hub unreachable at {HUB}"
        return items
    if blocked is None or summary.get("live_connected") is False:
        items["hub:live"] = "hub lost its herdr subscription — blocked panes are not being seen"
    n, ids = summary.get("open_decisions") or 0, summary.get("open_ids") or ""
    if n:
        items[f"decisions:{ids}"] = f"{n} open decision(s) → {DECISIONS_URL}"
    if summary.get("open_portal_decisions"):
        # ceiling: /api/summary exposes only a portal COUNT, so one portal
        # decision swapped for another in the same poll goes unannounced.
        # Upgrade: have hub.py publish portal ids like open_ids, key on them.
        n_portal = summary["open_portal_decisions"]
        items[f"decisions:portal:{n_portal}"] = f"{n_portal} open portal decision(s)"
    for d in summary.get("deploy_drift") or []:
        items[f"drift:{d.get('repo')}:{d.get('main')}"] = (
            f"deploy drift: {d.get('repo')} runs {d.get('deployed')}, main is {d.get('main')}")
    debt = summary.get("handoff_debt") or 0
    if debt:
        items[f"handoff:{debt}"] = f"handoff debt: {debt} repo(s) changed without a notepad entry"
    for name in ("attention_controller", "stall_watchdog"):
        err = (summary.get(name) or {}).get("last_error")
        if err:
            items[f"health:{name}"] = f"{name} failing: {str(err)[:160]}"
    return items


def changes(prev: dict[str, str], cur: dict[str, str]) -> list[tuple[str, str]]:
    """('+', text) for each new key, ('-', text) for each cleared key. Order: cleared first."""
    return [("-", prev[k]) for k in prev if k not in cur] + [("+", cur[k]) for k in cur if k not in prev]


def _get(path: str, timeout: float) -> dict | None:
    try:
        with urllib.request.urlopen(f"{HUB}{path}", timeout=timeout) as r:
            return json.loads(r.read())
    except (urllib.error.URLError, OSError, ValueError):
        return None


def poll(version: int, wait_s: float) -> tuple[int, dict | None, list[dict] | None]:
    """One long-poll round: returns as soon as an agent status changes, else after wait_s.

    blocked is None when the blocked set is unknown (see needs_you)."""
    live = _get(f"/api/blocked/wait?since={version}&timeout={wait_s:g}", wait_s + 10)
    if live is None or "blocked" not in live:
        # 503 "too many waiters" or hub down: the wait did not block, so back
        # off here or the loop spins against a hub that is asking for relief.
        time.sleep(min(wait_s, 5.0))
        live = _get("/api/blocked", 10)
    summary = _get("/api/summary", 10)
    if live is None or live.get("connected") is False:
        # live_attention() serves [] while disconnected — unknown, not empty.
        return version, summary, None
    return int(live.get("version") or version), summary, live.get("blocked") or []


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--grace", type=float, default=float(os.environ.get("HERDR_FEED_GRACE_S", "90")),
                    help="seconds a pane must stay blocked before it is shown (default 90)")
    ap.add_argument("--once", action="store_true", help="print the current needs-you set and exit")
    args = ap.parse_args()
    # The wait must be shorter than the grace: crossing the grace is not a
    # status change, so nothing else would wake the loop to notice it.
    wait_s = max(5.0, min(30.0, args.grace / 3))

    version, summary, blocked = poll(0, 1)
    prev = needs_you(summary, blocked, time.time(), args.grace)
    stamp = time.strftime("%H:%M")
    if not prev:
        print(f"{stamp}  nothing needs you", flush=True)
    for text in prev.values():
        print(f"{stamp}  • {text}", flush=True)
    if args.once:
        return 0
    while True:
        version, summary, blocked = poll(version, wait_s)
        cur = needs_you(summary, blocked, time.time(), args.grace, prev)
        for sign, text in changes(prev, cur):
            print(f"{time.strftime('%H:%M')}  {'+' if sign == '+' else '✓'} {text}", flush=True)
        prev = cur


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
