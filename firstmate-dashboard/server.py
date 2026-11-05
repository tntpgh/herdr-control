#!/usr/bin/env python3
"""firstmate-dashboard — a read-only view of one Firstmate home, drawn as the Bebop ship.

    python3 firstmate-dashboard/server.py --home ~/Code/firstmate [--port 8600]

Binds 127.0.0.1 only. Reads the home through its own CLIs (fmdata.py) on a
background refresh; requests are served from the last snapshot.

The single write is POST /answer: the captain's text becomes one
`fm-inbox.sh note` naming the decision. Nothing here merges, approves, spawns
or runs anything; Firstmate reads the note and decides. An answer is bound to
the exact decision text the page showed (its digest) and refused if that
text has changed since, so a stale page cannot answer a different question.

Routes
  /               the ship: rooms with live crews, Big Shot's bounty board, your calls
  /report?path=   a report file an open decision or a verified bounty names (inside data/ only)
  /answer         POST: decision answer -> Firstmate captain inbox
  /api/summary    counts; the field names the omp status line reads
  /api/projects   read-only per-repo join in the shape fleet-tools.ts reads
  /healthz        ok
  /static/ship-*  the theme's ship art (content-addressed)
"""
from __future__ import annotations

import argparse
import hmac
import http.server
import json
import os
import secrets
import socketserver
import sys
import threading
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fmdata  # noqa: E402
import render  # noqa: E402

BIND = "127.0.0.1"
DEFAULT_PORT = 8600
REFRESH_S = 10
MAX_BODY = 16 * 1024
MAX_REPORT = 512 * 1024


class Snapshots:
    """Background refresh so a page load never waits on the CLIs, except the
    very first one."""

    def __init__(self, home: fmdata.Home, interval: float = REFRESH_S):
        self.home, self.interval = home, interval
        self._snap: dict | None = None
        self._ready = threading.Event()
        self._lock = threading.Lock()

    def start(self) -> None:
        threading.Thread(target=self._loop, name="fm-snapshot", daemon=True).start()

    def _loop(self) -> None:
        while True:
            self.refresh()
            time.sleep(self.interval)

    def refresh(self, fresh: bool = False) -> dict:
        try:
            snap = self.home.snapshot(fresh=fresh)
        except Exception as e:  # noqa: BLE001 - a read bug must surface on the page, not kill the loop
            snap = {"ok": False, "errors": [f"snapshot failed: {type(e).__name__}: {e}"], "decisions": [],
                    "in_flight": [], "queued": [], "done": [], "bounties": [], "counts": {}, "fingerprint": "",
                    "home": str(self.home.home)}
        with self._lock:
            self._snap = snap
        self._ready.set()
        return snap

    def get(self, timeout: float = 30) -> dict:
        self._ready.wait(timeout)
        with self._lock:
            return self._snap or {"ok": False, "errors": ["first read still running"], "decisions": [], "in_flight": [],
                                  "queued": [], "done": [], "bounties": [], "counts": {}, "fingerprint": ""}


def summary(snap: dict) -> dict:
    if not snap.get("ok"):
        # No counts at all rather than zeros: the omp status line skips a body
        # without `attention`/`open_decisions`, so a failed read cannot pass
        # for "nothing needs you".
        return {"source": "firstmate", "ok": False, "error": "; ".join(snap.get("errors", [])) or "no snapshot"}
    c = snap.get("counts", {})
    return {"source": "firstmate", "home": snap.get("home"), "generated": snap.get("generated"),
            "ok": True, "errors": snap.get("errors", []),
            # `attention` + `open_decisions` are what agent-hooks/omp-herdr-control.ts reads.
            "attention": c.get("attention_tasks", 0), "attention_tasks": c.get("attention_tasks", 0),
            "open_decisions": c.get("open_decisions", 0), "in_flight": c.get("in_flight", 0),
            "queued": c.get("queued", 0), "done_recent": c.get("done_recent", 0),
            "open_ids": ",".join(sorted(d["id"] for d in snap.get("decisions", []))),
            "fingerprint": snap.get("fingerprint", "")}


def projects(snap: dict, home: Path) -> dict:
    """Per-repo rows in the shape fleet-tools.ts project_status and the omp
    ambient card read. PR state is not looked up (no network): `state` says so."""
    by: dict[str, dict] = {}

    def row(repo: str) -> dict:
        name = repo or "(no repo)"
        if name not in by:
            path = home / "projects" / repo if repo else None
            by[name] = {"project": name, "repo": str(path) if path and path.is_dir() else None, "tasks": [], "prs": [],
                        "open_decisions": [], "spec_items": [], "next_step": None, "needs_wake": False}
        return by[name]

    for t in snap.get("in_flight", []):
        r = row(t["repo"])
        r["tasks"].append({"task_id": t["id"], "state": t["crew"]["state"], "pane_id": t.get("pane_id"),
                           "label": f"{t['kind']}:{t['id']}", "branch": t.get("branch"), "worktree": t.get("worktree"),
                           "updated_at": t.get("updated_at") or snap.get("generated")})
        for url in t["prs"]:
            num = url.rstrip("/").rsplit("/", 1)[-1]
            r["prs"].append({"number": int(num) if num.isdigit() else 0, "url": url, "title": t["title"],
                             "state": "unverified", "isDraft": False})
    for d in snap.get("decisions", []):
        r = row(d["repo"])
        r["open_decisions"].append({"id": d["id"], "title": d["title"], "status": "open"})
        r["next_step"] = r["next_step"] or f"captain call: {d['title']}"
    return {"source": "firstmate", "generated": snap.get("generated"), "projects": sorted(by.values(), key=lambda p: p["project"])}


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port: int, home: fmdata.Home, snaps: Snapshots):
        super().__init__((BIND, port), Handler)
        self.home, self.snaps = home, snaps
        self.token = secrets.token_urlsafe(24)

    @property
    def port(self) -> int:
        return self.server_address[1]


class Handler(http.server.BaseHTTPRequestHandler):
    server: Server
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: D401 - one line per request on stderr
        sys.stderr.write(f"{self.log_date_time_string()} {self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}\n")

    # ── guards ───────────────────────────────────────────────────────────
    def _host_ok(self) -> bool:
        """Only our own origin. A page on any other site can still make the
        browser send a request here; Host (DNS rebinding) and Origin (cross-site
        POST) say who is asking."""
        allowed = {f"127.0.0.1:{self.server.port}", f"localhost:{self.server.port}"}
        if self.headers.get("Host", "") not in allowed:
            return False
        origin = self.headers.get("Origin")
        return origin is None or origin in {f"http://{h}" for h in allowed}

    def _send(self, code: int, ctype: str, body: bytes, extra: dict | None = None, nonce: str = "") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        # same-origin, not no-referrer: under no-referrer Chrome sends
        # `Origin: null` on our own form POST, which _host_ok() must refuse.
        # Off-site links still carry nothing (and are rel=noreferrer too).
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        if ctype.startswith("text/html"):
            script = f"'nonce-{nonce}'" if nonce else "'none'"
            self.send_header("Content-Security-Policy",
                             f"default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; script-src {script}; "
                             "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _html(self, code: int, doc: str, nonce: str) -> None:
        self._send(code, "text/html; charset=utf-8", doc.encode(), nonce=nonce)

    def _json(self, code: int, obj) -> None:
        self._send(code, "application/json", json.dumps(obj, default=str).encode())

    # ── routes ───────────────────────────────────────────────────────────
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self._host_ok():
            return self._send(421, "text/plain", b"wrong host")
        url = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(url.query)
        theme = render.theme_of((q.get("theme") or [""])[0])
        nonce = secrets.token_urlsafe(12)
        if url.path == "/healthz":
            return self._send(200, "text/plain", b"ok")
        if url.path == "/favicon.ico":
            return self._send(204, "image/x-icon", b"")
        if url.path in render.STATIC_ASSETS:
            data, ctype = render.STATIC_ASSETS[url.path]
            return self._send(200, ctype, data, {"Cache-Control": "public, max-age=31536000, immutable"})
        snap = self.server.snaps.get()
        if url.path == "/api/summary":
            return self._json(200 if snap.get("ok") else 503, summary(snap))
        if url.path == "/api/projects":
            if not snap.get("ok"):
                return self._json(503, {"error": "; ".join(snap.get("errors", [])) or "no snapshot"})
            return self._json(200, projects(snap, self.server.home.home))
        if url.path == "/":
            sent, bad = (q.get("sent") or [""])[0], (q.get("err") or [""])[0]
            flash = (f"Sent to the Firstmate inbox as note {sent}. Firstmate picks it up at its next check."
                     if sent else bad)
            return self._html(200, render.dashboard(snap, theme, self.server.token, nonce, flash, bool(bad)), nonce)
        if url.path == "/report":
            rel = (q.get("path") or [""])[0]
            named = {r for d in snap.get("decisions", []) for r in d["reports"]} | {
                b["proof"]["ref"] for b in snap.get("bounties", [])
                if b["status"] == "verified" and (b.get("proof") or {}).get("kind") == "report"}
            p = self.server.home.report_file(rel) if rel in named else None
            if p is None:
                return self._html(404, render.message("Not found", "That report is not one an open decision or a verified bounty names.", theme, nonce), nonce)
            data = p.read_bytes()[:MAX_REPORT].decode("utf-8", "replace")
            return self._html(200, render.report(rel, data, theme, nonce), nonce)
        return self._send(404, "text/plain", b"not found")

    def do_POST(self):
        # Read (or refuse to read) the body before any refusal: an unread body
        # left on a keep-alive socket is parsed as the next request line.
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length <= 0 or length > MAX_BODY:
            self.close_connection = True
            return self._send(413, "text/plain", b"body too large or empty")
        raw = self.rfile.read(length)
        if not self._host_ok():
            return self._send(421, "text/plain", b"wrong host")
        if urllib.parse.urlsplit(self.path).path != "/answer":
            return self._send(404, "text/plain", b"not found")
        form = urllib.parse.parse_qs(raw.decode("utf-8", "replace"), keep_blank_values=True)
        get = lambda k: (form.get(k) or [""])[0]  # noqa: E731
        theme = render.theme_of(get("theme"))
        nonce = secrets.token_urlsafe(12)
        if not hmac.compare_digest(get("token").encode(), self.server.token.encode()):
            return self._html(403, render.message("Refused", "This form is from an older dashboard session. Reload and send again.", theme, nonce), nonce)
        text = get("text").replace("\r\n", "\n").strip()
        if not text or len(text) > render.MAX_ANSWER_CHARS:
            return self._redirect(theme, err=f"Answer must be 1-{render.MAX_ANSWER_CHARS} characters.")
        # Re-read, not the cached snapshot, and every decision's `show` uncached:
        # the binding check is only as fresh as this read.
        snap = self.server.snaps.refresh(fresh=True)
        decision = next((d for d in snap.get("decisions", []) if d["id"] == get("decision")), None)
        if decision is None:
            return self._redirect(theme, err=f"Decision {get('decision')} is no longer open; nothing was sent.")
        if not hmac.compare_digest(decision["digest"].encode(), get("digest").encode()):
            return self._redirect(theme, err=f"Decision {decision['id']} changed since this page loaded; nothing was sent. "
                                             "Read it again and resend.")
        body = (f"Captain answer from the dashboard for decision {decision['id']} ({decision['title']}).\n"
                f"Decision text shown (digest {decision['digest']}):\n{decision['reason']}\n\nAnswer:\n{text}\n")
        rid = fmdata.request_id(decision["id"], decision["digest"], text)
        try:
            out = self.server.home.run("fm-inbox.sh", "note", "--request-id", rid, "--json", "-", stdin=body)
            note = json.loads(out.strip().splitlines()[-1]).get("id", "?")
        except (fmdata.CommandError, ValueError, IndexError) as e:
            return self._redirect(theme, err=f"Inbox did not take the answer: {e}")
        self.server.snaps.refresh()
        return self._redirect(theme, sent=note)

    def _redirect(self, theme: dict, **params) -> None:
        q = {k: v for k, v in params.items() if v}
        if theme["id"] != render.DEFAULT_THEME:
            q["theme"] = theme["id"]
        self._send(303, "text/plain", b"see other", {"Location": "/?" + urllib.parse.urlencode(q) + "#decisions"})


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--home", default=os.environ.get("FM_HOME"), help="Firstmate home (FM_HOME); state/ and data/ live here")
    ap.add_argument("--fm-root", help="Firstmate code root holding bin/ (default: --home)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    a = ap.parse_args(argv)
    if not a.home:
        ap.error("--home (or FM_HOME) is required")
    home = fmdata.Home(Path(a.home).expanduser(), Path(a.fm_root).expanduser() if a.fm_root else None)
    for tool in ("fm-tasks-axi.sh", "fm-crew-state.sh", "fm-inbox.sh"):
        if not os.access(home.root / "bin" / tool, os.X_OK):
            ap.error(f"{home.root / 'bin' / tool} is missing or not executable")
    snaps = Snapshots(home)
    srv = Server(a.port, home, snaps)
    snaps.start()
    print(f"firstmate-dashboard: http://{BIND}:{srv.port}/ (home {home.home})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
