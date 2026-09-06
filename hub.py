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
import ast
import concurrent.futures as cf
import datetime as dt
import html
import json
import os
import re
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
    ("vintageskins.com (BigCommerce)", "https://vintageskins.com/", "HEAD", None),
    ("vintageskins labels (Worker)", "https://vintageskins-labels.tnt-pgh.workers.dev/", "HEAD", None),
    ("vintageskins welcome webhook (Worker)", "https://vintageskins-welcome.tnt-pgh.workers.dev/", "HEAD", None),
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


# ── loops: every scheduled thing that is supposed to keep running ──────────────
# One row per loop: what it is, when it last ran, whether that is fresh for its
# cadence, and its last outcome — read from each loop's OWN artifact, never
# re-derived. `stale_after_s` is the cadence plus slack (a daily loop is late
# at 26h, not 24h01). "Suggestions" are the Stage-2 diagnose pass's own
# Stage-3-eligible / auto-remediate findings plus derived nudges from the
# freshness/outcome rules — proposal-only, exactly as the charter says.
THURBER_OS = Path(os.environ.get("THURBER_OS", Path.home() / "Code/thurber-os"))
# The Stage-1 ledger is per-MACHINE state written by the launchd job, which
# runs the live checkout — so read it from there even when this hub runs from
# a worktree. ENGINEERING_LEDGER_DIR is the same override the collector honors.
HERDR_CONTROL = Path(os.environ.get("HERDR_CONTROL_DIR", Path.home() / "Code/herdr-control"))
SENTINEL_HEARTBEAT = Path.home() / "Library/Application Support/thurber-os/local-sentinel/heartbeat.json"
LEDGER_DIR = Path(os.environ.get("ENGINEERING_LEDGER_DIR", HERDR_CONTROL / ".local-state/engineering-ledger"))
TRACKING_DIR = THURBER_OS / "docs/tracking"
GATE_REGISTRY = THURBER_OS / "docs/gate-registry.yaml"


def _parse_ts(v) -> float | None:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return v / 1000 if v > 1e11 else float(v)
    try:
        d = dt.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.timestamp()


def _loop(name, cadence, last, stale_after_s, outcome, detail, link=None) -> dict:
    ts = _parse_ts(last)
    age = (time.time() - ts) if ts else None
    stale = age is None or age > stale_after_s
    return {"name": name, "cadence": cadence, "last": last, "age_s": age, "stale": stale,
            "outcome": outcome, "detail": detail, "link": link}


def _loop_sentinel() -> dict:
    if not SENTINEL_HEARTBEAT.exists():
        return _loop("local sentinel", "every 5 min", None, 900, "missing", f"no heartbeat at {SENTINEL_HEARTBEAT}")
    try:
        raw = json.loads(SENTINEL_HEARTBEAT.read_text())
        v = raw.get("verdict")
        if isinstance(v, str):  # older writes stored a Python repr, not JSON
            v = ast.literal_eval(v)
    except (OSError, ValueError, SyntaxError) as e:
        return _loop("local sentinel", "every 5 min", None, 900, "unreadable", str(e)[:120])
    failed = v.get("failed_signals") or []
    return _loop("local sentinel", "every 5 min", v.get("checked_at"), 900, v.get("status") or "?",
                 f"failed signals: {', '.join(failed)}" if failed else "all signals healthy")


def _loop_stage1() -> dict:
    files = sorted(LEDGER_DIR.glob("*.jsonl")) if LEDGER_DIR.is_dir() else []
    if not files:
        return _loop("eloop stage 1 — engineering ledger collector", "hourly", None, 3 * 3600, "missing",
                     f"no ledger files in {LEDGER_DIR}")
    rows = []
    for line in files[-1].read_text().splitlines()[-40:]:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    last = max((r.get("observed_at") or "" for r in rows), default=None) or None
    latest_poll = [r for r in rows if r.get("observed_at") == last]
    bad = [f"{r.get('source')}:{r.get('source_id')}" for r in latest_poll if r.get("status") not in ("ok", "success", None)]
    return _loop("eloop stage 1 — engineering ledger collector", "hourly", last, 3 * 3600,
                 "degraded" if bad else "ok",
                 f"{len(latest_poll)} source rows in the last poll" + (f"; not ok: {', '.join(bad)}" if bad else ""))


_FINDING_RE = re.compile(r"^## (F\d+) — (.+)$", re.M)


def _loop_stage2() -> tuple[dict, list[dict]]:
    docs = sorted(TRACKING_DIR.glob("*-stage2-diagnose-pass.md")) if TRACKING_DIR.is_dir() else []
    if not docs:
        return _loop("eloop stage 2 — diagnose pass", "Fridays 09:00", None, 8 * 86400, "missing", "no pass docs"), []
    doc = docs[-1]
    text = doc.read_text()
    when = doc.name[:10]
    findings = []
    for m in _FINDING_RE.finditer(text):
        block = text[m.end(): text.find("\n## ", m.end()) if text.find("\n## ", m.end()) > 0 else len(text)]
        title = m.group(2)
        tags = []
        if "Stage-3-eligible" in title or "Stage-3-eligible" in block[:600]:
            tags.append("stage-3-eligible")
        if "auto-remediate" in title.lower() or "**Classification: auto-remediate**" in block:
            tags.append("auto-remediate")
        if "CARRY-OVER" in title:
            tags.append("carry-over")
        if "RESOLVED" in title:
            tags.append("resolved")
        findings.append({"id": m.group(1), "title": title, "tags": tags, "doc": doc.name})
    open_findings = [f for f in findings if "resolved" not in f["tags"]]
    return _loop("eloop stage 2 — diagnose pass", "Fridays 09:00", f"{when}T09:00:00+00:00", 8 * 86400,
                 "ok", f"{len(findings)} findings, {len(open_findings)} open, in {doc.name}",
                 link=f"file://{doc}"), findings


def _loop_gates() -> list[dict]:
    if not GATE_REGISTRY.exists():
        return []
    out, cur = [], None
    for line in GATE_REGISTRY.read_text().splitlines():
        s = line.strip()
        if s.startswith("- id: "):
            cur = {"id": s[6:].strip(), "status": "?", "title": ""}
            if cur["id"].startswith(("G-ELOOP", "G-OLOOP")):
                out.append(cur)
            else:
                cur = None
        elif cur is not None:
            if s.startswith("status:"):
                cur["status"] = s.split(":", 1)[1].strip()
            elif s.startswith("title:"):
                cur["title"] = s.split(":", 1)[1].strip()
    return out


def loops_data() -> dict:
    kb = CACHES["kb"].get() or {}
    runs = kb.get("runs") or []
    last_run = runs[0] if runs else {}
    loops = [
        _loop("KB nightly", "daily 08:00", last_run.get("started_at"), 26 * 3600,
              last_run.get("status") or "missing",
              f"{last_run.get('total_steps') or '?'} steps · {last_run.get('host') or ''}" if last_run else (kb.get("error") or kb.get("ledger_error") or "no runs"),
              link="/kb"),
    ]
    hb = kb.get("heartbeat") or {}
    loops.append(_loop("fleet heartbeat [9h]", "daily (inside KB nightly)", hb.get("generated_at"), 26 * 3600,
                       "divergent" if hb.get("divergent") else ("ok" if hb else "missing"),
                       f"{hb.get('healthy_count')}/{hb.get('total_count')} healthy" if hb else "no snapshot yet", link="/kb"))
    loops.append(_loop_sentinel())
    loops.append(_loop_stage1())
    s2, findings = _loop_stage2()
    loops.append(s2)

    suggestions = []
    for lp in loops:
        if lp["stale"]:
            suggestions.append({"key": f"stale:{_slug(lp['name'])}", "kind": "stale", "text": f"{lp['name']} has not run in {_age(lp['last']) if lp['last'] else 'ever'} (cadence {lp['cadence']}) — check its launchd job / log.", "link": lp.get("link")})
        elif lp["outcome"] not in ("ok", "success", "healthy"):
            suggestions.append({"key": f"outcome:{_slug(lp['name'])}", "kind": "outcome", "text": f"{lp['name']} last reported {lp['outcome']}: {lp['detail']}", "link": lp.get("link")})
    for f in findings:
        if "resolved" in f["tags"]:
            continue
        if "auto-remediate" in f["tags"] or "stage-3-eligible" in f["tags"]:
            suggestions.append({"key": f"finding:{f['id']}", "kind": "finding", "text": f"{f['id']}: {f['title']}", "tags": f["tags"], "link": f"file://{TRACKING_DIR / f['doc']}"})
    decisions = _loop_decisions()
    now_ms = int(time.time() * 1000)
    dismissed = 0
    for sg in suggestions:
        d = decisions.get(sg["key"])
        sg["decision"] = None
        if d and d["status"] == "open":
            sg["decision"] = {"state": "deciding", "url": d["url"]}
        elif d and d.get("until") and d["until"] > now_ms:
            sg["decision"] = {"state": "dismissed", "until": d["until"]}
            dismissed += 1
        elif d and d.get("decision") in ("accept", "hold"):
            sg["decision"] = {"state": d["decision"], "at": d["answered_at"], "notes": d.get("notes", "")}
    return {"loops": loops, "findings": findings, "suggestions": suggestions, "dismissed": dismissed,
            "gates": _loop_gates()}


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


# Terrence, 2026-09-05 ("Rung 1"): every suggestion gets a Decide button; the
# answer is a formserve form in the /decisions inbox; dismissals stop the nag.
# No auto-dispatch: "accept" means the CONDUCTOR dispatches (Stage 3 / G-ELOOP-E2
# is provisional). Decisions are derived from the forms registry itself - the
# form's answers carry `loops_key` - so there is no second state file to drift.
DISMISS_DAYS = {"dismiss_7": 7, "dismiss_30": 30}


def _sidecar_key(form_path) -> str | None:
    """An OPEN form has no answers yet; its suggestion key sits in a sidecar
    written next to the html when the form was served."""
    if not form_path:
        return None
    try:
        return Path(form_path).with_suffix(".key").read_text().strip() or None
    except OSError:
        return None


def _loop_decisions() -> dict:
    """key -> newest form outcome for that suggestion (open, or answered)."""
    out: dict = {}
    for path in sorted(FORMS_DIR.glob("*.json")):  # oldest first; newer overwrite
        try:
            f = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        key = (f.get("answers") or {}).get("loops_key") or _sidecar_key(f.get("form_path"))
        if not key:
            continue
        if f.get("status") == "open":
            out[key] = {"status": "open", "url": f.get("url")} if port_open(int(f.get("port", 0) or 0)) else out.get(key, {})
            continue
        if f.get("status") != "answered":
            continue
        a = f.get("answers") or {}
        days = DISMISS_DAYS.get(a.get("decision"))
        out[key] = {"status": "answered", "decision": a.get("decision"), "notes": a.get("notes", ""),
                    "answered_at": f.get("answered_at"),
                    "until": (f.get("answered_at") or 0) + days * 86400 * 1000 if days else None}
    return out


DECIDE_FORM = """<!doctype html><html lang=en><head><meta charset=utf-8><title>{title}</title>
<style>:root{{--ground:#0f1115;--surface:#171a21;--line:#272c37;--ink:#e6e9ef;--dim:#9aa3b2;--accent:#6aa6ff}}
body{{margin:0;background:var(--ground);color:var(--ink);font:15px/1.5 system-ui,sans-serif}} main{{max-width:720px;margin:0 auto;padding:32px 24px 110px}}
h1{{font-size:22px;margin:0 0 6px}} .sub{{color:var(--dim);margin:0 0 22px}} fieldset{{border:1px solid var(--line);border-radius:8px;background:var(--surface);padding:14px 16px;margin:0 0 16px}}
legend{{color:var(--dim);font-size:12px;letter-spacing:.08em;text-transform:uppercase;padding:0 6px}} .opt{{display:flex;gap:10px;padding:8px 6px;border-radius:6px;cursor:pointer}} .opt:hover{{background:#1d2129}}
.hint{{display:block;color:var(--dim);font-size:13px}} textarea{{width:100%;min-height:70px;background:var(--ground);color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:8px;font:inherit}}
.bar{{position:fixed;left:0;right:0;bottom:0;background:var(--surface);border-top:1px solid var(--line);padding:12px 24px;display:flex;gap:10px;justify-content:flex-end}}
button{{font:600 14px system-ui;padding:10px 18px;border-radius:6px;border:1px solid var(--accent);background:var(--accent);color:#0b1020;cursor:pointer}} .ghost{{background:transparent;color:var(--dim);border-color:var(--line)}}
pre{{white-space:pre-wrap;background:var(--ground);border:1px solid var(--line);border-radius:6px;padding:10px;color:var(--dim);font-size:13px}}</style></head><body><main>
<h1>{title}</h1><p class=sub>Suggestion from the hub's /loops page ({kind}). Nothing is dispatched by this form: "accept" hands it to the conductor to dispatch as a herdr worker.</p>
<pre>{text}</pre>
<form id=f><fieldset><legend>Decision</legend>
<label class=opt><input type=radio name=decision value=accept required checked><span><b>Accept</b><span class=hint>conductor dispatches it (worktree + PR, human merge) and reports back</span></span></label>
<label class=opt><input type=radio name=decision value=hold><span><b>Hold</b><span class=hint>keep it visible, no action yet</span></span></label>
<label class=opt><input type=radio name=decision value=dismiss_7><span><b>Dismiss for 7 days</b><span class=hint>hidden from /loops until then; comes back if still true</span></span></label>
<label class=opt><input type=radio name=decision value=dismiss_30><span><b>Dismiss for 30 days</b></span></label>
</fieldset><fieldset><legend>Notes</legend><textarea name=notes placeholder="constraints, who, why…"></textarea></fieldset></form></main>
<div class=bar><button type=button class=ghost id=cancel>Send nothing</button><button type=submit form=f>Send answer</button></div>
<script>document.getElementById("f").addEventListener("submit",function(e){{e.preventDefault();var fd=new FormData(e.target);
window.submitAnswers({{loops_key:{key_json},decision:fd.get("decision"),notes:(fd.get("notes")||"").trim()}})}});
document.getElementById("cancel").addEventListener("click",function(){{window.submitAnswers({{cancelled:true,loops_key:{key_json}}})}});</script></body></html>"""


def serve_loop_decision(key: str) -> str | None:
    """Write a decision form for one suggestion and hand it to formserve, which
    registers it in the inbox. Returns the registry-visible title, or None."""
    sg = next((x for x in (CACHES["loops"].get() or {}).get("suggestions", []) if x["key"] == key), None)
    if not sg:
        return None
    FORMS_DIR.mkdir(parents=True, exist_ok=True)
    title = f"loops: {sg['text'][:70]}{'…' if len(sg['text']) > 70 else ''}"
    form = FORMS_DIR / f"loops-{_slug(key)}-{time.strftime('%Y%m%dT%H%M%S', time.gmtime())}.html"
    form.write_text(DECIDE_FORM.format(title=_esc(title), kind=_esc(sg["kind"]), text=_esc(sg["text"]),
                                       key_json=json.dumps(key)))
    form.with_suffix(".key").write_text(key)
    subprocess.Popen([sys.executable, str(HERDR_CONTROL / "formserve.py"), str(form),
                      "--timeout", "14400", "--no-open"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    CACHES["loops"].at = 0.0  # re-read on next view so the row shows "deciding"
    CACHES["forms"].at = 0.0
    return title


CACHES = {
    "herdr": Cached(5, herdr_data),
    "forms": Cached(3, forms_data),
    "search": Cached(120, search_data),
    "kb": Cached(300, kb_data),
    "links": Cached(60, links_data),
    "loops": Cached(10, loops_data),
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
 button.decide{font:600 12px system-ui;padding:4px 10px;border-radius:5px;border:1px solid #6aa6ff;background:transparent;color:#6aa6ff;cursor:pointer} button.decide:hover{background:#6aa6ff;color:#0b1020}
 .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;background:#ff7a7a} .dot.ok{background:#6fd39a}
"""
NAV = [("/", "overview"), ("/decisions", "decisions"), ("/loops", "loops"), ("/herdr", "herdr"), ("/search", "search"), ("/kb", "kb"), ("/links", "links")]


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
    h, f, s, k, l, lo = (CACHES[n].get() for n in ("herdr", "forms", "search", "kb", "links", "loops"))
    bad_loops = [x for x in lo.get("loops", []) if x["stale"] or x["outcome"] not in ("ok", "success", "healthy")]
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
        ("/loops", f"{len(lo.get('loops', [])) - len(bad_loops)}/{len(lo.get('loops', []))}", "loops healthy", f"{len(lo.get('suggestions', []))} suggestion(s)" + (" · " + ", ".join(x["name"].split(" — ")[0] for x in bad_loops) if bad_loops else ""), bool(bad_loops)),
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
    lo = CACHES["loops"].get()
    strip = " ".join(
        f"<a class='card {'hot' if (x['stale'] or x['outcome'] not in ('ok', 'success', 'healthy')) else ''}' href='/loops' style='padding:10px 12px'>"
        f"<div class=t>{_esc(x['name'].split(' — ')[0])}</div><div style='font-weight:600'>{'STALE' if x['stale'] else _esc(x['outcome'])}</div>"
        f"<div class=s>{_age(x['last']) if x['last'] else 'never'} ago · {_esc(x['cadence'])}</div></a>" for x in lo.get("loops", []))
    sug = "".join(f"<li>{_esc(t['text'])}</li>" for t in lo.get("suggestions", [])[:5])
    body = (f"<h2>Loops <a href='/loops' class=dim style='font-weight:400'>· all, with suggestions →</a></h2><div class=cards>{strip}</div>"
            + (f"<h2>Suggestions</h2><ul class=dim style='margin:0 0 6px;padding-left:18px'>{sug}</ul>" if sug else "")
            + f"<h2>Needs attention ({len(d['attention'])})</h2><table>{task_rows(d['attention'])}</table>"
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
def _suggestion_row(s: dict) -> str:
    dec = s.get("decision") or {}
    st = dec.get("state")
    if st == "deciding":
        action = "<a class='pill run' href='/decisions'>deciding…</a>"
    elif st == "accept":
        action = f"<span class='pill ok' title='{_esc(dec.get('notes'))}'>accepted · awaiting conductor dispatch</span>"
    elif st == "hold":
        action = f"<span class='pill' title='{_esc(dec.get('notes'))}'>on hold</span>"
    else:
        action = (f"<form method=post action=/loops/decide style='margin:0'><input type=hidden name=key value='{_esc(s['key'])}'>"
                  f"<button class=decide>Decide</button></form>")
    tags = f" <small>{' · '.join(s.get('tags', []))}</small>" if s.get("tags") else ""
    return (f"<tr><td><span class='pill {'hot' if s['kind'] != 'finding' else ''}'>{_esc(s['kind'])}</span></td>"
            f"<td{' class=dim' if st == 'hold' else ''}>{_esc(s['text'])}{tags}</td><td class=age>{action}</td></tr>")


def render_loops() -> str:
    d = CACHES["loops"].get()
    rows = ""
    for lp in d["loops"]:
        cls = "bad" if lp["stale"] or lp["outcome"] not in ("ok", "success", "healthy") else "ok"
        name = f"<a href='{_esc(lp['link'])}'>{_esc(lp['name'])}</a>" if lp.get("link") and not str(lp["link"]).startswith("file://") else _esc(lp["name"])
        rows += (f"<tr><td><span class='pill {cls}'>{'STALE' if lp['stale'] else _esc(lp['outcome'])}</span></td>"
                 f"<td><b>{name}</b><br><small>{_esc(lp['cadence'])} · {_esc(lp['detail'])}</small></td>"
                 f"<td class=age title='{_esc(lp['last'])}'>{_age(lp['last']) if lp['last'] else 'never'}</td></tr>")
    sug = "".join(_suggestion_row(s) for s in d["suggestions"] if not (s.get("decision") or {}).get("state") == "dismissed")
    if d.get("dismissed"):
        sug += f"<tr><td></td><td class=dim>{d['dismissed']} dismissed (come back when their dismissal expires)</td><td></td></tr>"
    gates = "".join(f"<tr><td><span class=pill>{_esc(g['status'])}</span></td><td><b>{_esc(g['id'])}</b> <span class=dim>{_esc(g['title'])}</span></td></tr>" for g in d["gates"])
    findings = "".join(f"<tr><td class=dim>{_esc(f['id'])}</td><td>{_esc(f['title'])}</td><td><small>{' · '.join(f['tags'])}</small></td></tr>" for f in d["findings"])
    body = (f"<h2>Loops</h2><table>{rows}</table>"
            f"<h2>Suggestions ({len(d['suggestions'])}) — proposal-only</h2><table>{sug or '<tr><td class=dim>nothing to suggest</td></tr>'}</table>"
            f"<h2>Evolution-loop gates (docs/gate-registry.yaml — Terrence signs, nobody stamps)</h2><table>{gates or '<tr><td class=dim>none</td></tr>'}</table>"
            f"<h2>Latest Stage-2 findings</h2><table>{findings or '<tr><td class=dim>none</td></tr>'}</table>")
    return page("loops", "/loops", body, refresh=60)


PAGES = {"/": (render_overview, None), "/herdr": (render_herdr, "herdr"), "/decisions": (render_decisions, "forms"),
         "/loops": (render_loops, "loops"), "/search": (render_search, "search"), "/kb": (render_kb, "kb"),
         "/links": (render_links, "links")}


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

    def do_POST(self):
        path, _, _ = self.path.partition("?")
        if path != "/loops/decide":
            return self._send(404, "text/plain", b"not found")
        n = int(self.headers.get("content-length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        key = (form.get("key") or [""])[0]
        title = serve_loop_decision(key)
        if not title:
            return self._send(404, "text/plain", f"no such suggestion: {key}".encode())
        self.send_response(303)
        self.send_header("location", "/decisions")
        self.send_header("content-length", "0")
        self.end_headers()

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
