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
decision, and that a failed read never reports zero counts.
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
  receipts) cat "{fx}/receipts.json" ;;
  note) shift; printf '%s\\n' "$@" > "{h}/note-args"; cat > "{h}/note-body"
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
    print(f"\n{len(FAILS)} failure(s)" if FAILS else "\nall checks passed")
    return 1 if FAILS else 0


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
        form = {"token": request_token(page.decode()), "decision": "cap-xss", "digest": d["digest"], "text": "Go with (a)."}
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

    # every open decision appears, each with its own answer form
    ids = open_decision_ids()
    check(sorted(ids) == ["cap-long", "cap-xss"], f"fixture has the two open captain holds ({ids})")
    for i in ids:
        check(f"data-decision='{i}'" in page and f"name=decision value='{i}'" in page, f"decision {i} shown with an answer form")
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
        low += [("--bg", "--ok", round(render.contrast(pal["--bg"], pal["--ok"]), 2))] if render.contrast(pal["--bg"], pal["--ok"]) < 4.5 else []
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
    check(len(re.findall(r"<div class=dim>state read \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ</div>", page)) == 4,
          "each crew row says when its state was read")
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

    # answer guards
    d = next(x for x in snaps.get()["decisions"] if x["id"] == "cap-xss")
    good = {"token": request_token(page), "decision": "cap-xss", "digest": d["digest"], "text": "Go with (a)."}
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
    code, h, _ = request(port, "POST", "/answer", urllib.parse.urlencode({**good, "digest": "0" * 16}))
    check(code == 303 and "changed+since" in h.get("Location", "") and not note.exists(), "stale decision text refused, nothing sent")
    code, h, _ = request(port, "POST", "/answer", urllib.parse.urlencode({**good, "decision": "wait-dep"}))
    check(code == 303 and "no+longer+open" in h.get("Location", "") and not note.exists(), "non-decision id refused, nothing sent")
    code, h, _ = request(port, "POST", "/answer", urllib.parse.urlencode({**good, "text": "   "}))
    check(code == 303 and "err=" in h.get("Location", "") and not note.exists(), "empty answer refused")

    code, h, _ = request(port, "POST", "/answer", urllib.parse.urlencode(good), {"Origin": f"http://127.0.0.1:{port}"})
    check(code == 303 and "sent=1700000000-TEST01" in h.get("Location", ""), "accepted answer redirects with the note id")
    args = note.read_text().split("\n") if note.exists() else []
    sent = (Path(home.home) / "note-body").read_text() if note.exists() else ""
    check(args[:2] == ["--request-id", fmdata.request_id("cap-xss", d["digest"], "Go with (a).")] and "--json" in args,
          "inbox note carries the idempotency key")
    check("decision cap-xss" in sent and "Go with (a)." in sent and d["digest"] in sent,
          "inbox note names the decision, the shown text's digest and the answer")

    # a failed read must not look like an empty fleet
    (Path(home.home) / "FAIL_LIST").touch()
    snaps.refresh()
    code, _, s = request(port, "GET", "/api/summary")
    s = json.loads(s)
    check(code == 503 and "attention" not in s and "open_decisions" not in s, "failed read: 503 with no counts")
    code, _, page = request(port, "GET", "/")
    check(code == 200 and "backlog unreadable" in page.decode(), "failed read shown on the page")


def hdrs_of(port: int, path: str) -> dict:
    return request(port, "GET", path)[1]


def request_token(page: str) -> str:
    marker = "name=token value='"
    i = page.find(marker)
    return page[i + len(marker):page.index("'", i + len(marker))] if i >= 0 else ""


if __name__ == "__main__":
    os.environ.pop("FM_HOME", None)
    sys.exit(main())
