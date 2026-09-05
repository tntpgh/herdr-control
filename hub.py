#!/usr/bin/env python3
"""hub.py — one localhost page for every operator surface, with sub-pages.

Terrence, 2026-09-05: "lots of tools using their own localhost port and
dashboard … a smart way to aggregate, sub-pages for decisions, an overall
view." This is an INDEX and an INBOX, not a rewrite: every tool keeps its
own server; the hub lists them, checks they are alive, and pulls together
the two things that need a human — attention items and open decisions.

  /            overview cards (herdr attention, decisions, fleet, KB nightly, search memory)
  /herdr       run-registry view: needs-attention, recent events, conductor cursors
  /decisions   inbox: open formserve forms rendered inline, answered ones with answers
  /search      consensus-search memory: totals, last queries, replay counts
  /kb          knowledge-base: last nightly runs + steps, fleet heartbeat snapshot
  /links       every surface with a liveness dot
  /api/summary {attention, open_decisions} — what the omp extension's one-liner reads
  any page     ?json=1 → the page's data as JSON

Sources (all read-only): ~/.local/state/herdr/runs/registry.sqlite3 (herdr),
~/.local/state/herdr/forms/*.json (formserve registry), consensus-search
GET /log (bearer SEARCH_SYNC_TOKEN), knowledge-base's own venv + kb-deploy
checkout for kb.nightly_runs/steps and server.heartbeat.latest_snapshot()
(NEON_CONNECTION_STRING, default_transaction_read_only=on). Secrets come
from the environment or, pre-resolved, from ~/.config/op/service-account.env
— never from an `op` subprocess (see secret()). Loopback only,
no auth — same posture as formserve. Idempotent to start: a second copy sees
the port taken and exits 0.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import html
import json
import os
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_PORT = int(os.environ.get("HERDR_HUB_PORT", "8600"))
STATE = Path(os.environ.get("HERDR_STATE_ROOT", Path.home() / ".local/state/herdr"))
REGISTRY = Path(os.environ.get("HERDR_RUN_REGISTRY", STATE / "runs/registry.sqlite3"))
FORMS_DIR = STATE / "forms"
KB_DEPLOY = Path(os.environ.get("KB_DEPLOY", Path.home() / "Code/kb-deploy"))
KB_PYTHON = Path(os.environ.get("KB_PYTHON", Path.home() / "Code/knowledge-base/.venv/bin/python3"))
SEARCH_URL = os.environ.get("CONSENSUS_SEARCH_URL", "https://consensus.teamthurber.com")
OP_ENV = Path.home() / ".config/op/service-account.env"
ATTENTION = ("input_required", "blocked", "running")

# Every surface the team runs, hosted and local. `probe` is what "alive" means
# for it; hosted ones also get the KB heartbeat verdict when a snapshot exists.
SURFACES = [
    ("consensus·search", SEARCH_URL + "/", "GET", "search"),
    ("tourguide (apps)", "https://apps.teamthurber.com/health", "GET", "tourguide"),
    ("teamthurber.com", "https://teamthurber.com/", "HEAD", "tntpgh"),
    ("thurber-ai portal", "https://tunnel.teamthurber.com/", "HEAD", "thurber_ai"),
    ("knowledge-base (Fly)", "https://thurber-kb.fly.dev/healthz", "GET", "kb"),
    ("omp auth-gateway", "http://127.0.0.1:4000/", "HEAD", None),
    ("search dev (wrangler) · optional", "http://127.0.0.1:8799/", "HEAD", None),
]
OPTIONAL = {"search dev (wrangler) · optional"}  # a dev server being down is normal, never "hot"


# ── tiny TTL cache: each source is fetched at most once per window ─────────────
class Cached:
    def __init__(self, ttl: float, fn):
        self.ttl, self.fn, self.at, self.val, self.lock = ttl, fn, 0.0, None, threading.Lock()

    def get(self):
        with self.lock:
            if time.monotonic() - self.at > self.ttl:
                try:
                    self.val = self.fn()
                except Exception as e:  # a dead source is a card that says so, never a dead hub
                    self.val = {"error": f"{type(e).__name__}: {e}"}
                self.at = time.monotonic()
            return self.val


# ── herdr registry ─────────────────────────────────────────────────────────────
def herdr_data(event_limit: int = 100) -> dict:
    if not REGISTRY.exists():
        return {"error": f"registry not found: {REGISTRY}", "tasks": [], "attention": [], "events": [], "checkpoints": []}
    conn = sqlite3.connect(f"file:{REGISTRY}?mode=ro", uri=True, timeout=2)
    conn.row_factory = sqlite3.Row
    try:
        tasks = [dict(r) for r in conn.execute(
            "SELECT task_id, run_id, label, repo, state, pane_id, conductor_id, worktree, created_at, updated_at "
            "FROM tasks ORDER BY updated_at DESC")]
        events = []
        for r in conn.execute("SELECT sequence, type, task_id, occurred_at, payload FROM events "
                              "ORDER BY sequence DESC LIMIT ?", (event_limit,)):
            e = dict(r)
            try:
                e["payload"] = json.loads(e["payload"] or "{}")
            except json.JSONDecodeError:
                e["payload"] = {"_raw": e["payload"]}
            events.append(e)
        checkpoints = [dict(r) for r in conn.execute(
            "SELECT conductor_id, last_event_seq, updated_at FROM checkpoints ORDER BY updated_at DESC LIMIT 12")]
        max_seq = conn.execute("SELECT COALESCE(MAX(sequence),0) FROM events").fetchone()[0]
    finally:
        conn.close()
    labels = {t["task_id"]: t["label"] or t["task_id"] for t in tasks}
    for e in events:
        e["label"] = labels.get(e["task_id"], e["task_id"])
    attention = sorted((t for t in tasks if t["state"] in ATTENTION),
                       key=lambda t: (ATTENTION.index(t["state"]), t["updated_at"]))
    return {"tasks": tasks, "attention": attention, "events": events,
            "checkpoints": checkpoints, "max_event_seq": max_seq}


# ── formserve registry ─────────────────────────────────────────────────────────
def port_open(port: int, host: str = "127.0.0.1", timeout: float = 0.3) -> bool:
    with socket.socket() as s:
        s.settimeout(timeout)
        return s.connect_ex((host, port)) == 0


def forms_data() -> dict:
    forms = []
    if FORMS_DIR.is_dir():
        for p in sorted(FORMS_DIR.glob("*.json"), reverse=True):
            try:
                f = json.loads(p.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if f.get("status") == "open" and not port_open(int(f.get("port", 0) or 0)):
                f["status"] = "gone"  # the server died without recording an outcome (killed, crashed)
            forms.append(f)
    open_forms = [f for f in forms if f["status"] == "open"]
    return {"open": open_forms, "history": [f for f in forms if f["status"] != "open"][:30],
            "open_count": len(open_forms)}


# ── secrets: pre-resolved, never `op` from a background process ───────────────
# ~/.config/op/service-account.env documents the rule: `op` probes TCC on every
# invocation from a launchd/background session and raises a system prompt
# nobody is there to answer (1Password/shell-plugins#606), so long-running
# jobs read PRE-RESOLVED values from that file instead — the same escape
# hatch lib/engineering-ledger.sh uses. Refresh a line from an interactive
# shell when a secret rotates.
def secret(name: str) -> str | None:
    v = os.environ.get(name)
    if v:
        return v
    if not OP_ENV.exists():
        return None
    for line in OP_ENV.read_text().splitlines():
        line = line.strip()
        if line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.removeprefix("export ").partition("=")
        if key.strip() == name:
            return val.strip().strip("'\"") or None
    return None


# ── consensus-search memory ────────────────────────────────────────────────────
def search_data() -> dict:
    token = secret("SEARCH_SYNC_TOKEN")
    if not token:
        return {"error": f"SEARCH_SYNC_TOKEN not set and not in {OP_ENV} — resolve it there from an interactive shell", "rows": []}
    rows, since = [], 0
    for _ in range(50):  # 50 × 500 rows is far beyond today's table; a hard stop, not a limit
        req = urllib.request.Request(
            f"{SEARCH_URL}/log?since={since}&limit=500",
            headers={"authorization": f"Bearer {token}", "user-agent": "herdr-hub/1 (+tnt@teamthurber.com)"})
        with urllib.request.urlopen(req, timeout=20) as r:
            page = json.load(r)
        rows.extend(page.get("rows", []))
        if page.get("next") is None:
            break
        since = page["next"]
    totals = {"searches": len(rows), "replays": sum(int(r.get("hit_count") or 0) for r in rows),
              "data_kind": sum(1 for r in rows if r.get("kind") == "data"),
              "partial": sum(1 for r in rows if r.get("status") != "ok")}
    latest = sorted(rows, key=lambda r: r["ts"], reverse=True)[:15]
    recent = []
    for r in latest:
        try:
            t = json.loads(r.get("timings_json") or "{}")
        except json.JSONDecodeError:
            t = {}
        recent.append({"id": r["id"], "ts": r["ts"], "q": r["q"], "kind": r.get("kind"), "scope": r.get("scope"),
                       "hits": r.get("hit_count") or 0, "total_s": round((t.get("total") or 0) / 1000, 1),
                       "url": f"{SEARCH_URL}/?q={urllib.parse.quote(r['q'])}"})
    return {"totals": totals, "recent": recent}


# ── knowledge-base: nightly ledger + fleet heartbeat, via KB's own venv ────────
_KB_SNIPPET = r"""
import json, sys, datetime
sys.path.insert(0, ".")
out = {}
try:
    from server import heartbeat
    out["heartbeat"] = heartbeat.latest_snapshot()
except Exception as e:
    out["heartbeat_error"] = f"{type(e).__name__}: {e}"
try:
    import psycopg, os
    with psycopg.connect(os.environ["NEON_CONNECTION_STRING"], options="-c default_transaction_read_only=on") as c:
        runs = c.execute("SELECT run_id, host, weekday, git_sha, status, started_at, finished_at, total_steps "
                         "FROM kb.nightly_runs ORDER BY started_at DESC LIMIT 5").fetchall()
        cols = ["run_id","host","weekday","git_sha","status","started_at","finished_at","total_steps"]
        out["runs"] = [dict(zip(cols, r)) for r in runs]
        if runs:
            steps = c.execute("SELECT step_label, status, attempts, duration_s, error_class, error_message "
                              "FROM kb.nightly_steps WHERE run_id=%s ORDER BY ctid", (runs[0][0],)).fetchall()
            out["steps"] = [dict(zip(["step_label","status","attempts","duration_s","error_class","error_message"], s)) for s in steps]
except Exception as e:
    out["ledger_error"] = f"{type(e).__name__}: {e}"
print(json.dumps(out, default=str))
"""


def kb_data() -> dict:
    if not (KB_DEPLOY / "server").is_dir() or not KB_PYTHON.exists():
        return {"error": f"kb-deploy checkout or venv missing ({KB_DEPLOY}, {KB_PYTHON})"}
    dsn = secret("NEON_CONNECTION_STRING")
    if not dsn:
        return {"error": f"NEON_CONNECTION_STRING not set and not in {OP_ENV}"}
    env = dict(os.environ, NEON_CONNECTION_STRING=dsn)
    try:
        r = subprocess.run([str(KB_PYTHON), "-c", _KB_SNIPPET], cwd=KB_DEPLOY, env=env,
                           capture_output=True, text=True, timeout=40)
    except subprocess.TimeoutExpired:
        return {"error": "kb reader timed out (40s)"}
    if r.returncode != 0:
        return {"error": f"kb reader exit {r.returncode}: {r.stderr.strip()[-300:]}"}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"error": f"kb reader printed non-JSON: {r.stdout[:200]}"}


# ── liveness ───────────────────────────────────────────────────────────────────
def probe(name: str, url: str, method: str, hb_key: str | None) -> dict:
    t0 = time.monotonic()
    try:
        req = urllib.request.Request(url, method=method, headers={"user-agent": "herdr-hub/1"})
        with urllib.request.urlopen(req, timeout=5) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code  # 401/403/302 from an auth wall is still "there"
    except (urllib.error.URLError, OSError, ValueError) as e:
        return {"name": name, "url": url, "alive": False, "code": None, "ms": None,
                "detail": str(getattr(e, "reason", e))[:80], "hb": hb_key}
    return {"name": name, "url": url, "alive": code < 500, "code": code,
            "ms": int((time.monotonic() - t0) * 1000), "detail": "", "hb": hb_key}


def links_data() -> dict:
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(lambda s: probe(*s), SURFACES))
    forms = forms_data()
    for f in forms["open"]:
        results.append({"name": f"decision: {f.get('title') or f['id']}", "url": f["url"], "alive": True,
                        "code": 200, "ms": None, "detail": "open form", "hb": None})
    return {"surfaces": results}


CACHES = {
    "herdr": Cached(5, herdr_data),
    "forms": Cached(3, forms_data),
    "search": Cached(120, search_data),
    "kb": Cached(300, kb_data),
    "links": Cached(60, links_data),
}


# ── rendering ──────────────────────────────────────────────────────────────────
def _esc(v) -> str:
    return html.escape(str(v if v is not None else ""))


def _age(iso) -> str:
    if not iso:
        return "—"
    if isinstance(iso, (int, float)):
        then = dt.datetime.fromtimestamp(iso / 1000, tz=dt.timezone.utc)
    else:
        try:
            then = dt.datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        except ValueError:
            return str(iso)
        if then.tzinfo is None:
            then = then.replace(tzinfo=dt.timezone.utc)
    s = int((dt.datetime.now(dt.timezone.utc) - then).total_seconds())
    if s < 0:
        return f"in {-s // 60}m"
    for lim, div, suf in ((90, 1, "s"), (5400, 60, "m"), (172800, 3600, "h")):
        if s < lim:
            return f"{s // div}{suf}"
    return f"{s // 86400}d"


STYLE = """
 body{margin:0;background:#0f1115;color:#e6e9ef;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
 header{display:flex;gap:18px;align-items:center;padding:14px 20px;border-bottom:1px solid #272c37;background:#171a21}
 header b{font-size:16px} header a{color:#9aa3b2;text-decoration:none} header a.on{color:#e6e9ef;border-bottom:2px solid #e08a4a}
 main{max-width:1150px;margin:0 auto;padding:16px 20px 60px}
 h2{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#9aa3b2;margin:22px 0 8px}
 table{width:100%;border-collapse:collapse;background:#171a21;border:1px solid #272c37;border-radius:10px;overflow:hidden}
 td{padding:8px 10px;border-top:1px solid #272c37;vertical-align:top} tr:first-child td{border-top:0}
 .pill{font-size:11px;padding:1px 8px;border-radius:999px;border:1px solid #272c37;color:#9aa3b2;white-space:nowrap}
 .hot .pill,.pill.hot{color:#1a1206;background:#e08a4a;border-color:#e08a4a} .pill.ok{color:#6fd39a;border-color:#6fd39a}
 .pill.bad{color:#ff7a7a;border-color:#ff7a7a} .pill.run{color:#6aa6ff;border-color:#6aa6ff}
 .age{color:#9aa3b2;white-space:nowrap;text-align:right} .dim{color:#9aa3b2} small{color:#9aa3b2} a{color:#6aa6ff}
 .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px}
 .card{background:#171a21;border:1px solid #272c37;border-radius:12px;padding:14px 16px;text-decoration:none;color:inherit;display:block}
 .card .n{font-size:28px;font-weight:700;line-height:1.1} .card .t{color:#9aa3b2;font-size:12px;text-transform:uppercase;letter-spacing:.08em}
 .card.hot{border-color:#e08a4a} .card .s{font-size:12px;color:#9aa3b2;margin-top:6px}
 iframe{width:100%;height:720px;border:1px solid #272c37;border-radius:12px;background:#fff}
 pre{background:#0c0e13;border:1px solid #272c37;border-radius:8px;padding:10px;overflow:auto;font-size:12px}
 .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;background:#ff7a7a} .dot.ok{background:#6fd39a}
"""
NAV = [("/", "overview"), ("/decisions", "decisions"), ("/herdr", "herdr"), ("/search", "search"), ("/kb", "kb"), ("/links", "links")]


def page(title: str, path: str, body: str, refresh: int = 15) -> str:
    nav = " ".join(f"<a href='{p}' class='{'on' if p == path else ''}'>{n}</a>" for p, n in NAV)
    return (f"<!doctype html><html lang=en><head><meta charset=utf-8><meta http-equiv=refresh content={refresh}>"
            f"<title>{_esc(title)}</title><style>{STYLE}</style></head><body>"
            f"<header><b>hub</b>{nav}<span class=dim style='margin-left:auto'>refresh {refresh}s · "
            f"<a href='{path}?json=1'>json</a></span></header><main>{body}</main></body></html>")


def task_rows(rows) -> str:
    out = []
    for t in rows:
        repo = (t["repo"] or "").rsplit("/", 1)[-1]
        cls = "hot" if t["state"] in ("input_required", "blocked") else ("run" if t["state"] == "running" else "")
        out.append(f"<tr class='{cls}'><td><span class='pill {cls}'>{_esc(t['state'])}</span></td>"
                   f"<td><b>{_esc(t['label'])}</b><br><small>{_esc(repo)} · pane {_esc(t['pane_id'] or '—')} · "
                   f"{_esc(t['conductor_id'] or 'no conductor')}</small></td>"
                   f"<td class=age title='{_esc(t['updated_at'])}'>{_age(t['updated_at'])}</td></tr>")
    return "".join(out) or "<tr><td class=dim>none</td></tr>"


def render_overview() -> str:
    h, f, s, k, l = (CACHES[n].get() for n in ("herdr", "forms", "search", "kb", "links"))
    att = len(h.get("attention", []))
    hb = (k or {}).get("heartbeat") or {}
    runs = (k or {}).get("runs") or []
    last = runs[0] if runs else {}
    required = [x for x in l.get("surfaces", []) if x["name"] not in OPTIONAL]
    alive = sum(1 for x in required if x["alive"])
    cards = [
        ("/herdr", att, "need attention", f"{len(h.get('tasks', []))} tasks · events to #{h.get('max_event_seq', 0)}", att > 0),
        ("/decisions", f.get("open_count", 0), "decisions open", f"{len(f.get('history', []))} answered/expired on record", f.get("open_count", 0) > 0),
        ("/links", f"{alive}/{len(required)}", "surfaces alive", "probed from this Mac; dev servers not counted", alive < len(required)),
        ("/kb", _esc(last.get("status", "—")), "last KB nightly", f"{_age(last.get('started_at'))} ago · {last.get('total_steps') or '?'} steps" if last else (k.get("error") or "no runs"), last.get("status") == "failed"),
        ("/kb", f"{hb.get('healthy_count', '—')}/{hb.get('total_count', '—')}", "fleet healthy (KB heartbeat)", f"snapshot {_age(hb.get('generated_at'))} ago" if hb else "no snapshot", bool(hb.get("divergent"))),
        ("/search", (s.get("totals") or {}).get("searches", "—"), "searches remembered", f"{(s.get('totals') or {}).get('replays', 0)} served from memory" if s.get("totals") else (s.get("error") or ""), False),
    ]
    body = "<div class=cards>" + "".join(
        f"<a class='card {'hot' if hot else ''}' href='{href}'><div class=t>{t}</div><div class=n>{n}</div><div class=s>{_esc(sub)}</div></a>"
        for href, n, t, sub, hot in cards) + "</div>"
    body += "<h2>Needs attention</h2><table>" + task_rows(h.get("attention", [])) + "</table>"
    if f.get("open"):
        body += "<h2>Open decisions</h2><table>" + "".join(
            f"<tr class=hot><td><span class='pill hot'>open</span></td><td><a href='/decisions'>{_esc(x.get('title') or x['id'])}</a>"
            f"<br><small>{_esc(x['url'])}</small></td><td class=age>{_age(x.get('created_at'))}</td></tr>" for x in f["open"]) + "</table>"
    return page("hub", "/", body)


def render_herdr() -> str:
    d = CACHES["herdr"].get()
    if d.get("error"):
        return page("herdr", "/herdr", f"<pre>{_esc(d['error'])}</pre>")
    ev = []
    for e in d["events"]:
        p = e["payload"]
        detail = " ".join(str(p[k]) for k in ("reason", "outcome", "detail") if p.get(k))
        if p.get("prompt_id"):
            detail += f" prompt={p['prompt_id'][:12]}…"
        ev.append(f"<tr><td class=dim>#{e['sequence']}</td><td><span class=pill>{_esc(e['type'])}</span></td>"
                  f"<td>{_esc(e['label'])}</td><td class=dim>{_esc(detail)}</td><td class=age title='{_esc(e['occurred_at'])}'>{_age(e['occurred_at'])}</td></tr>")
    cp = "".join(f"<tr><td>{_esc(c['conductor_id'])}</td><td>{c['last_event_seq']} / {d['max_event_seq']}"
                 f"{' <span class=pill>behind</span>' if c['last_event_seq'] < d['max_event_seq'] else ''}</td>"
                 f"<td class=age>{_age(c['updated_at'])}</td></tr>" for c in d["checkpoints"])
    others = [t for t in d["tasks"] if t["state"] not in ATTENTION][:40]
    body = (f"<h2>Needs attention ({len(d['attention'])})</h2><table>{task_rows(d['attention'])}</table>"
            f"<h2>Recent events (newest first)</h2><table>{''.join(ev) or '<tr><td class=dim>none</td></tr>'}</table>"
            f"<h2>Conductor cursors</h2><table>{cp or '<tr><td class=dim>none</td></tr>'}</table>"
            f"<h2>Other tasks (latest 40)</h2><table>{task_rows(others)}</table>")
    return page("herdr", "/herdr", body)


def render_decisions() -> str:
    d = CACHES["forms"].get()
    body = f"<h2>Open ({d['open_count']})</h2>"
    if not d["open"]:
        body += "<p class=dim>Nothing waiting on you. Forms appear here the moment an agent serves one.</p>"
    for f in d["open"]:
        body += (f"<p><b>{_esc(f.get('title') or f['id'])}</b> <span class=dim>· served {_age(f.get('created_at'))} ago · "
                 f"expires {_age(f.get('expires_at'))} · <a href='{_esc(f['url'])}' target=_blank>open in its own tab</a></span></p>"
                 f"<iframe src='{_esc(f['url'])}' title='{_esc(f.get('title') or f['id'])}'></iframe>")
    rows = "".join(
        f"<tr><td><span class='pill {'ok' if f['status'] == 'answered' else 'bad'}'>{_esc(f['status'])}</span></td>"
        f"<td><b>{_esc(f.get('title') or f['id'])}</b><br><small>{_esc(f.get('form_path', ''))}</small>"
        + (f"<pre>{_esc(json.dumps(f.get('answers'), indent=1, sort_keys=True))}</pre>" if f.get("answers") else "")
        + f"</td><td class=age>{_age(f.get('answered_at') or f.get('created_at'))}</td></tr>" for f in d["history"])
    body += f"<h2>History</h2><table>{rows or '<tr><td class=dim>none yet</td></tr>'}</table>"
    return page(f"decisions · {d['open_count']} open", "/decisions", body, refresh=10)


def render_search() -> str:
    d = CACHES["search"].get()
    if d.get("error"):
        return page("search", "/search", f"<pre>{_esc(d['error'])}</pre>", refresh=60)
    t = d["totals"]
    body = ("<form action='" + SEARCH_URL + "/' method=get target=_blank style='margin:0 0 14px'>"
            "<input name=q placeholder='Ask consensus·search…' style='width:70%;padding:10px 14px;border-radius:10px;border:1px solid #272c37;background:#171a21;color:#e6e9ef;font-size:15px'>"
            " <button style='padding:10px 18px;border-radius:10px;border:1px solid #e08a4a;background:#e08a4a;font-weight:600'>Search</button></form>"
            "<div class=cards>" + "".join(
                f"<div class=card><div class=t>{k}</div><div class=n>{v}</div></div>"
                for k, v in (("searches", t["searches"]), ("served from memory", t["replays"]), ("data-kind", t["data_kind"]), ("partial (a leg errored)", t["partial"]))) + "</div>")
    rows = "".join(f"<tr><td><a href='{_esc(r['url'])}' target=_blank>{_esc(r['q'])}</a><br><small>{_esc(r['scope'] or '')}</small></td>"
                   f"<td><span class=pill>{_esc(r['kind'] or '?')}</span></td><td class=dim>{r['hits']}× · {r['total_s']}s</td>"
                   f"<td class=age>{_age(r['ts'])}</td></tr>" for r in d["recent"])
    body += f"<h2>Latest searches</h2><table>{rows or '<tr><td class=dim>none</td></tr>'}</table>"
    return page("search memory", "/search", body, refresh=120)


def render_kb() -> str:
    d = CACHES["kb"].get()
    if d.get("error"):
        return page("kb", "/kb", f"<pre>{_esc(d['error'])}</pre>", refresh=120)
    body = ""
    hb = d.get("heartbeat") or {}
    if hb:
        systems = (hb.get("payload") or {}).get("systems") or (hb.get("payload") or {})
        rows = "".join(
            f"<tr><td><span class='pill {'ok' if v.get('status') == 'healthy' else 'bad'}'>{_esc(v.get('status'))}</span></td>"
            f"<td><b>{_esc(k)}</b><br><small>{_esc(v.get('detail', ''))}</small></td></tr>"
            for k, v in systems.items() if isinstance(v, dict))
        body += (f"<h2>Fleet heartbeat — {hb.get('healthy_count')}/{hb.get('total_count')} healthy, snapshot {_age(hb.get('generated_at'))} ago"
                 f"{' · DIVERGENT' if hb.get('divergent') else ''}</h2><table>{rows}</table>")
    elif d.get("heartbeat_error"):
        body += f"<h2>Fleet heartbeat</h2><pre>{_esc(d['heartbeat_error'])}</pre>"
    runs = d.get("runs") or []
    if runs:
        rows = "".join(f"<tr><td><span class='pill {'ok' if r['status'] in ('ok', 'success', 'completed') else 'bad'}'>{_esc(r['status'])}</span></td>"
                       f"<td>{_esc(r['weekday'])} · {_esc(r['host'])} · <small>{_esc((r.get('git_sha') or '')[:7])}</small></td>"
                       f"<td class=dim>{r.get('total_steps') or '?'} steps</td><td class=age title='{_esc(r['started_at'])}'>{_age(r['started_at'])}</td></tr>" for r in runs)
        body += f"<h2>Nightly runs</h2><table>{rows}</table>"
        steps = "".join(f"<tr><td><span class='pill {'ok' if s['status'] in ('ok', 'success') else ('bad' if s['status'] in ('failed', 'error') else '')}'>{_esc(s['status'])}</span></td>"
                        f"<td>{_esc(s['step_label'])}<br><small>{_esc((s.get('error_message') or s.get('error_class') or '')[:160])}</small></td><td class=dim>×{s.get('attempts') or 1} · {s.get('duration_s') or 0}s</td></tr>"
                        for s in d.get("steps") or [])
        body += f"<h2>Steps of the latest run</h2><table>{steps or '<tr><td class=dim>none</td></tr>'}</table>"
    elif d.get("ledger_error"):
        body += f"<h2>Nightly ledger</h2><pre>{_esc(d['ledger_error'])}</pre>"
    return page("knowledge-base", "/kb", body or "<p class=dim>nothing to show</p>", refresh=300)


def render_links() -> str:
    d = CACHES["links"].get()
    hb = ((CACHES["kb"].get() or {}).get("heartbeat") or {}).get("payload") or {}
    systems = hb.get("systems") or hb
    rows = ""
    for s in d.get("surfaces", []):
        verdict = systems.get(s["hb"]) if s["hb"] and isinstance(systems, dict) else None
        v = f"<span class='pill {'ok' if verdict.get('status') == 'healthy' else 'bad'}'>KB heartbeat: {_esc(verdict.get('status'))}</span>" if isinstance(verdict, dict) else ""
        rows += (f"<tr><td><span class='dot {'ok' if s['alive'] else ''}'></span>{_esc(s['name'])}</td>"
                 f"<td><a href='{_esc(s['url'])}' target=_blank>{_esc(s['url'])}</a></td>"
                 f"<td class=dim>{s['code'] or ''} {str(s['ms']) + 'ms' if s['ms'] is not None else ''} {_esc(s['detail'])}</td><td>{v}</td></tr>")
    return page("links", "/links", f"<h2>Surfaces</h2><table>{rows}</table>", refresh=60)


# ── HTTP ───────────────────────────────────────────────────────────────────────
PAGES = {"/": (render_overview, None), "/herdr": (render_herdr, "herdr"), "/decisions": (render_decisions, "forms"),
         "/search": (render_search, "search"), "/kb": (render_kb, "kb"), "/links": (render_links, "links")}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/healthz":
            return self._send(200, "text/plain", b"ok")
        if path == "/api/summary":
            h, f = CACHES["herdr"].get(), CACHES["forms"].get()
            return self._send(200, "application/json", json.dumps(
                {"attention": len(h.get("attention", [])), "open_decisions": f.get("open_count", 0)}).encode())
        if path not in PAGES:
            return self._send(404, "text/plain", b"not found")
        render, source = PAGES[path]
        if "json=1" in query:
            data = {n: CACHES[n].get() for n in CACHES} if source is None else CACHES[source].get()
            return self._send(200, "application/json", json.dumps(data, default=str).encode())
        try:
            return self._send(200, "text/html; charset=utf-8", render().encode())
        except Exception as e:  # a render bug shows on the page, never takes the hub down
            return self._send(500, "text/plain", f"{type(e).__name__}: {e}".encode())

    def _send(self, code: int, ctype: str, body: bytes):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = ap.parse_args()
    if port_open(args.port):
        print(f"hub: already serving on http://127.0.0.1:{args.port}/", file=sys.stderr)
        return 0
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"hub: http://127.0.0.1:{args.port}/", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
