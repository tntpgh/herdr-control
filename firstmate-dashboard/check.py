#!/usr/bin/env python3
"""check — render the dashboard against fixture data and assert what matters.

    python3 firstmate-dashboard/check.py

Builds a throwaway Firstmate home from fixtures/ with stand-in CLIs (the
real ones need a real home), serves it on an ephemeral 127.0.0.1 port, and
checks: every open captain decision appears, hostile text is escaped, the
Bebop theme and its ship art load, the summary counts the omp status line
reads, the answer path's guards (token, Host/Origin, stale decision text),
that an accepted answer reaches the inbox CLI naming its decision, and that
a failed read never reports zero counts.
"""
from __future__ import annotations

import http.client
import json
import os
import shutil
import stat
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
case "$1" in
  list) cat "{fx}/list.txt" ;;
  show) cat "{fx}/show-$2.txt" ;;
  *) exit 2 ;;
esac
""")
    tool(home / "bin" / "fm-crew-state.sh", f"""cat "{fx}/$1.txt" 2>/dev/null || echo 'state: unknown · source: none · no fixture'
""")
    tool(home / "bin" / "fm-inbox.sh", f"""case "$1" in
  receipts) cat "{fx}/receipts.json" ;;
  note) shift; printf '%s\\n' "$@" > "{h}/note-args"; cat > "{h}/note-body"
        echo '{{"schema":"fm-inbox-note.v1","outcome":"created","id":"1700000000-TEST01"}}' ;;
  *) exit 2 ;;
esac
""")
    return home


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
        home = fmdata.Home(build_home(Path(t)))
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
    print(f"\n{len(FAILS)} failure(s)" if FAILS else "\nall checks passed")
    return 1 if FAILS else 0


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
    for raw in ("<script>alert", "<img src=x", "<b>feed</b>"):
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

    # page hardening
    csp = hdrs_of(port, "/").get("Content-Security-Policy", "")
    check("script-src 'nonce-" in csp and "form-action 'self'" in csp, "CSP pins scripts to a nonce and forms to self")

    # status crew state + PR from the status log
    check("data-d='blocked'>blocked</span>" in page, "crew-state word shown verbatim with its style")
    check("https://github.com/example/demo-repo/pull/41" in page, "PR URL read from the status log")

    # summary + projects
    code, _, s = request(port, "GET", "/api/summary")
    s = json.loads(s)
    check(code == 200 and s["open_decisions"] == 2 and s["attention"] == 1 and s["in_flight"] == 2 and s["queued"] == 1,
          f"/api/summary counts ({ {k: s.get(k) for k in ('open_decisions', 'attention', 'in_flight', 'queued')} })")
    check(s["open_ids"] == "cap-long,cap-xss", "/api/summary open_ids")
    code, _, p = request(port, "GET", "/api/projects")
    p = {r["project"]: r for r in json.loads(p)["projects"]}
    demo = p.get("demo-repo", {})
    check(code == 200 and {"project", "repo", "tasks", "prs", "open_decisions", "next_step", "needs_wake"} <= demo.keys(),
          "/api/projects rows carry the fields fleet-tools.ts reads")
    check([d["id"] for d in demo.get("open_decisions", [])] == ["cap-xss"] and len(demo.get("tasks", [])) == 2
          and demo.get("prs", [{}])[0].get("number") == 41, "/api/projects joins decisions, crews and PRs per repo")

    # reports: only ones an open decision names, only inside data/
    code, _, r = request(port, "GET", "/report?path=" + urllib.parse.quote("data/cap-xss/report.md"))
    check(code == 200 and "&lt;script&gt;alert(&quot;report&quot;)" in r.decode() and "<script>alert" not in r.decode(),
          "named report served, escaped")
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
