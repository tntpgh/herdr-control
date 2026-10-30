#!/usr/bin/env python3
"""Acceptance check for the hub_ui look against the baseline hub.

    python3 prototype/hub-preview/check.py

Renders every page with preview.py (new + baseline, same synthetic data and
clock), then checks: same status/content-type per route; ?json=1 and /api/*
bodies identical; every control (form/input/button/iframe/link) the baseline
had is still there and the only new controls are display prefs; every piece of
baseline text inside <main> is still there; meta refresh unchanged; POSTs
refused; a11y basics; WCAG AA contrast per theme; job classes in sync with
lib/agent-profiles.sh; Ship snapshot leaks no form token; ui.js Ship renderer
under JavaScriptCore (check.js).
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "tmp/hub-preview"
JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc"
sys.path.insert(0, str(ROOT / "lib"))
import hub_ui  # noqa: E402

fails = 0


def check(name: str, cond, detail="") -> None:
    global fails
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  -- {str(detail)[:400]}"))
    fails += 0 if cond else 1


# /timeline's default window is the real clock (now - 24h), so two renders a
# second apart differ only there; compare with timestamps blanked.
TS = re.compile(r"\d{4}-\d\d-\d\dT\d\d(?::|%3A)\d\d(?::|%3A)\d\dZ")


def norm(s: str) -> str:
    return TS.sub("<ts>", s)


class Scan(HTMLParser):
    """Controls anywhere; text only inside <main>, outside script/style."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.controls, self.text, self.depth_main, self.skip, self.meta = set(), set(), 0, 0, []

    def handle_starttag(self, tag, attrs):
        a = {k: norm(v or "") for k, v in attrs}
        if tag == "main":
            self.depth_main += 1
        if tag in ("script", "style"):
            self.skip += 1
        if tag == "meta" and a.get("http-equiv") == "refresh":
            self.meta.append(a.get("content"))
        if tag == "form":
            self.controls.add(("form", (a.get("method") or "get").lower(), a.get("action") or ""))
        elif tag in ("input", "select", "textarea"):
            self.controls.add((tag, a.get("type") or "", a.get("name") or "", a.get("value") or "", a.get("id") or ""))
        elif tag == "button":
            self.controls.add(("button", a.get("class") or "", a.get("type") or ""))
        elif tag == "iframe":
            self.controls.add(("iframe", a.get("src") or ""))
        elif tag == "a" and a.get("href"):
            self.controls.add(("a", a.get("href")))

    def handle_endtag(self, tag):
        if tag == "main":
            self.depth_main -= 1
        if tag in ("script", "style"):
            self.skip -= 1

    def handle_data(self, data):
        if self.depth_main and not self.skip:
            t = re.sub(r"\d+", "#", " ".join(data.split()))  # ages tick between two renders
            if t:
                self.text.add(t)


def scan(path: Path) -> Scan:
    s = Scan()
    s.feed(path.read_text())
    return s


PREF_CONTROLS = {("select", "", "", "", "pref-theme"), ("input", "checkbox", "", "", "pref-reduce"),
                 ("input", "checkbox", "", "", "pref-flavour"), ("input", "radio", "hub-view", "ship", ""),
                 ("input", "radio", "hub-view", "overview", ""), ("a", "#main")}


def snap(name: str, *flags: str, now: int) -> dict:
    d = OUT / name
    r = subprocess.run([sys.executable, str(HERE / "preview.py"), "--snapshot", str(d), "--now", str(now), *flags],
                       capture_output=True, text=True, timeout=180)
    check(f"preview.py {name} snapshot ran", r.returncode == 0, r.stderr[-400:])
    return json.loads((d / "index.json").read_text())


def lum(hexc: str) -> float:
    c = [int(hexc[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def ratio(a: str, b: str) -> float:
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def main() -> int:
    now = int(time.time())
    new, base = snap("new", now=now), snap("baseline", "--baseline", now=now)
    down = snap("down", "--herdr-down", now=now)
    regerr = snap("regerr", "--registry-error", now=now)

    print("== routes")
    check("same route set", set(new) == set(base), set(new) ^ set(base))
    for p in base:
        check(f"{p}: status {base[p]['status']} kept", new[p]["status"] == base[p]["status"], (base[p], new[p]))
        if "ctype" in base[p]:
            check(f"{p}: content-type kept", new[p]["ctype"] == base[p]["ctype"], (base[p]["ctype"], new[p]["ctype"]))
    for p in [k for k in new if k.startswith("POST ")]:
        check(f"{p} refused by preview", new[p]["status"] == 403, new[p])

    print("== JSON bodies identical (minus rev)")
    for p, m in base.items():
        if m.get("file", "").endswith(".json"):
            a = json.loads(norm((OUT / "baseline" / m["file"]).read_text()))
            b = json.loads(norm((OUT / "new" / new[p]["file"]).read_text()))
            for d in (a, b):
                if isinstance(d, dict):
                    d.pop("rev", None)
            check(f"{p}: json identical", a == b)

    print("== HTML: controls, text, refresh")
    for p, m in base.items():
        if not m.get("file", "").endswith(".html"):
            continue
        sb, sn = scan(OUT / "baseline" / m["file"]), scan(OUT / "new" / new[p]["file"])
        lost = sb.controls - sn.controls
        check(f"{p}: every baseline control kept", not lost, sorted(lost))
        added = sn.controls - sb.controls
        bad_added = {c for c in added if c not in PREF_CONTROLS and c[0] != "a"}
        check(f"{p}: only display-pref controls added", not bad_added, sorted(bad_added))
        new_hrefs = {c[1] for c in added if c[0] == "a"} - {"#main"}
        check(f"{p}: added links are hub pages or nav", all(h.startswith("/") for h in new_hrefs), sorted(new_hrefs))
        missing = sb.text - sn.text
        check(f"{p}: every baseline <main> text kept", not missing, sorted(missing)[:8])
        check(f"{p}: meta refresh unchanged", sb.meta == sn.meta, (sb.meta, sn.meta))
        if p.startswith("/decisions/"):
            continue
        h = (OUT / "new" / new[p]["file"]).read_text()
        check(f"{p}: viewport meta", "name=viewport" in h)
        check(f"{p}: skip link", "class=skip href='#main'" in h)
        check(f"{p}: nav marks current page", "aria-current=page" in h)
        check(f"{p}: no exception text", "Traceback" not in h)

    print("== Ship snapshot")
    home = (OUT / "new" / new["/"]["file"]).read_text()
    m = re.search(r"<script type=application/json id=ship-data>(.*?)</script>", home, re.S)
    check("/ embeds ship-data", m)
    ship = json.loads(m.group(1))
    check("ship-data carries no form token / port / worktree",
          not re.search(r"token|preview-token-not-real|59001|\.worktrees", m.group(1)), m.group(1)[:200])
    expect = {"implement:feat/login-form": "executing", "code:fix/null-guard": "unconfirmed",
              "plan:plan/q4-roadmap": "blocked", "design:design/settings-page": "stalled",
              "review:review/pr-41": "in_review", "deep-review:review/pr-38-r2": "executing",
              "debug:fix/flaky-timer": "blocked", "research:research/vendor-scan": "starting",
              "quick:chore/lint-pass": "done_with_proof", "mechanical:chore/rename-sweep": "closed",
              "docs:docs/runbook": "failed", "explore:explore/cache-options": "lost",
              "hotfix-ad-hoc": "executing", "architect:arch/event-bus": "cancelled",
              "implement:feat/export-csv": "gone",
              "triage-urgent-oncall": "done_with_proof", "sweep-dead-branches": "blocked"}
    got = {t["label"]: t["display"] for t in ship["tasks"]}
    check("display state per fixture task", got == expect, {k: (expect.get(k), got.get(k)) for k in set(got) | set(expect) if expect.get(k) != got.get(k)})
    words = {t["label"]: t["words"] for t in ship["tasks"]}
    check("stored-source blocked says unconfirmed", "Unconfirmed" in words["debug:fix/flaky-timer"])
    check("stale stored state named", "Registry still says running" in words["design:design/settings-page"])
    check("completed without proof says so", "No proof on file" in words["mechanical:chore/rename-sweep"])
    check("unrecognized label has no station (shown in the inline Bounty board, not a 6th room)",
          [t["station"] for t in ship["tasks"] if t["label"] == "hotfix-ad-hoc"] == [None])
    # r19 fix (tmp/in/r19/R19-AMEND-SPA.md): the disabled "bounties" nav
    # span this repo used to carry is gone -- T wants the board inline on
    # Ship, not behind any tab, enabled or not.
    check("no bounties nav tab, disabled or otherwise", "nav-disabled" not in home and ">bounties<" not in home)
    check("bounty board renders inline on Ship", "class=\"bounty-board\"" in home)
    check("finished >24h hidden and counted", ship["hidden_finished"] == 1 and "implement:feat/old-thing" not in got)
    check("/ html carries no form token", "preview-token-not-real" not in home)
    # N1 (tmp/in/REVIEW-DASH.md round-2): under a repo scope, a live pane
    # whose owning task is NOT in that repo must be dropped and counted,
    # never shown with an empty task (the exact regression _live_rows()
    # guards against for /herdr; this round shipped it unguarded for Ship).
    # Fixture ground truth (fixtures.py tasks()): of the 6 live panes, only
    # w1:p1/w1:p3/w3:p1/w6:p1 own a demo-app task; w2:p1 owns demo-infra's
    # plan:plan/q4-roadmap and w3:p2 owns demo-docs's deep-review:review/
    # pr-38-r2, so scoping to demo-app must hide exactly those two.
    check("unscoped / lists all 6 live panes", {w["pane"] for w in ship["workers"]} ==
          {"w1:p1", "w2:p1", "w1:p3", "w3:p1", "w3:p2", "w6:p1"}, {w["pane"] for w in ship["workers"]})
    shome = (OUT / "new" / new["/?repo=demo-app"]["file"]).read_text()
    sship = json.loads(re.search(r"id=ship-data>(.*?)</script>", shome, re.S).group(1))
    check("/?repo=demo-app keeps only demo-app panes",
          {w["pane"] for w in sship["workers"]} == {"w1:p1", "w1:p3", "w3:p1", "w6:p1"},
          {w["pane"] for w in sship["workers"]})
    check("/?repo=demo-app hides the other repos' panes, counted (not silently dropped)",
          sship["workers_hidden"] == 2, sship["workers_hidden"])
    # The "N hidden" caption and per-row rendering happen client-side in
    # renderShip() (host.innerHTML = ... in apply()); the static fetch
    # above has no JS engine, so that text lives in check.js, not here.
    check("/?repo=demo-app never lists a pane with an empty task",
          all(w["task"] for w in sship["workers"]), [w for w in sship["workers"] if not w["task"]])
    dhome = (OUT / "down" / down["/"]["file"]).read_text()
    dship = json.loads(re.search(r"id=ship-data>(.*?)</script>", dhome, re.S).group(1))
    check("herdr-down snapshot says not connected", dship["live_connected"] is False)
    rhome = (OUT / "regerr" / regerr["/"]["file"]).read_text()
    check("registry error: / still renders", regerr["/"]["status"] == 200)
    rship = json.loads(re.search(r"id=ship-data>(.*?)</script>", rhome, re.S).group(1))
    check("registry error reaches the Ship", bool(rship.get("error")))
    themes = json.loads(re.search(r"id=hub-themes>(.*?)</script>", home, re.S).group(1))
    for name, obj in (("ship-live", ship), ("ship-down", dship), ("ship-regerr", rship),
                       ("ship-scoped", sship), ("themes", themes)):
        (OUT / f"{name}.json").write_text(json.dumps(obj))

    print("== themes")
    check("theme problems: none", not hub_ui.THEME_PROBLEMS, hub_ui.THEME_PROBLEMS)
    for tid, t in hub_ui.THEMES.items():
        p = t["palette"]
        for fg in ("--fg", "--muted", "--accent", "--ok", "--warn", "--bad", "--info"):
            for bg in ("--bg", "--surface", "--surface-2"):
                r = ratio(p[fg], p[bg])
                check(f"{tid}: {fg} on {bg} {r:.2f}:1 >= 4.5", r >= 4.5)
        for fill in ("--accent", "--ok", "--bad"):
            r = ratio(p["--bg"], p[fill])
            check(f"{tid}: --bg text on {fill} fill {r:.2f}:1 >= 4.5", r >= 4.5)
        check(f"{tid}: dark (bg darker than fg)", lum(p["--bg"]) < lum(p["--fg"]))
        for sid, s in (t.get("stations") or {}).items():
            check(f"{tid}: station {sid} is canonical", sid in {x["id"] for x in hub_ui.STATIONS})
            who = s.get("who")
            check(f"{tid}: station {sid} crew {who} defined", who is None or who in (t.get("characters") or {}))
        for panel, who in (t.get("panels") or {}).items():
            check(f"{tid}: panel {panel} crew defined", panel in hub_ui.PANELS.values() and who in (t.get("characters") or {}))
    check("broken theme is skipped, not applied", _broken_theme_skipped())

    print("== motion: new-row entrance is fully killed under reduced motion")
    # Not a screenshot (one anecdote): a cascade proof. base.css's existing
    # blanket kill-switch (html[data-reduce] *, @media prefers-reduced-
    # motion:reduce) uses !important on every property; !important always
    # wins over a non-!important rule regardless of selector specificity or
    # source order (CSS cascade, unconditionally) -- so the new tr.row-new
    # rule only has to avoid !important of its own to be guaranteed killed,
    # never a second manual media query (tmp/in/REVIEW-DASH.md F3's "the
    # only way to stop it is the OS-level setting" is the failure this
    # reuses, not repeats).
    css = hub_ui.BASE_CSS
    check("blanket data-reduce kill-switch present and unmodified",
          "html[data-reduce] *" in css and "animation:none!important" in css)
    check("blanket prefers-reduced-motion media kill-switch present",
          "@media (prefers-reduced-motion:reduce)" in css and "animation:none!important" in css.split("prefers-reduced-motion:reduce){", 1)[-1][:80])
    m = re.search(r"tr\.row-new\{([^}]*)\}", css)
    check("tr.row-new rule exists", bool(m), css[:0])
    check("tr.row-new carries no !important (so the blanket kill-switch always wins, any rule order)",
          bool(m) and "!important" not in m.group(1), m.group(1) if m else None)

    print("== job classes")
    sh = (ROOT / "lib/agent-profiles.sh").read_text()
    known = re.search(r'^KNOWN_JOB_CLASSES="([^"]+)"', sh, re.M).group(1).split()
    check("JOB_CLASSES == lib/agent-profiles.sh KNOWN_JOB_CLASSES", list(hub_ui.JOB_CLASSES) == known, (hub_ui.JOB_CLASSES, known))
    for c in known:
        n = sum(c in s["jobs"] for s in hub_ui.STATIONS)
        check(f"{c} at exactly one station", n == 1, n)
        check(f"{c} has a plain label", c in hub_ui.JOB_LABELS)

    print("== ui.js under JavaScriptCore")
    r = subprocess.run([JSC, str(HERE / "check.js")], cwd=ROOT, capture_output=True, text=True, timeout=60)
    print(r.stdout.rstrip())
    check("check.js passed", r.returncode == 0 and "ALL CHECKS PASSED" in r.stdout, r.stderr[-400:])

    print("ALL CHECKS PASSED" if not fails else f"{fails} FAILED")
    return 1 if fails else 0


def _broken_theme_skipped() -> bool:
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        for tid, pal in (("bebop", hub_ui.THEMES["bebop"]["palette"]), ("broken", {"--bg": "#000"})):
            (root / tid).mkdir()
            (root / tid / "theme.json").write_text(json.dumps({"palette": pal}))
        themes, problems = hub_ui.load_themes(root)
    return "broken" not in themes and any(p.startswith("broken:") for p in problems)


if __name__ == "__main__":
    sys.exit(main())
