#!/usr/bin/env python3
"""herdr-status.py — the reconciliation report as a localhost page, not a prompt.

Serves the herdr run registry (~/.local/state/herdr/runs/registry.sqlite3,
read-only) at http://127.0.0.1:8650/ so the wake-persistence report never
has to be typed into an agent's context again. The omp extension
(agent-hooks/omp-herdr-control.ts) starts this on session start when the
port is free and injects at most ONE line pointing here.

  GET /            HTML: needs-input, running, recent events, conductor cursors
  GET /?json=1     the same data as JSON
  GET /healthz     200 "ok"

Idempotent to start: a second copy finds the port taken and exits 0.
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import socket
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_PORT = int(os.environ.get("HERDR_STATUS_PORT", "8650"))
REGISTRY = Path(os.environ.get("HERDR_RUN_REGISTRY",
                               Path.home() / ".local/state/herdr/runs/registry.sqlite3"))
ATTENTION = ("input_required", "blocked", "running")


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
    conn.row_factory = sqlite3.Row
    return conn


def snapshot(event_limit: int = 100) -> dict:
    if not REGISTRY.exists():
        return {"error": f"registry not found: {REGISTRY}", "tasks": [], "events": [], "checkpoints": []}
    with _connect() as conn:
        tasks = [dict(r) for r in conn.execute(
            "SELECT task_id, run_id, label, repo, state, pane_id, conductor_id, worktree, created_at, updated_at "
            "FROM tasks ORDER BY updated_at DESC")]
        events = []
        for r in conn.execute(
                "SELECT sequence, type, task_id, occurred_at, payload FROM events ORDER BY sequence DESC LIMIT ?",
                (event_limit,)):
            e = dict(r)
            try:
                e["payload"] = json.loads(e["payload"] or "{}")
            except json.JSONDecodeError:
                e["payload"] = {"_raw": e["payload"]}
            events.append(e)
        checkpoints = [dict(r) for r in conn.execute(
            "SELECT conductor_id, last_event_seq, updated_at FROM checkpoints ORDER BY updated_at DESC")]
        max_seq = conn.execute("SELECT COALESCE(MAX(sequence),0) FROM events").fetchone()[0]
    labels = {t["task_id"]: t["label"] or t["task_id"] for t in tasks}
    for e in events:
        e["label"] = labels.get(e["task_id"], e["task_id"])
    return {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "max_event_seq": max_seq, "tasks": tasks, "events": events, "checkpoints": checkpoints}


def _age(iso: str) -> str:
    try:
        then = dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return iso
    s = int((dt.datetime.now(dt.timezone.utc) - then).total_seconds())
    if s < 90:
        return f"{s}s"
    if s < 5400:
        return f"{s // 60}m"
    if s < 172800:
        return f"{s // 3600}h"
    return f"{s // 86400}d"


def _esc(v) -> str:
    return html.escape(str(v if v is not None else ""))


def render(data: dict) -> str:
    if data.get("error"):
        return f"<!doctype html><title>herdr</title><pre>{_esc(data['error'])}</pre>"
    tasks = data["tasks"]
    attention = [t for t in tasks if t["state"] in ATTENTION]
    attention.sort(key=lambda t: (ATTENTION.index(t["state"]), t["updated_at"]))
    others = [t for t in tasks if t["state"] not in ATTENTION][:40]

    def task_rows(rows):
        out = []
        for t in rows:
            repo = (t["repo"] or "").rsplit("/", 1)[-1]
            out.append(
                f"<tr class='{_esc(t['state'])}'><td><span class='pill'>{_esc(t['state'])}</span></td>"
                f"<td><b>{_esc(t['label'])}</b><br><small>{_esc(repo)} · pane {_esc(t['pane_id'] or '—')}"
                f" · {_esc(t['conductor_id'] or 'no conductor')}</small></td>"
                f"<td class='age' title='{_esc(t['updated_at'])}'>{_esc(_age(t['updated_at']))}</td></tr>")
        return "".join(out) or "<tr><td colspan=3 class='dim'>none</td></tr>"

    ev_rows = []
    for e in data["events"]:
        p = e["payload"]
        detail = " ".join(str(p[k]) for k in ("reason", "outcome", "detail") if p.get(k))
        if p.get("prompt_id"):
            detail += f" prompt={p['prompt_id'][:12]}…"
        ev_rows.append(
            f"<tr><td class='dim'>#{e['sequence']}</td><td><span class='pill'>{_esc(e['type'])}</span></td>"
            f"<td>{_esc(e['label'])}</td><td class='dim'>{_esc(detail)}</td>"
            f"<td class='age' title='{_esc(e['occurred_at'])}'>{_esc(_age(e['occurred_at']))}</td></tr>")

    cp_rows = "".join(
        f"<tr><td>{_esc(c['conductor_id'])}</td><td>{c['last_event_seq']} / {data['max_event_seq']}"
        f"{' <span class=pill>behind</span>' if c['last_event_seq'] < data['max_event_seq'] else ''}</td>"
        f"<td class='age'>{_esc(_age(c['updated_at']))}</td></tr>"
        for c in data["checkpoints"][:12])

    return f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta http-equiv=refresh content=15><title>herdr · {len(attention)} need attention</title>
<style>
 body{{margin:0;background:#0f1115;color:#e6e9ef;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
 main{{max-width:1100px;margin:0 auto;padding:18px 20px 60px}}
 h1{{font-size:18px;margin:0 0 4px}} h2{{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:#9aa3b2;margin:22px 0 8px}}
 table{{width:100%;border-collapse:collapse;background:#171a21;border:1px solid #272c37;border-radius:10px;overflow:hidden}}
 td{{padding:8px 10px;border-top:1px solid #272c37;vertical-align:top}} tr:first-child td{{border-top:0}}
 .pill{{font-size:11px;padding:1px 8px;border-radius:999px;border:1px solid #272c37;color:#9aa3b2;white-space:nowrap}}
 tr.input_required .pill,tr.blocked .pill{{color:#1a1206;background:#e08a4a;border-color:#e08a4a}}
 tr.running .pill{{color:#6aa6ff;border-color:#6aa6ff}}
 .age{{color:#9aa3b2;white-space:nowrap;text-align:right}} .dim{{color:#9aa3b2}} small{{color:#9aa3b2}}
 .sub{{color:#9aa3b2;font-size:12px}}
</style></head><body><main>
<h1>herdr <span class=sub>· registry {_esc(REGISTRY)} · {_esc(data['generated_at'])} · refreshes every 15s · <a href='/?json=1' style='color:#6aa6ff'>json</a></span></h1>
<h2>Needs attention ({len(attention)})</h2><table>{task_rows(attention)}</table>
<h2>Recent events (newest first)</h2><table>{''.join(ev_rows) or "<tr><td class=dim>none</td></tr>"}</table>
<h2>Conductor cursors</h2><table>{cp_rows or "<tr><td class=dim>none</td></tr>"}</table>
<h2>Other tasks (latest 40)</h2><table>{task_rows(others)}</table>
</main></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # quiet by default; this runs for hours
        pass

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/healthz":
            return self._send(200, "text/plain", b"ok")
        if path != "/":
            return self._send(404, "text/plain", b"not found")
        try:
            data = snapshot()
        except sqlite3.Error as e:
            return self._send(503, "text/plain", f"registry unreadable: {e}".encode())
        if "json=1" in query:
            return self._send(200, "application/json", json.dumps(data, default=str).encode())
        return self._send(200, "text/html; charset=utf-8", render(data).encode())

    def _send(self, code: int, ctype: str, body: bytes):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def port_in_use(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = ap.parse_args()
    if port_in_use(args.port):
        print(f"herdr-status: already serving on http://127.0.0.1:{args.port}/", file=sys.stderr)
        return 0
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"herdr-status: http://127.0.0.1:{args.port}/", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
