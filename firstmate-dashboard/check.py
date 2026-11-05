#!/usr/bin/env python3
"""check — render the dashboard against fixture data and assert what matters.

    python3 firstmate-dashboard/check.py

Builds a throwaway Firstmate home from fixtures/ with stand-in CLIs (the
real ones need a real home, and a stand-in `gh` so nothing leaves the
machine), serves it on an ephemeral 127.0.0.1 port, and checks: every open
captain decision appears, hostile text is escaped, Bebop draws the whole page
as the ship with each crew in its room, Big Shot's bounty board carries the
right status for each source and reads Verified only with a merged PR or
report on record, both palettes keep AA contrast, the summary counts the omp
status line reads, the answer path's guards (token, Host/Origin, stale
decision text), that an accepted answer reaches the inbox CLI naming its
decision and its confirmation shows under Your calls, that Answer all sends
each typed answer as its own note and a row's Send only its own, that a call counts as
answered only for the text the answer was bound to, that the Reports view
lists only data/<id>/report.md inside data/, escapes every report, pins its
captain calls linked to the held decision and makes its tables sortable,
faceted and copyable, and that a failed read never reports zero counts, an
empty fleet or an unheld call, in the API or on the page.
"""
from __future__ import annotations

import http.client
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIX = HERE / "fixtures"
sys.path.insert(0, str(HERE))
import fmdata  # noqa: E402
import render  # noqa: E402
import server  # noqa: E402

FAILS: list[str] = []


def check(cond: bool, what: str) -> None:
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        FAILS.append(what)


def tool(path: Path, body: str) -> None:
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def build_home(tmp: Path) -> Path:
    home = tmp / "home"
    shutil.copytree(FIX / "home", home)
    (home / "bin").mkdir()
    fx, h = str(FIX), str(home)
    tool(home / "bin" / "fm-tasks-axi.sh", f"""[ -e "{h}/FAIL_LIST" ] && {{ echo 'tasks-axi: backlog unreadable' >&2; exit 1; }}
echo "fm-tasks-axi.sh $*" >> "{h}/cli-calls"
case "$1" in
  list) cat "{h}/list.txt" 2>/dev/null || cat "{fx}/list.txt" ;;
  show) cat "{h}/show-$2.txt" 2>/dev/null || cat "{fx}/show-$2.txt" ;;
  *) exit 2 ;;
esac
""")
    # A crew's reading comes from crew/<id>.txt in the home when present (a
    # check changing it), else its fixture; crew/<id>.fail makes the read fail.
    tool(home / "bin" / "fm-crew-state.sh", f"""echo "fm-crew-state.sh $*" >> "{h}/cli-calls"
[ -e "{h}/crew/$1.fail" ] && {{ echo 'crew state unreadable' >&2; exit 1; }}
cat "{h}/crew/$1.txt" 2>/dev/null || cat "{fx}/$1.txt" 2>/dev/null || echo 'state: unknown · source: none · no fixture'
""")
    tool(home / "bin" / "fm-inbox.sh", f"""case "$1" in
  receipts) cat "{h}/receipts.json" 2>/dev/null || cat "{fx}/receipts.json" ;;
  note) shift; printf '%s\\n' "$@" > "{h}/note-args"; cat > "{h}/note-body"; cat "{h}/note-body" >> "{h}/note-log"
        echo '{{"schema":"fm-inbox-note.v1","outcome":"created","id":"1700000000-TEST01"}}' ;;
  *) exit 2 ;;
esac
""")
    # Alert issues: #7 open, #8 closed, #9 unreadable. Every call is logged.
    tool(home / "bin" / "gh", f"""echo "$*" >> "{h}/gh-calls"
case "$3" in
  7) echo '{{"state":"OPEN","title":"Alert: <b>deploy</b> health failing","url":"https://github.com/example/demo-repo/issues/7"}}' ;;
  8) echo '{{"state":"CLOSED","title":"Alert: fixed","url":"https://github.com/example/demo-repo/issues/8"}}' ;;
  *) echo 'HTTP 404' >&2; exit 1 ;;
esac
""")
    proj = home / "projects" / "demo-repo"
    proj.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(proj)], check=True)
    subprocess.run(["git", "-C", str(proj), "remote", "add", "origin", "https://github.com/example/demo-repo.git"], check=True)
    return home


def section(page: str, sid: str) -> str:
    """One room's markup: from its id to the next room."""
    i = page.find(f"id='room-{sid}'")
    j = page.find("class=fm-room id=", i + 1)
    return page[i:j if j > 0 else None] if i >= 0 else ""


def text_of(markup: str) -> str:
    return re.sub(r"<[^>]+>", " ", markup)


def request(port: int, method: str, path: str, body: str | None = None, headers: dict | None = None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    h = {"Host": f"127.0.0.1:{port}"}
    if body is not None:
        h["Content-Type"] = "application/x-www-form-urlencoded"
    h.update(headers or {})
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, dict(r.getheaders()), data


def open_decision_ids() -> list[str]:
    rows = fmdata.parse_table((FIX / "list.txt").read_text())
    return [r["id"] for r in rows if r["held"] == "yes" and r["hold_kind"] == "captain" and r["state"] != "done"]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="fmdash-check-") as t:
        root = build_home(Path(t))
        home = fmdata.Home(root, gh=str(root / "bin" / "gh"))
        snaps = server.Snapshots(home)
        snaps.refresh()
        srv = server.Server(0, home, snaps)
        port = srv.port
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            run(port, home, snaps)
        finally:
            srv.shutdown()
            srv.server_close()
    with tempfile.TemporaryDirectory(prefix="fmdash-check-") as t:
        incremental(build_home(Path(t)))
    with tempfile.TemporaryDirectory(prefix="fmdash-check-") as t:
        tailnet(build_home(Path(t)))
    print(f"\n{len(FAILS)} failure(s)" if FAILS else "\nall checks passed")
    return 1 if FAILS else 0


TAILNET = "mac.example.ts.net:8600"
LOGIN = "captain@example.com"


def tailnet(root: Path) -> None:
    """The Tailscale Serve view: admitted only for its Host with Serve's one
    vouched login, read-only unless --tailnet-answers, never cross-origin."""
    home = fmdata.Home(root, gh=str(root / "bin" / "gh"))
    snaps = server.Snapshots(home)
    snaps.refresh()
    note = Path(home.home) / "note-args"
    for answers in (False, True):
        srv = server.Server(0, home, snaps, TAILNET, LOGIN, answers)
        port = srv.port
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            ts = {"Host": TAILNET, "Tailscale-User-Login": LOGIN}
            for bad, why in (({"Tailscale-User-Login": "other@example.com"}, "another tailnet login"),
                             ({"Tailscale-User-Login": LOGIN.upper()}, "a login matching only case-insensitively"),
                             ({"Tailscale-User-Login": ""}, "empty login"),
                             ({"Host": "other.example.ts.net:8600"}, "another tailnet host")):
                code, _, _ = request(port, "GET", "/api/summary", headers={**ts, **bad})
                check(code == 421, f"tailnet view refused: {why} (answers={answers})")
            code, _, _ = request(port, "GET", "/api/summary", headers={"Host": TAILNET})
            check(code == 421, f"tailnet view refused: no Tailscale-User-Login header (tagged device or direct hit) (answers={answers})")
            code, _, page = request(port, "GET", "/", headers=ts)
            page = page.decode()
            check(code == 200 and ("name=token" in page) == answers and ("Read-only view" in page) != answers,
                  f"tailnet page {'carries' if answers else 'omits'} the answer form (answers={answers})")
            code, _, _ = request(port, "GET", "/", headers={"Host": f"127.0.0.1:{port}"})
            check(code == 200, f"loopback still served alongside the tailnet view (answers={answers})")
            d = next(x for x in snaps.get()["decisions"] if x["id"] == "cap-xss")
            _, _, local = request(port, "GET", "/")
            form = urllib.parse.urlencode({"token": request_token(local.decode()), "decision": "cap-xss",
                                           "digest-cap-xss": d["digest"], "text-cap-xss": "Go with (a)."})
            origin = {"Origin": f"https://{TAILNET}"}
            code, _, _ = request(port, "POST", "/answer", form, {**ts, "Origin": "https://evil.example"})
            check(code == 421 and not note.exists(), f"tailnet cross-site Origin refused (answers={answers})")
            code, _, _ = request(port, "POST", "/answer", form, ts)
            check(code == 403 and not note.exists(), f"tailnet answer without an Origin refused (answers={answers})")
            code, h, _ = request(port, "POST", "/answer", form, {**ts, **origin})
            if answers:
                sent = (Path(home.home) / "note-body").read_text() if note.exists() else ""
                check(code == 303 and "sent=" in h.get("Location", "") and f"via the tailnet as {LOGIN}" in sent,
                      "tailnet answer (when enabled) lands as a note naming the tailnet login")
            else:
                check(code == 403 and not note.exists(), "tailnet answer refused while the view is read-only")
        finally:
            srv.shutdown()
            srv.server_close()


def incremental(root: Path) -> None:
    """A refresh re-reads only crews whose state files changed, plus one stale
    reading; an unchanged backlog reuses each `show`."""
    home = fmdata.Home(root, gh=str(root / "bin" / "gh"))
    calls = root / "cli-calls"

    def snap() -> tuple[dict, list[str]]:
        calls.unlink(missing_ok=True)
        s = home.snapshot()
        ran = calls.read_text().splitlines() if calls.exists() else []
        return s, ran

    def crew_reads(ran: list[str]) -> list[str]:
        return sorted(c.split()[1] for c in ran if c.startswith("fm-crew-state.sh"))

    def shows(ran: list[str]) -> list[str]:
        return sorted(c.split()[2] for c in ran if c.startswith("fm-tasks-axi.sh show"))

    def crews(s: dict) -> dict:
        return {t["id"]: t["crew"] for t in s["in_flight"]}

    first, ran = snap()
    check(crew_reads(ran) == ["crew-blocked", "crew-done", "crew-odd", "crew-working"], "first refresh reads every crew")
    again, ran = snap()
    check(crew_reads(ran) == [] and crews(again) == crews(first)
          and all(c.get("observed_at") for c in crews(again).values()),
          "nothing changed: no crew is re-read, and each keeps its reading and when it was read")

    (root / "crew").mkdir()
    (root / "crew/crew-working.txt").write_text("state: blocked · source: status-log · needs a key\n")
    with open(root / "state/crew-blocked.status", "a") as f:
        f.write("working: resumed\n")
    s, ran = snap()
    check(crew_reads(ran) == ["crew-blocked"], f"only the crew whose status log changed is re-read ({crew_reads(ran)})")
    check(crews(s)["crew-working"]["state"] == "working", "an unchanged crew keeps its cached reading")

    for tid, age in (("crew-working", 300), ("crew-odd", 200)):
        home._crew[tid]["at"] -= age
    s, ran = snap()
    check(crew_reads(ran) == ["crew-working"] and crews(s)["crew-working"]["state"] == "blocked",
          "one stale reading is re-read per refresh, oldest first, and its new state shows")
    s, ran = snap()
    check(crew_reads(ran) == ["crew-odd"], "the next stale reading follows on the next refresh")

    (root / "crew/crew-done.fail").touch()
    (root / "state/crew-done.meta").write_text((root / "state/crew-done.meta").read_text() + "note=x\n")
    s, ran = snap()
    check(crew_reads(ran) == ["crew-done"] and crews(s)["crew-done"]["state"] == "unknown"
          and "unreadable" in crews(s)["crew-done"]["detail"], "a meta change re-reads; a failed read shows unknown")
    (root / "crew/crew-done.fail").unlink()
    s, ran = snap()
    check(crew_reads(ran) == ["crew-done"] and crews(s)["crew-done"]["state"] != "unknown",
          "a failed read is not cached: the next refresh retries it")

    lines = [ln.replace("count: 12", "count: 11").replace("tasks[12]", "tasks[11]")
             for ln in (FIX / "list.txt").read_text().splitlines() if not ln.lstrip().startswith("crew-odd,")]
    (root / "list.txt").write_text("\n".join(lines) + "\n")
    s, ran = snap()
    check("crew-odd" not in crews(s) and "crew-odd" not in home._crew, "a crew no longer in flight drops out")
    (root / "list.txt").unlink()
    s, ran = snap()
    check(crew_reads(ran) == ["crew-odd"], "a crew back in flight is read afresh")

    check(shows(ran) == ["cap-long", "cap-xss"], "with no markdown backlog, every refresh re-runs show")
    backlog = root / "data/backlog.md"
    backlog.write_text("# backlog\n")
    _, ran = snap()
    check(shows(ran) == ["cap-long", "cap-xss"], "a backlog change re-runs show")
    s, ran = snap()
    check(shows(ran) == [] and [d["title"] for d in s["decisions"]] == [d["title"] for d in first["decisions"]]
          and [d["reason"] for d in s["decisions"]] == [d["reason"] for d in first["decisions"]],
          "an unchanged backlog reuses each show, with the same decision text")
    backlog.write_text("# backlog\n- edited\n")
    _, ran = snap()
    check(shows(ran) == ["cap-long", "cap-xss"], "an edited backlog re-runs show")

    # An answer is bound to the decision text as it stands, never a cached show.
    snaps = server.Snapshots(home)
    shown = snaps.refresh()
    _, ran = snap()
    check(shows(ran) == [], "the show cache is primed")
    srv = server.Server(0, home, snaps)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        _, _, page = request(srv.port, "GET", "/")
        d = next(x for x in shown["decisions"] if x["id"] == "cap-xss")
        (root / "show-cap-xss.txt").write_text((FIX / "show-cap-xss.txt").read_text().replace("Two calls", "Three calls"))
        form = {"token": request_token(page.decode()), "decision": "cap-xss", "digest-cap-xss": d["digest"],
                "text-cap-xss": "Go with (a)."}
        code, h, _ = request(srv.port, "POST", "/answer", urllib.parse.urlencode(form))
        check(code == 303 and "changed+since" in h.get("Location", "") and not (root / "note-args").exists(),
              "an answer to decision text changed since it was shown is refused, even with the show cached")
    finally:
        srv.shutdown()
        srv.server_close()


def run(port: int, home: fmdata.Home, snaps: server.Snapshots) -> None:
    code, hdrs, body = request(port, "GET", "/")
    page = body.decode()
    check(code == 200, "GET / renders")

    # every open decision appears as a row of one table, each with its own answer field and Send
    ids = open_decision_ids()
    check(sorted(ids) == ["cap-long", "cap-xss"], f"fixture has the two open captain holds ({ids})")
    for i in ids:
        check(f"<tr class=fm-decision id='d-{i}' data-decision='{i}'" in page and f"name='text-{i}'" in page
              and f"name='digest-{i}'" in page and f"name=decision value='{i}'>Send</button>" in page,
              f"decision {i} is a table row with its own answer field and Send")
    check(page.count("<form method=post action='/answer' class=fm-calls>") == 1 and page.count("class=fm-all>Answer all") == 1,
          "one form holds every call, with one Answer all button")
    check("data-decision='wait-dep'" not in page, "a non-captain hold is queued, not a decision")
    check("cuts it off right here at the end" in page, "truncated list title replaced by the full `show` title")
    check("sent as inbox note <code>1700000000-PREV01</code>" in page, "an earlier dashboard answer is shown on its decision")

    # escaping
    for raw in ("<script>alert", "<img src=x", "<b>feed</b>", "<b>deploy</b>", "<i>next</i>"):
        check(raw not in page, f"hostile text not emitted raw: {raw}")
    check("Pick &lt;script&gt;alert(&quot;t&quot;)&lt;/script&gt; &amp; go" in page, "decision title escaped")
    check("&lt;img src=x onerror=alert(1)&gt;\nline two" in page, "decision reason escaped, line break kept")

    # theme
    bebop = render.THEMES["bebop"]["palette"]
    check("data-theme='bebop'" in page, "default theme is bebop")
    check(f'html[data-theme="bebop"]{{--bg:{bebop["--bg"]}' in page, "bebop palette inlined")
    ship = render.THEMES["bebop"].get("ship_image", "")
    check(bool(ship) and ship in page, "bebop ship art referenced")
    code, hdrs, img = request(port, "GET", ship) if ship else (0, {}, b"")
    check(code == 200 and hdrs.get("Content-Type") == "image/png" and img[:8] == b"\x89PNG\r\n\x1a\n", "ship art served as PNG")
    check(">Ed</span>" in page and ">Jet</span>" in page, "crew badges drawn in bebop")
    code, _, plain = request(port, "GET", "/?theme=plain")
    check(code == 200 and "data-theme='plain'" in plain.decode() and ship not in plain.decode()
          and "class=crew-badge" not in plain.decode(), "plain theme: no art, no badges")
    for theme in ("plain", "bebop"):
        pal = render.THEMES[theme]["palette"]
        low = [(fg, bg, round(render.contrast(pal[fg], pal[bg]), 2))
               for fg in ("--fg", "--muted", "--accent", "--warn", "--ok", "--info", "--bad", "--brass")
               for bg in ("--bg", "--surface", "--surface-2") if render.contrast(pal[fg], pal[bg]) < 4.5]
        # --bg text on a filled chip: Verified (--ok) and the nav's hot count (--warn)
        low += [("--bg", fill, round(render.contrast(pal["--bg"], pal[fill]), 2))
                for fill in ("--ok", "--warn") if render.contrast(pal["--bg"], pal[fill]) < 4.5]
        check(not low, f"{theme}: every text colour is AA (4.5:1) on every surface it is drawn on {low or ''}")

    # the whole page is the ship: the cutaway, one live card per room, Big Shot's screen
    check("class=fm-art role=img" in page and "class=fm-bigshot-art role=img" in page and ".fm-art{aspect-ratio:" in page,
          "bebop draws the ship cutaway and Big Shot's screen from the ship art")
    slots = re.findall(r"<li class=fm-slot data-station='(\w+)'", page)
    check(slots == [s["id"] for s in render.STATIONS], f"one live card per ship room, in art order ({slots})")
    check("crew-blocked" in section(page, "buildbay") and "crew-done" in section(page, "buildbay")
          and "crew-working" in section(page, "scout") and "crew-odd" in section(page, "cargo")
          and "crew-blocked" not in section(page, "scout"),
          "each crew sits in its kind's room; an unknown kind goes to the cargo hold, not a guessed room")
    check("id=decisions" in section(page, "bridge") and "data-decision='cap-xss'" in section(page, "bridge"),
          "captain calls are answered on the Bridge")
    check(re.search(r"data-station='scout' data-live", page) is not None
          and re.search(r"data-station='buildbay' data-live", page) is None
          and re.search(r"data-station='buildbay'[^>]* data-hot", page) is not None,
          "only a room with a working crew moves; a blocked crew marks its room for attention")
    plain_page = plain.decode()
    check(re.findall(r"<li class=fm-slot data-station='(\w+)'", plain_page) == slots and "id=bounties" in plain_page
          and "class=fm-art" not in plain_page, "plain draws the same rooms and bounty board, with no art")

    # Big Shot's bounty board
    board = {b["id"]: b for b in snaps.get()["bounties"]}
    want = {"cap-xss": "open", "cap-long": "in_progress", "wait-dep": "open", "next-up": "open",
            "crew-done": "awaiting_evidence", "old-done": "verified", "scout-done": "verified",
            "bare-done": "awaiting_evidence", "signal-demo-repo-7": "in_progress", "signal-demo-repo-9": "open"}
    got = {i: board.get(i, {}).get("status") for i in want}
    check(got == want, f"bounty status per source ({ {i: s for i, s in got.items() if s != want[i]} or 'all match'})")
    check("call-done" not in board and "signal-demo-repo-8" not in board and "crew-blocked" not in board,
          "no card for an answered call, a closed alert issue, or routine crew work")
    for bid, status in want.items():
        check(f"id='b-{bid}' data-bounty='{status}'" in page, f"bounty {bid} drawn as {status}")
    check(all((b.get("proof") or {}).get("kind") in ("pr", "report") for b in board.values() if b["status"] == "verified")
          and page.count("<strong>Verified</strong>") == sum(1 for b in board.values() if b["status"] == "verified"),
          "Verified only with a merged PR or report on record")
    check("merged PR <a href='https://github.com/example/demo-repo/pull/40'" in page
          and "report <a href='/report?path=data%2Fscout-done%2Freport.md'>" in page,
          "a verified card links its merged PR or report")
    check(board["next-up"]["note"] == "Starts after crew-working." and "dependency" in board["wait-dep"]["note"]
          and "not re-checked" in board["signal-demo-repo-9"]["note"] and "crew-done" in board["signal-demo-repo-7"]["note"],
          "each open card says what it is waiting on")
    i, j = page.find("<aside id=bounties"), page.find("</aside>")
    words = text_of(page[i:j]).replace("No money, rewards, points or revenue", "")
    money = re.findall(r"\$|\breward|\bpayout|\bprize|\bpoints?\b|\brevenue|\bamount|\bprice|\busd\b", words, re.I)
    check(i >= 0 and not money, f"bounty board has no money/reward wording {money or ''}")
    calls = (Path(home.home) / "gh-calls").read_text().splitlines()
    snaps.refresh()
    check(len(calls) == 3 and len((Path(home.home) / "gh-calls").read_text().splitlines()) == 3,
          f"alert issues are looked up once per refresh window, not every refresh ({len(calls)} calls)")

    # page hardening
    csp = hdrs_of(port, "/").get("Content-Security-Policy", "")
    check("script-src 'nonce-" in csp and "form-action 'self'" in csp, "CSP pins scripts to a nonce and forms to self")

    # status crew state + PR from the status log
    check("data-d='blocked'>blocked</span>" in page, "crew-state word shown verbatim with its style")
    stamp = r"<time datetime='(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)'>\1</time>"
    check(len(re.findall(r"state read " + stamp, page)) == 4, "each crew row says when its state was read")
    check(re.search(r"<tr id='t-crew-blocked' data-attn>.*?last report " + stamp, page) is not None
          and "<a href='/#t-crew-blocked'>1 crew needs a look</a>" in page,
          "a crew row says when it last reported; the attention count links to the crew that needs a look")
    check("https://github.com/example/demo-repo/pull/41" in page, "PR URL read from the status log")

    # summary + projects
    code, _, s = request(port, "GET", "/api/summary")
    s = json.loads(s)
    check(code == 200 and s["open_decisions"] == 2 and s["attention"] == 1 and s["in_flight"] == 4 and s["queued"] == 2,
          f"/api/summary counts ({ {k: s.get(k) for k in ('open_decisions', 'attention', 'in_flight', 'queued')} })")
    check(s["open_ids"] == "cap-long,cap-xss", "/api/summary open_ids")
    code, _, p = request(port, "GET", "/api/projects")
    p = {r["project"]: r for r in json.loads(p)["projects"]}
    demo = p.get("demo-repo", {})
    check(code == 200 and {"project", "repo", "tasks", "prs", "open_decisions", "next_step", "needs_wake"} <= demo.keys(),
          "/api/projects rows carry the fields fleet-tools.ts reads")
    check([d["id"] for d in demo.get("open_decisions", [])] == ["cap-xss"] and len(demo.get("tasks", [])) == 4
          and demo.get("prs", [{}])[0].get("number") == 41, "/api/projects joins decisions, crews and PRs per repo")

    # reports: only ones an open decision names, only inside data/
    code, _, r = request(port, "GET", "/report?path=" + urllib.parse.quote("data/cap-xss/report.md"))
    check(code == 200 and "&lt;script&gt;alert(&quot;report&quot;)" in r.decode() and "<script>alert" not in r.decode(),
          "named report served, escaped")
    code, _, r = request(port, "GET", "/report?path=" + urllib.parse.quote("data/scout-done/report.md"))
    check(code == 200 and "Findings &lt;b&gt;here&lt;/b&gt;" in r.decode(), "a verified bounty's report is served, escaped")
    for bad in ("../../../etc/passwd", "data/../state/crew-blocked.meta", "data/other.md"):
        code, _, _ = request(port, "GET", "/report?path=" + urllib.parse.quote(bad))
        check(code == 404, f"report refused: {bad}")

    reports_view(port, home)

    # answer guards
    d = next(x for x in snaps.get()["decisions"] if x["id"] == "cap-xss")
    good = {"token": request_token(page), "decision": "cap-xss", "digest-cap-xss": d["digest"], "text-cap-xss": "Go with (a)."}
    note = Path(home.home) / "note-args"
    code, _, _ = request(port, "GET", "/api/summary", headers={"Host": f"evil.example:{port}"})
    check(code == 421, "foreign Host refused (DNS rebinding)")
    code, _, _ = request(port, "POST", "/answer", urllib.parse.urlencode(good), {"Origin": "https://evil.example"})
    check(code == 421 and not note.exists(), "cross-site Origin refused, nothing sent")
    code, _, _ = request(port, "POST", "/answer", urllib.parse.urlencode(good), {"Origin": "null"})
    check(code == 421 and not note.exists(), "opaque Origin: null refused, nothing sent")
    # A browser posting from our own page must send a real Origin, which
    # Referrer-Policy: no-referrer would turn into `null`.
    check(hdrs_of(port, "/").get("Referrer-Policy") not in ("no-referrer", None), "page keeps a same-origin Origin on its own POST")
    # A refused POST must not leave its body on the keep-alive socket.
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("POST", "/answer", body=urllib.parse.urlencode(good),
              headers={"Host": f"evil.example:{port}", "Content-Type": "application/x-www-form-urlencoded"})
    r1 = c.getresponse()
    first = r1.status
    r1.read()
    c.request("GET", "/healthz", headers={"Host": f"127.0.0.1:{port}"})
    second = c.getresponse()
    check(first == 421 and second.status == 200 and second.read() == b"ok", "refused POST leaves the connection usable")
    c.close()
    code, _, _ = request(port, "POST", "/answer", urllib.parse.urlencode({**good, "token": "wrong"}))
    check(code == 403 and not note.exists(), "bad token refused, nothing sent")
    code, h, _ = request(port, "POST", "/answer", urllib.parse.urlencode({**good, "digest-cap-xss": "0" * 16}))
    check(code == 303 and "changed+since" in h.get("Location", "") and not note.exists(), "stale decision text refused, nothing sent")
    code, h, _ = request(port, "POST", "/answer", urllib.parse.urlencode({**good, "decision": "wait-dep", "text-wait-dep": "Go."}))
    check(code == 303 and "no+longer+open" in h.get("Location", "") and not note.exists(), "non-decision id refused, nothing sent")
    code, h, _ = request(port, "POST", "/answer", urllib.parse.urlencode({**good, "text-cap-xss": "   ", "text-cap-long": "Ship it."}))
    check(code == 303 and "err=" in h.get("Location", "") and not note.exists(),
          "a row's Send with its own answer blank is refused, and never sends another row's answer")

    code, h, _ = request(port, "POST", "/answer", urllib.parse.urlencode(good), {"Origin": f"http://127.0.0.1:{port}"})
    check(code == 303 and "sent=1700000000-TEST01" in h.get("Location", ""), "accepted answer redirects with the note id")
    args = note.read_text().split("\n") if note.exists() else []
    sent = (Path(home.home) / "note-body").read_text() if note.exists() else ""
    check(args[:2] == ["--request-id", fmdata.request_id("cap-xss", d["digest"], "Go with (a).")] and "--json" in args,
          "inbox note carries the idempotency key")
    check("decision cap-xss" in sent and "Go with (a)." in sent and d["digest"] in sent,
          "inbox note names the decision, the shown text's digest and the answer")
    code, _, landed = request(port, "GET", h.get("Location", "/").split("#")[0])
    bridge = section(landed.decode(), "bridge")
    check(code == 200 and bridge.find("id=decisions") < bridge.find("Sent to the Firstmate inbox as note 1700000000-TEST01") > 0,
          "the sent confirmation is drawn under Your calls, where the redirect lands")

    # Answer all: every typed answer goes as its own note, bound to its own text.
    log = Path(home.home) / "note-log"
    long_d = next(x for x in snaps.get()["decisions"] if x["id"] == "cap-long")
    both = {"token": good["token"], "digest-cap-xss": d["digest"], "digest-cap-long": long_d["digest"],
            "text-cap-xss": "Go with (a).", "text-cap-long": "Ship it."}

    def answer_all(**f) -> tuple[str, list[str]]:
        log.unlink(missing_ok=True)
        _, h, _ = request(port, "POST", "/answer", urllib.parse.urlencode({**both, **f}))
        return h.get("Location", ""), sorted(re.findall(r"for decision (\S+) \(", log.read_text() if log.exists() else ""))

    loc, went = answer_all()
    check(went == ["cap-long", "cap-xss"] and "sent=1700000000-TEST01%2C1700000000-TEST01" in loc and "err=" not in loc,
          f"Answer all sends every typed answer, one inbox note per call ({went})")
    _, _, landed = request(port, "GET", loc.split("#")[0])
    check("Sent 2 answers to the Firstmate inbox as notes 1700000000-TEST01, 1700000000-TEST01" in section(landed.decode(), "bridge"),
          "Answer all's confirmation names every note sent")
    loc, went = answer_all(**{"text-cap-long": "  "})
    check(went == ["cap-xss"] and "sent=" in loc and "err=" not in loc, f"Answer all skips a row left blank ({went})")
    loc, went = answer_all(decision="cap-long")
    check(went == ["cap-long"], f"a row's Send sends only that row, even with other answers typed ({went})")
    loc, went = answer_all(**{"digest-cap-long": "0" * 16})
    check(went == ["cap-xss"] and "sent=" in loc and "cap-long+changed+since" in loc,
          f"Answer all with one stale call sends the others and names the one refused ({went})")
    _, _, landed = request(port, "GET", loc.split("#")[0])
    bridge = section(landed.decode(), "bridge")
    check("class='fm-flash' role=status>Sent to the Firstmate inbox as note" in bridge
          and "class='fm-flash bad' role=alert>Decision cap-long changed since" in bridge,
          "a partly refused Answer all shows both what was sent and what was not")
    loc, went = answer_all(**{"text-cap-xss": " ", "text-cap-long": ""})
    check(went == [] and "err=Type+an+answer" in loc, "Answer all with nothing typed sends nothing")

    # An answer counts as answered only for the decision text it was bound to.
    receipts = json.loads((FIX / "receipts.json").read_text())
    receipts["pending"].append({"id": "1700000000-TEST01", "at": "2026-11-05T09:00:00Z", "acknowledged": False,
                                "request_id": fmdata.request_id("cap-xss", d["digest"], "Go with (a).")})
    (Path(home.home) / "receipts.json").write_text(json.dumps(receipts))
    snaps.refresh()
    _, _, page = request(port, "GET", "/")
    page = page.decode()
    card = lambda i: page[page.find(f"id='d-{i}'"):page.find("</tr>", page.find(f"id='d-{i}'"))]  # noqa: E731
    check("data-answered>" in card("cap-xss") and "class=fm-chip>answered<" in card("cap-xss") and "class=fm-tick" in card("cap-xss"),
          "a call answered at its current text is marked answered, with a check mark")
    check("data-answered" not in card("cap-long") and "text changed since your answer" in card("cap-long")
          and "class=fm-tick" not in card("cap-long"),
          "a call answered only at an earlier text still needs you, and says its text changed")
    check("Needs your call: <strong>1</strong> <span class=dim>· 1 answered" in page and "<title>(1) Firstmate</title>" in page,
          "the call bar and tab title count only calls that still need you")

    # a failed read must not look like an empty fleet
    (Path(home.home) / "FAIL_LIST").touch()
    snaps.refresh()
    code, _, s = request(port, "GET", "/api/summary")
    s = json.loads(s)
    check(code == 503 and "attention" not in s and "open_decisions" not in s, "failed read: 503 with no counts")
    code, _, page = request(port, "GET", "/")
    page = page.decode()
    check(code == 200 and "backlog unreadable" in page, "failed read shown on the page")
    check("Nothing is waiting on you" not in page and "No crew here right now" not in page
          and "Needs your call: <strong>?</strong>" in page and "<title>(!) Firstmate</title>" in page,
          "failed read: the page never says nothing needs you, and its counts read unknown")
    code, _, r = request(port, "GET", "/report?path=" + urllib.parse.quote("data/crew-blocked/report.md"))
    r = r.decode()
    check(code == 200 and "Whether these calls are held is unknown" in r and "No open captain hold" not in r,
          "failed read: a report still opens, and never says its calls are not held")


def reports_view(port: int, home: fmdata.Home) -> None:
    """The Reports view: every data/<id>/report.md newest first, drawn as a
    document with its captain calls pinned and linked to the held decision."""
    data = Path(home.home) / "data"
    for age, rid in enumerate(("crew-blocked", "scout-done", "cap-xss")):
        os.utime(data / rid / "report.md", (1_800_000_000 - age * 3600,) * 2)
    (data / "escape").mkdir()
    (data / "escape" / "report.md").symlink_to(Path(home.home) / "state" / "crew-blocked.meta")
    (data / "notes.md").write_text("# not a report\n")

    code, hdrs, body = request(port, "GET", "/reports")
    page = body.decode()
    listed = re.findall(r"<tr id='rep-([^']+)'>", page)
    check(code == 200 and listed == ["crew-blocked", "scout-done", "cap-xss"],
          f"/reports lists each data/<id>/report.md newest first, nothing outside data/ or not a report ({listed})")
    row = lambda rid: page[page.find(f"<tr id='rep-{rid}'>"):page.find("</tr>", page.find(f"<tr id='rep-{rid}'>"))]  # noqa: E731
    check(">Feed fix: &lt;b&gt;debt&lt;/b&gt; &amp; calls</a>" in row("crew-blocked"),
          "a listed report is titled by its first heading, escaped; a heading inside a code fence is not it")
    check("href='/#d-cap-xss'>held: cap-xss</a>" in row("crew-blocked") and "href='/#d-cap-xss'>held: cap-xss</a>" in row("cap-xss")
          and "held:" not in row("scout-done"),
          "a report links the held decision whose hold origin is its task, or whose reason names it; others link none")
    csp = lambda h: re.sub(r"'nonce-[^']+'", "'nonce'", h.get("Content-Security-Policy", ""))  # noqa: E731
    check(csp(hdrs) == csp(hdrs_of(port, "/")) and "script-src 'nonce'" in csp(hdrs),
          "report pages carry the ship page's CSP unchanged")
    for bad in ("data/escape/report.md", "data/notes.md", "data/./crew-blocked/report.md", "data/../data/crew-blocked/report.md"):
        code, _, _ = request(port, "GET", "/report?path=" + urllib.parse.quote(bad))
        check(code == 404, f"report refused: {bad}")
    code, _, _ = request(port, "POST", "/report?path=data%2Fcrew-blocked%2Freport.md", "x=1")
    check(code == 404 and not (Path(home.home) / "note-args").exists(), "a report takes no POST: the only write is /answer")

    code, _, body = request(port, "GET", "/report?path=" + urllib.parse.quote("data/crew-blocked/report.md"))
    r = body.decode()
    check(code == 200 and "<title>Feed fix: &lt;b&gt;debt&lt;/b&gt; &amp; calls · Report</title>" in r, "a report renders, titled")
    for raw in ("<img src=x", "<script>alert(\"cell\")", "<script>alert('m')", "<b>debt</b>", "javascript:"):
        check(raw not in r, f"report markdown never emits raw markup or a script link: {raw}")
    check("&lt;img src=x onerror=alert(2)&gt;" in r and "a trap" in r
          and "<a href='https://github.com/example/demo-repo/pull/41' rel=noreferrer>the PR</a>" in r
          and "<a href='https://github.com/example/demo-repo/issues/7' rel=noreferrer>https://github.com/example/demo-repo/issues/7</a>." in r
          and "<a href='#r-debt-register'>the register</a>" in r and "<h2 id='r-debt-register'>" in r,
          "report links: http(s) leave the page, #anchors land in the report, anything else stays text")
    check("class=fm-mermaid" in r and "A[&quot;&lt;script&gt;alert(&#x27;m&#x27;)&lt;/script&gt;&quot;] --&gt; B" in r,
          "a mermaid block is shown as escaped source")
    pin, first_h2 = r.find("class=fm-pin id='r-captain-calls' data-held"), r.find("<h2 id='r-debt-register'>")
    calls = r[pin:r.find("</section>", pin)]
    check(0 < pin < first_h2 and r.count("id='r-captain-calls'") == 1,
          "the Captain calls section is pinned above the report body, once")
    check("2 calls · pinned from the report" in calls and "<li value=2><strong>Retire the old feed.</strong>" in calls
          and "<ul><li>(a) yes. <strong>Recommended.</strong></li>" in calls,
          "pinned calls keep the report's numbering and nesting")
    check("Held for you as <a href='/#d-cap-xss'><code>cap-xss</code>" in calls,
          "pinned calls link the matching held decision card on the Bridge")
    code, _, body = request(port, "GET", "/report?path=" + urllib.parse.quote("data/scout-done/report.md"))
    check(code == 200 and "No open captain hold" not in body.decode() and "class=fm-pin" not in body.decode(),
          "a report with no calls and no hold pins nothing")

    i = r.find("<table id=rt-1")
    table = r[r.rfind("<div class=fm-mdt", 0, i):r.find("</table>", i)]
    heads = re.findall(r"<th scope=col><button type=button class=fm-sort>([^<]*)</button></th>", table)
    menus = re.findall(r"<label>(\w+) <select data-col=(\d+)", table)
    check(heads == ["ID", "Repo", "Item", "Sev"], f"every column header sorts ({heads})")
    check(menus == [("Repo", "1"), ("Sev", "3")] and "<option value='P2'>P2 (2)</option>" in table
          and "<option value='other-repo'>other-repo (2)</option>" in table,
          f"facet menus for short repeating columns, with counts; none for unique or long ones ({menus})")
    check("<tr data-i=1 data-f1='demo-repo\nother-repo' data-f3='P2'>" in table,
          "a comma-listed cell belongs to each value's facet")
    check("data-ref='data/crew-blocked/report.md#debt-register — D-002 | demo-repo, other-repo | pipe in code: a | b | P2'" in table,
          "a row's copy reference is one line: report#section, then its cells as text")

    # A hostile report: every line below backtracked for seconds to minutes in
    # an earlier draft, and a regex holds the GIL, so it would stall the whole
    # dashboard. Both report routes must still answer at once.
    hostile = data / "zz-hostile"
    hostile.mkdir()
    (hostile / "report.md").write_text("\n\n".join([
        "# Hostile" + " " * 50_000 + "x",
        " ".join("`" * k for k in range(1, 700)),
        "```" + "a" * 50_000 + "`",
        "[" * 50_000,
        "a \\| b\n" + " " * 50_000 + "x\\|",
        "-" + " -" * 20_000 + " x",
        ">" * 20_000 + " x",
        "| ID | Note |\n|---|---|\n| D-1 | ok\x1b[201~rm -rf ~\x0f\u202eevil |",
    ]))
    os.utime(hostile / "report.md", (1_700_000_000,) * 2)
    for path in ("/reports", "/report?path=" + urllib.parse.quote("data/zz-hostile/report.md")):
        t = time.monotonic()
        code, _, body = request(port, "GET", path)
        took = time.monotonic() - t
        check(code == 200 and took < 2, f"a hostile report renders in linear time: {path} ({code}, {took:.2f}s)")
    refs = re.findall(r"data-ref='([^']*)'", body.decode())
    check(refs == ["data/zz-hostile/report.md#hostile-x — D-1 | ok [201~rm -rf ~ evil"],
          f"a copied reference carries no control or bidi characters a terminal would act on ({refs})")


def hdrs_of(port: int, path: str) -> dict:
    return request(port, "GET", path)[1]


def request_token(page: str) -> str:
    marker = "name=token value='"
    i = page.find(marker)
    return page[i + len(marker):page.index("'", i + len(marker))] if i >= 0 else ""


if __name__ == "__main__":
    os.environ.pop("FM_HOME", None)
    sys.exit(main())
