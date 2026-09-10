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
  /kb          knowledge-base: nightly ledger, heartbeat, repeat-view signal audits
  /links       every surface with a liveness dot
  /api/summary {attention, open_decisions} — what the omp extension's one-liner reads
  any page     ?json=1 → the page's data as JSON

Sources (all read-only): ~/.local/state/herdr/runs/registry.sqlite3 (herdr),
~/.local/state/herdr/forms/*.json (formserve registry), consensus-search
GET /log (bearer SEARCH_SYNC_TOKEN), knowledge-base's own venv + kb-deploy
checkout for kb.nightly_runs/steps, server.heartbeat.latest_snapshot(), and
server.signal_quality.recent_runs() (NEON_CONNECTION_STRING, read-only).
Secrets come from the environment or ~/.config/op/launchd-secrets.env
— never from an `op` subprocess or shell evaluation (see secret()). Loopback only,
no auth — same posture as formserve. Idempotent to start: a second copy sees
the port taken and exits 0.
"""
from __future__ import annotations

import argparse
import ast
import concurrent.futures as cf
import datetime as dt
import hmac
import html
import json
import math
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
from uuid import UUID
from pathlib import Path

# lib/ is beside this script, not on sys.path — hub.py runs from launchd with
# whatever cwd the plist gives it, so the path is derived from __file__.
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from record_store import NotClaimable, claim_and_update  # noqa: E402

DEFAULT_PORT = int(os.environ.get("HERDR_HUB_PORT", "8600"))
STATE = Path(os.environ.get("HERDR_STATE_ROOT", Path.home() / ".local/state/herdr"))
REGISTRY = Path(os.environ.get("HERDR_RUN_REGISTRY", STATE / "runs/registry.sqlite3"))
FORMS_DIR = STATE / "forms"
KB_DEPLOY = Path(os.environ.get("KB_DEPLOY", Path.home() / "Code/kb-deploy"))
KB_PYTHON = Path(os.environ.get("KB_PYTHON", Path.home() / "Code/knowledge-base/.venv/bin/python3"))
SEARCH_URL = os.environ.get("CONSENSUS_SEARCH_URL", "https://consensus.teamthurber.com")
LAUNCHD_SECRETS = Path(os.environ.get("HERDR_HUB_SECRETS_ENV", Path.home() / ".config/op/launchd-secrets.env"))
SECRET_NAMES = frozenset(("NEON_CONNECTION_STRING", "SEARCH_SYNC_TOKEN"))
KB_DASHBOARD_URL = os.environ.get("KB_DASHBOARD_URL", "https://dashboard.teamthurber.com")
ATTENTION = ("input_required", "blocked", "running")

# Every surface the team runs, hosted and local. `probe` is what "alive" means
# for it; hosted ones also get the KB heartbeat verdict when a snapshot exists.
SURFACES = [
    ("consensus·search", SEARCH_URL + "/", "GET", "search"),
    ("tourguide (apps)", "https://apps.teamthurber.com/health", "GET", "tourguide"),
    ("teamthurber.com", "https://teamthurber.com/", "HEAD", "tntpgh_actions"),
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
                except Exception:  # failed readers must not leak credentials through exception text
                    self.val = {"error": "source reader unavailable"}
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


def form_html(form_id: str) -> Path:
    """Where the hub keeps its own copy of a form's HTML.

    The copy is what makes a decision durable. formserve's own port dies the
    moment it collects an answer (and dies WITHOUT collecting one if its
    process is killed or the machine sleeps), which used to leave a form
    listed `open` at a URL that no longer answered — observed 2026-09-09 on
    the eBay Hunter `rev 1` form, marked `gone`, unanswerable. With the HTML
    here, the hub can serve and accept that same form itself, for as long as
    the registry row exists.
    """
    return FORMS_DIR / f"{form_id}.html"


def forms_data() -> dict:
    forms = []
    now_ms = int(time.time() * 1000)
    if FORMS_DIR.is_dir():
        for p in sorted(FORMS_DIR.glob("*.json"), reverse=True):
            try:
                f = json.loads(p.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            # formserve lifts the title out of the form's <h1> and strips tags but
            # not entities, so a title with "&" arrives as "&amp;" and _esc() then
            # double-escapes it into a visible "&amp;". Decode once, here, so every
            # consumer (page, iframe title, /api) gets the human string.
            if f.get("title"):
                f["title"] = html.unescape(f["title"])
            f["hub_servable"] = form_html(f["id"]).exists()
            if f["hub_servable"]:
                f["hub_url"] = f"/decisions/{f['id']}"
            if f.get("status") == "open":
                exp = f.get("expires_at")
                if exp and now_ms > int(exp):
                    # An expired form is still unanswered — never "declined".
                    f["status"] = "expired"
                elif not f["hub_servable"] and not port_open(int(f.get("port", 0) or 0)):
                    # Pre-hub form whose server died without recording an outcome.
                    # A hub-servable one is NEVER gone: this page can still answer it.
                    f["status"] = "gone"
            forms.append(f)
    open_forms = [f for f in forms if f["status"] == "open"]
    return {"open": open_forms, "history": [f for f in forms if f["status"] != "open"][:30],
            "open_count": len(open_forms)}


# ── answering a form from the hub itself ──────────────────────────────────────
# The hub serves the stored HTML with this shim appended, so a form authored for
# formserve needs no change: it still calls window.submitAnswers().
HUB_SUBMIT_SHIM = """
<input type="hidden" id="__formserve_token" value="%(token)s">
<script>
(function () {
  window.submitAnswers = function (answers) {
    var body = Object.assign({}, answers === undefined ? {} : answers);
    body.__formserve_token = document.getElementById("__formserve_token").value;
    return fetch("%(action)s", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then(function (r) {
      if (!r.ok) return r.text().then(function (t) { throw new Error(r.status + ": " + t); });
      document.querySelectorAll("button,input,select,textarea").forEach(function (el) { el.disabled = true; });
      var b = document.createElement("div");
      b.setAttribute("role", "status");
      b.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:99999;padding:14px 18px;" +
        "font:600 14px system-ui,sans-serif;text-align:center;background:#1f6e7e;color:#fff";
      b.textContent = "Answer recorded in the hub. The agent has been notified.";
      document.body.appendChild(b);
      return true;
    }).catch(function (e) {
      var b = document.createElement("div");
      b.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:99999;padding:14px 18px;" +
        "font:600 14px system-ui,sans-serif;text-align:center;background:#a83a2f;color:#fff";
      b.textContent = "Could not record answer: " + e.message;
      document.body.appendChild(b);
      throw e;
    });
  };
})();
</script>
"""


def _form_row(form_id: str) -> tuple[Path, dict] | tuple[None, None]:
    """Registry row for an id, or (None, None). The id is path-validated: it
    indexes a file under FORMS_DIR, so anything but the generated shape is
    refused rather than joined onto a path."""
    if not re.fullmatch(r"[0-9A-Za-z._-]{1,120}", form_id or ""):
        return None, None
    path = FORMS_DIR / f"{form_id}.json"
    try:
        return path, json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None, None


def serve_stored_form(form_id: str) -> tuple[int, bytes]:
    """The form's own HTML, plus the submit shim, at a URL that outlives its
    creating process. An already-answered form is shown read-only."""
    _, row = _form_row(form_id)
    if row is None:
        return 404, b"no such decision"
    body = form_html(form_id)
    if not body.exists():
        return 404, b"this decision predates hub-served forms; use its own port"
    try:
        raw = body.read_text()
    except OSError:
        return 500, b"decision body unreadable"
    if row.get("status") != "open":
        answers = json.dumps(row.get("answers") or {}, indent=1, sort_keys=True)
        banner = (f"<div style=\"position:sticky;top:0;z-index:99999;padding:12px 16px;"
                  f"background:#1f6e7e;color:#fff;font:600 14px system-ui\">"
                  f"{_esc(row['status'])}"
                  + (f" · answered {_age(row.get('answered_at'))} ago" if row.get("answered_at") else "")
                  + f"<pre style=\"margin:8px 0 0;font:12px ui-monospace;white-space:pre-wrap\">{_esc(answers)}</pre></div>")
        # Insert after <body> so the banner is inside the document, and neuter
        # the form: an answered decision must not look re-answerable.
        frozen = ("<script>document.addEventListener('DOMContentLoaded',function(){"
                  "document.querySelectorAll('button,input,select,textarea')"
                  ".forEach(function(el){el.disabled=true;});});</script>")
        m = re.search(r"<body[^>]*>", raw, re.I)
        out = (raw[:m.end()] + banner + raw[m.end():]) if m else banner + raw
        out = out.replace("</body>", frozen + "</body>") if "</body>" in out else out + frozen
        return 200, out.encode()
    shim = HUB_SUBMIT_SHIM % {"token": _esc(row.get("token") or ""),
                              "action": f"/decisions/{form_id}/submit"}
    out = raw.replace("</body>", shim + "</body>") if "</body>" in raw else raw + shim
    return 200, out.encode()


def record_answer(form_id: str, payload: dict) -> tuple[int, bytes]:
    """Write an answer into the registry, then notify the waiting agent.

    Same token posture as formserve: this endpoint is unauthenticated loopback,
    so any local process could otherwise POST a fabricated answer that then
    gets typed into a live agent pane. The token is generated per form and
    embedded only in the HTML the hub actually served.
    """
    path, row = _form_row(form_id)
    if row is None:
        return 404, b"no such decision"
    token = row.get("token") or ""
    submitted = payload.pop("__formserve_token", None)
    if not token or not isinstance(submitted, str) or not hmac.compare_digest(submitted, token):
        return 403, b"forbidden: missing or invalid token"
    # The status read above is already stale — formserve's own port may answer
    # between it and this line. claim_and_update re-reads under an exclusive
    # lock and writes via rename, so the loser genuinely loses (409) instead of
    # overwriting a recorded answer, and a crash can't leave a half-written
    # decision record. See lib/record_store.py.
    # Expiry is enforced HERE, under the lock, not only in the rendered list.
    # forms_data() flipped `expired` in the loaded dict for display, but this
    # path re-read the record and would accept an answer to a form whose
    # expires_at had passed hours earlier - the exact case the hub copy exists
    # for, since the original server is gone by then (two-model review,
    # 2026-09-09). Raising NotClaimable inside the callback rejects it under the
    # same lock that protects against the double-answer.
    def _answer(row: dict) -> dict:
        exp = row.get("expires_at")
        if isinstance(exp, (int, float)) and exp > 0 and time.time() * 1000 > exp:
            raise NotClaimable("expired", row)
        row.update(status="answered", answers=payload,
                   answered_at=int(time.time() * 1000), answered_via="hub")
        return row

    try:
        row = claim_and_update(path, _answer)
    except NotClaimable as e:
        if e.state == "expired" and e.row.get("status") == "open":
            return 410, b"expired: this decision passed its deadline and is still unanswered; re-serve it"
        return 409, f"already {e.state}".encode()
    except FileNotFoundError:
        return 404, b"no such decision"
    except json.JSONDecodeError as e:
        return 500, f"decision record is corrupt: {e}".encode()
    except OSError as e:
        return 500, f"could not record: {e}".encode()
    CACHES["forms"].at = 0.0
    notify_owner(row)
    return 200, b'{"ok":true}'


def notify_owner(row: dict) -> None:
    """Push the answer to the agent that asked, using the delivery leaf that
    already handles the two ways this strands (a reaped background task
    splitting type from Enter, and a large paste being collapsed).

    Honest limitation: omp's own agent inbox is in-process — there is no CLI to
    post into it — so "push" here means the herdr pane leaf, exactly as
    formserve --deliver does. An agent with no pane target still finds the
    answer in the registry and on this page; nothing is lost, it just has to look.
    """
    target = row.get("deliver_to")
    if not target:
        return
    leaf = HERDR_CONTROL / "herdr-deliver.sh"
    if not leaf.exists():
        leaf = HERDR_CONTROL / "send-to-agent.sh"
    if not leaf.exists():
        return
    text = ("Form answers from the hub (" + str(row.get("title") or row.get("id")) + "):\n"
            + json.dumps(row.get("answers") or {}, indent=2, sort_keys=True))
    try:
        subprocess.run(["bash", str(leaf), str(target), text], capture_output=True, text=True,
                       timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass  # the answer is recorded; delivery is best-effort by design


# ── secrets: pre-resolved, never `op` from a background process ───────────────
# Only the hub's two service credentials may be resolved. This is the existing
# literal assignment parser, not a shell: no expansion, sourcing, or op calls.
# The service-account file contains the broker token, not these service secrets.
def secret(name: str) -> str | None:
    if name not in SECRET_NAMES:
        raise ValueError("unsupported hub credential name")
    v = os.environ.get(name)
    if v:
        return v
    try:
        lines = LAUNCHD_SECRETS.read_text().splitlines()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError):
        raise ValueError("hub service credential file unavailable") from None
    for line in lines:
        line = line.strip()
        if line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.removeprefix("export ").partition("=")
        if key.strip() == name:
            val = val.strip()
            if val.startswith(("'", '"')):
                if len(val) < 2 or val[-1] != val[0]:
                    raise ValueError("invalid hub service credential assignment")
                val = val[1:-1]
            return val or None
    return None


# ── consensus-search memory ────────────────────────────────────────────────────
def search_data() -> dict:
    token = secret("SEARCH_SYNC_TOKEN")
    if not token:
        return {"error": "SEARCH_SYNC_TOKEN unavailable; check the hub environment or scoped launchd credential file", "rows": []}
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
    import psycopg, os
    with psycopg.connect(os.environ["NEON_CONNECTION_STRING"], options="-c default_transaction_read_only=on") as c:
        try:
            with c.transaction():
                row = c.execute("SELECT payload FROM kb.heartbeat_snapshots ORDER BY generated_at DESC LIMIT 1").fetchone()
                payload = row[0] if row else None
                out["heartbeat"] = json.loads(payload) if isinstance(payload, str) else payload
        except Exception:
            out["heartbeat_error"] = "heartbeat reader unavailable"
        try:
            with c.transaction():
                runs = c.execute("SELECT run_id, host, weekday, git_sha, status, started_at, finished_at, total_steps "
                                 "FROM kb.nightly_runs ORDER BY started_at DESC LIMIT 5").fetchall()
                cols = ["run_id","host","weekday","git_sha","status","started_at","finished_at","total_steps"]
                out["runs"] = [dict(zip(cols, r)) for r in runs]
                if runs:
                    steps = c.execute("SELECT step_label, status, attempts, duration_s, error_class "
                                      "FROM kb.nightly_steps WHERE run_id=%s ORDER BY ctid", (runs[0][0],)).fetchall()
                    out["steps"] = [dict(zip(["step_label","status","attempts","duration_s","error_class"], s)) for s in steps]
        except Exception:
            out.pop("runs", None)
            out.pop("steps", None)
            out["ledger_error"] = "nightly ledger reader unavailable"
        try:
            with c.transaction():
                from server.signal_quality import recent_runs
                out["signal_quality_runs"] = recent_runs(c, limit=10)
        except Exception:
            out["signal_quality_error"] = "signal quality reader unavailable; check KB module, migration, and database access"
except Exception:
    out["heartbeat_error"] = "heartbeat database unavailable"
    out["ledger_error"] = "nightly ledger database unavailable"
    out["signal_quality_error"] = "signal quality database unavailable"
print(json.dumps(out, default=str))
"""


SIGNAL_SUMMARY_FIELDS = (
    "window_days", "person_count", "before_count", "after_count", "changed_count",
    "repeat_before_count", "repeat_after_count", "withheld_stale_count",
    "withheld_unknown_date_count", "violation_count",
)


def _public_signal_runs(rows) -> list[dict]:
    """Allow only typed audit metadata and aggregate counters onto localhost."""
    if not isinstance(rows, list):
        raise ValueError("invalid signal quality response")
    result = []
    for row in rows[:10]:
        if not isinstance(row, dict) or row.get("status") not in ("running", "ok", "degraded", "failed"):
            raise ValueError("invalid signal quality run")
        if not isinstance(row.get("run_id"), str):
            raise ValueError("invalid audit run identifier")
        run_id = str(UUID(row["run_id"]))
        dates = {}
        for key in ("started_at", "finished_at"):
            value = row.get(key)
            if value is None and key == "finished_at":
                dates[key] = None
                continue
            if not isinstance(value, str):
                raise ValueError("invalid audit timestamp")
            date = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if date.tzinfo is None:
                raise ValueError("audit timestamp requires timezone")
            dates[key] = date.astimezone(dt.timezone.utc).isoformat()
        rule = row.get("rule_version")
        if not isinstance(rule, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:/-]{0,95}", rule):
            raise ValueError("invalid audit rule version")
        revision = row.get("source_revision")
        if revision is not None and (not isinstance(revision, str) or not re.fullmatch(r"[0-9a-fA-F]{7,64}", revision)):
            revision = None
        summary = row.get("summary")
        if not isinstance(summary, dict):
            raise ValueError("invalid audit summary")
        counts = {}
        for key in SIGNAL_SUMMARY_FIELDS:
            value = summary.get(key)
            # A running/failed audit can lack counters; never substitute fake zeros.
            if value is None and row["status"] in ("running", "failed"):
                continue
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError("invalid audit counter")
            counts[key] = value
        # Raw error strings (including SQL/PII) have no place on this surface.
        result.append({"run_id": run_id, **dates, "status": row["status"],
                       "rule_version": rule, "source_revision": revision, "summary": counts,
                       "error_code": "audit_failed" if row.get("error_code") else None})
    return result


def _signal_quality_link() -> str | None:
    """Configured human-auth page only; no credentials/query/fragment in links."""
    value = KB_DASHBOARD_URL
    try:
        url = urllib.parse.urlsplit(value)
        if (url.scheme not in ("https", "http") or not url.hostname or url.username or url.password
                or url.query or url.fragment or url.hostname not in ("dashboard.teamthurber.com", "localhost", "127.0.0.1")
                or (url.scheme == "http" and url.hostname == "dashboard.teamthurber.com")
                or url.path not in ("", "/")):
            return None
        url.port  # reject malformed ports
    except ValueError:
        return None
    return value.rstrip("/") + "/signal-quality"


# Heartbeat: the persisted snapshot carries raw checker exception text, subprocess
# stderr and whole non-OK HTTP response bodies in systems.*.detail (SQ-SEC-04),
# so this unauthenticated surface republishes NOTHING from the payload except the
# checker names KB itself defines, its fixed status vocabulary, and counts derived
# from those — no detail strings, no unknown keys, no producer-supplied numbers.
# Names are server.heartbeat._CHECKERS; a key KB does not define is counted, never
# echoed, because an arbitrary key may itself be secret-bearing.
HEARTBEAT_SYSTEMS = frozenset(("kb", "tourguide", "tntpgh_actions", "idx_poller",
                               "syncworks", "thurber_ai", "imagen", "search"))
HEARTBEAT_UNHEALTHY = ("degraded", "unreachable")
# status -> the only diagnostic string allowed out of this projection
HEARTBEAT_CODES = {"healthy": "check_ok", "degraded": "check_degraded",
                   "unreachable": "check_unreachable", "unknown": "check_not_observed"}


def _public_heartbeat(payload) -> dict:
    """Project a snapshot into typed names/statuses/counts and fixed codes.

    Raises ValueError for any shape that cannot be summarized honestly: an
    invalid payload must read unavailable, never healthy-by-default.
    """
    if not isinstance(payload, dict):
        raise ValueError("invalid heartbeat payload")
    generated = payload.get("generated_at")
    if not isinstance(generated, str):
        raise ValueError("invalid heartbeat timestamp")
    when = dt.datetime.fromisoformat(generated.replace("Z", "+00:00"))
    if when.tzinfo is None:
        raise ValueError("heartbeat timestamp requires timezone")
    raw = payload.get("systems")
    if not isinstance(raw, dict):
        raise ValueError("invalid heartbeat systems")
    systems, unrecognized = {}, 0
    for name, value in raw.items():
        if not isinstance(name, str) or name not in HEARTBEAT_SYSTEMS:
            unrecognized += 1
            continue
        status = value.get("status") if isinstance(value, dict) else None
        status = status if status in HEARTBEAT_CODES else "unknown"
        systems[name] = {"status": status, "code": HEARTBEAT_CODES[status]}
    if not systems:
        raise ValueError("heartbeat reported no known system")
    healthy = sorted(n for n, v in systems.items() if v["status"] == "healthy")
    unhealthy = sorted(n for n, v in systems.items() if v["status"] in HEARTBEAT_UNHEALTHY)
    return {"generated_at": when.astimezone(dt.timezone.utc).isoformat(),
            "systems": dict(sorted(systems.items())),
            "healthy_count": len(healthy), "checked_count": len(healthy) + len(unhealthy),
            "total_count": len(systems), "unrecognized_count": unrecognized,
            "unhealthy": unhealthy, "divergent": bool(healthy) and bool(unhealthy)}


def _kb_unavailable(reason: str) -> dict:
    return {"error": reason, "signal_quality_error": "signal quality reader unavailable"}


def kb_data() -> dict:
    if not (KB_DEPLOY / "server").is_dir() or not KB_PYTHON.exists():
        return _kb_unavailable("kb-deploy checkout or venv missing")
    try:
        dsn = secret("NEON_CONNECTION_STRING")
    except ValueError:
        return _kb_unavailable("KB credential configuration unavailable")
    if not dsn:
        return _kb_unavailable("NEON_CONNECTION_STRING unavailable; check the hub environment or scoped launchd credential file")
    # Do not pass broker/Slack/search credentials or Python startup overrides.
    env = {key: os.environ[key] for key in ("HOME", "PATH", "LANG", "LC_ALL", "TMPDIR") if key in os.environ}
    env.update(NEON_CONNECTION_STRING=dsn, PGOPTIONS="-c default_transaction_read_only=on")
    try:
        r = subprocess.run([str(KB_PYTHON), "-c", _KB_SNIPPET], cwd=KB_DEPLOY, env=env,
                           capture_output=True, text=True, timeout=40)
    except subprocess.TimeoutExpired:
        return _kb_unavailable("kb reader timed out (40s)")
    except OSError:
        return _kb_unavailable("kb reader could not start")
    if r.returncode != 0:
        return _kb_unavailable(f"kb reader exit {r.returncode}; database observation unavailable")
    try:
        data = json.loads(r.stdout)
    except (json.JSONDecodeError, UnicodeError):
        return _kb_unavailable("kb reader returned invalid JSON")
    if not isinstance(data, dict):
        return _kb_unavailable("kb reader returned invalid data")
    for run in data.get("runs") or []:
        run["status"] = _nightly_status(run)
    # Only the producer's fixed diagnostic categories may cross this boundary.
    # A credential can look like a short token too; shape alone is not redaction.
    for step in data.get("steps") or []:
        cls = step.get("error_class")
        if cls not in (None, "transient", "structural", "unknown"):
            step["error_class"] = "error_class_withheld"
    # Errors are fixed local messages, not exception text from the child.
    for key in ("heartbeat_error", "ledger_error", "signal_quality_error", "error"):
        if key in data:
            data[key] = "KB reader unavailable" if key == "error" else key.removesuffix("_error").replace("_", " ") + " reader unavailable"
    if "heartbeat_error" in data:
        data.pop("heartbeat", None)
    elif "heartbeat" not in data:
        data["heartbeat_error"] = "heartbeat reader unavailable"
    elif data["heartbeat"] is not None:  # None = no snapshot recorded yet, which is truthful
        try:
            data["heartbeat"] = _public_heartbeat(data["heartbeat"])
        except (ValueError, TypeError, KeyError, OverflowError):
            data.pop("heartbeat", None)
            data["heartbeat_error"] = "heartbeat unavailable: invalid snapshot contract"
    if "signal_quality_error" in data:
        data.pop("signal_quality_runs", None)
    elif "signal_quality_runs" in data:
        try:
            data["signal_quality_runs"] = _public_signal_runs(data["signal_quality_runs"])
        except (ValueError, TypeError, KeyError, OverflowError):
            data.pop("signal_quality_runs", None)
            data["signal_quality_error"] = "signal quality response unavailable: invalid aggregate contract"
    else:
        data["signal_quality_error"] = "signal quality reader unavailable"
    return data


# ── liveness ───────────────────────────────────────────────────────────────────
def probe(name: str, url: str, method: str, hb_key: str | None) -> dict:
    t0 = time.monotonic()
    try:
        req = urllib.request.Request(url, method=method, headers={"user-agent": "herdr-hub/1"})
        with urllib.request.urlopen(req, timeout=5) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code  # 401/403/302 from an auth wall is still "there"
        e.close()
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
    observed = outcome not in ("unavailable", "unreadable", "unknown")
    stale = observed and (age is None or age > stale_after_s)
    return {"name": name, "cadence": cadence, "last": last, "age_s": age, "stale": stale,
            "observed": observed, "outcome": outcome, "detail": detail, "link": link}


def _loop_age(lp: dict) -> str:
    return "unknown" if not lp["observed"] else (_age(lp["last"]) if lp["last"] else "never")


def _signal_quality_loop(kb: dict) -> dict:
    error = kb.get("error") or kb.get("signal_quality_error")
    if error or "signal_quality_runs" not in kb:
        return _loop("signal quality [9j]", "daily (inside KB nightly)", None, 26 * 3600,
                     "unavailable", "audit reader unavailable; check credentials, KB module and migration", link="/kb")
    runs = kb["signal_quality_runs"]
    last = runs[0] if runs else {}
    summary = last.get("summary") or {}
    detail = ("repeat-view eligibility and ranking invariants only; "
              f"before {summary.get('before_count', '—')} → after {summary.get('after_count', '—')}; "
              f"violations {summary.get('violation_count', '—')}")
    return _loop("signal quality [9j]", "daily (inside KB nightly)", last.get("started_at"), 26 * 3600,
                 last.get("status", "missing"), detail if last else "no recorded audit runs", link="/kb")


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


def _nightly_status(run: dict) -> str:
    if run.get("status"):
        return run["status"]
    if run.get("started_at") and not run.get("finished_at"):
        return "running"
    return "unknown" if run else "missing"


def loops_data() -> dict:
    kb = CACHES["kb"].get() or {}
    ledger_error = kb.get("error") or kb.get("ledger_error") or ("nightly ledger response unavailable" if "runs" not in kb else None)
    runs = kb.get("runs") or []
    last_run = runs[0] if runs and not ledger_error else {}
    loops = [
        _loop("KB nightly", "daily 08:00", last_run.get("started_at"), 26 * 3600,
              "unavailable" if ledger_error else _nightly_status(last_run),
              "nightly ledger reader unavailable; check credentials and database access" if ledger_error else (
                  f"{last_run.get('total_steps') or '?'} steps · {last_run.get('host') or ''}" if last_run else "no runs"),
              link="/kb"),
    ]
    heartbeat_error = kb.get("error") or kb.get("heartbeat_error") or ("heartbeat response unavailable" if "heartbeat" not in kb else None)
    hb = (kb.get("heartbeat") or {}) if not heartbeat_error else {}
    loops.append(_loop("fleet heartbeat [9h]", "daily (inside KB nightly)", hb.get("generated_at"), 26 * 3600,
                       "unavailable" if heartbeat_error else ("divergent" if hb.get("divergent") else ("ok" if hb else "missing")),
                       "heartbeat reader unavailable; check credentials and database access" if heartbeat_error else (
                           f"{hb.get('healthy_count')}/{hb.get('total_count')} healthy" if hb else "no snapshot yet"), link="/kb"))
    loops.append(_signal_quality_loop(kb))
    loops.append(_loop_sentinel())
    loops.append(_loop_stage1())
    s2, findings = _loop_stage2()
    loops.append(s2)

    suggestions = []
    for lp in loops:
        if not lp["observed"]:
            suggestions.append({"key": f"observer:{_slug(lp['name'])}", "kind": "observer",
                                "text": f"{lp['name']} execution history is unknown: {lp['detail']}. Restore reader access before judging its schedule.",
                                "link": lp.get("link")})
        elif lp["stale"]:
            suggestions.append({"key": f"stale:{_slug(lp['name'])}", "kind": "stale", "text": f"{lp['name']} has not run in {_age(lp['last']) if lp['last'] else 'ever'} (cadence {lp['cadence']}); last outcome {lp['outcome']} — check its launchd job / log.", "link": lp.get("link")})
        elif lp["outcome"] not in ("ok", "success", "healthy", "running"):
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
 iframe.dframe{height:calc(100vh - 190px);min-height:560px}
 .dhead{margin:10px 0 8px}
 details.hist{margin-top:22px;border-top:1px solid #272c37;padding-top:6px}
 details.hist>summary{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#9aa3b2;cursor:pointer;padding:6px 0;list-style:none}
 details.hist>summary::-webkit-details-marker{display:none}
 details.hist>summary::before{content:"\\25B8  ";color:#e08a4a}
 details.hist[open]>summary::before{content:"\\25BE  "}
 details.hist>summary:hover{color:#e6e9ef}
 details.hist>table{margin-top:8px}
 pre{background:#0c0e13;border:1px solid #272c37;border-radius:8px;padding:10px;overflow:auto;font-size:12px}
 button.decide{font:600 12px system-ui;padding:4px 10px;border-radius:5px;border:1px solid #6aa6ff;background:transparent;color:#6aa6ff;cursor:pointer} button.decide:hover{background:#6aa6ff;color:#0b1020}
 .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;background:#ff7a7a} .dot.ok{background:#6fd39a}
"""
NAV = [("/", "overview"), ("/decisions", "decisions"), ("/loops", "loops"), ("/herdr", "herdr"), ("/search", "search"), ("/kb", "kb"), ("/links", "links")]


def page(title: str, path: str, body: str, refresh: int = 15) -> str:
    """refresh=0 disables the meta-refresh; the caller supplies its own poller."""
    nav = " ".join(f"<a href='{p}' class='{'on' if p == path else ''}'>{n}</a>" for p, n in NAV)
    meta = f"<meta http-equiv=refresh content={refresh}>" if refresh else ""
    label = f"refresh {refresh}s" if refresh else "reloads only on change"
    return (f"<!doctype html><html lang=en><head><meta charset=utf-8>{meta}"
            f"<title>{_esc(title)}</title><style>{STYLE}</style></head><body>"
            f"<header><b>hub</b>{nav}<span class=dim style='margin-left:auto'>{label} · "
            f"<a href='{path}?json=1'>json</a></span></header><main>{body}</main></body></html>")


# Terrence, 2026-09-05: "the form kept refreshing before I could make full
# decisions." A meta-refresh page tears down the embedded form iframe every
# tick, losing whatever was half-answered. So /decisions never auto-refreshes;
# it polls /api/summary and reloads only when the OPEN FORM SET changes (one
# served, one answered) - the two moments a reload is worth losing nothing for.
DECISIONS_POLLER = """<script>
(function(){var key=%s;setInterval(function(){fetch('/api/summary').then(function(r){return r.json()})
.then(function(s){if(s.open_ids!==key)location.reload()}).catch(function(){})},5000)})();
</script>"""


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
    ledger_error = k.get("error") or k.get("ledger_error") or ("nightly reader unavailable" if "runs" not in k else None)
    heartbeat_error = k.get("error") or k.get("heartbeat_error") or ("heartbeat reader unavailable" if "heartbeat" not in k else None)
    required = [x for x in l.get("surfaces", []) if x["name"] not in OPTIONAL]
    alive = sum(1 for x in required if x["alive"])
    cards = [
        ("/herdr", att, "need attention", f"{len(h.get('tasks', []))} tasks · events to #{h.get('max_event_seq', 0)}", att > 0),
        ("/decisions", f.get("open_count", 0), "decisions open", f"{len(f.get('history', []))} answered/expired on record", f.get("open_count", 0) > 0),
        ("/links", f"{alive}/{len(required)}", "surfaces alive", "probed from this Mac; dev servers not counted", alive < len(required)),
        ("/kb", "unavailable" if ledger_error else _esc(_nightly_status(last)), "last KB nightly",
         ledger_error or (f"{_age(last.get('started_at'))} ago · {last.get('total_steps') or '?'} steps" if last else "no runs"),
         bool(ledger_error) or last.get("status") == "failed"),
        ("/kb", "unavailable" if heartbeat_error else f"{hb.get('healthy_count', '—')}/{hb.get('total_count', '—')}",
         "fleet healthy (KB heartbeat)", heartbeat_error or (f"snapshot {_age(hb.get('generated_at'))} ago" if hb else "no snapshot"),
         bool(heartbeat_error) or bool(hb.get("divergent"))),
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
        f"<div class=t>{_esc(x['name'].split(' — ')[0])}</div><div style='font-weight:600'>{'STALE · ' if x['stale'] else ''}{_esc(x['outcome'])}</div>"
        f"<div class=s>{_loop_age(x)} · {_esc(x['cadence'])}</div></a>" for x in lo.get("loops", []))
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
    # Terrence, 2026-09-06: "open decisions should expand most of the page,
    # history defaults collapsed." The open form is the only thing on this page
    # that needs acting on, so it gets the viewport; the answered/expired log is
    # reference material behind a <details>.
    body = ""
    if not d["open"]:
        body += ("<h2>Open (0)</h2><p class=dim>Nothing waiting on you. "
                 "Forms appear here the moment an agent serves one.</p>")
    for f in d["open"]:
        # Prefer the hub's own durable URL: it keeps working after the creating
        # process exits, which the form's own port does not.
        src = f.get("hub_url") or f["url"]
        body += (f"<p class=dhead><b>{_esc(f.get('title') or f['id'])}</b> <span class=dim>· served {_age(f.get('created_at'))} ago · "
                 f"expires {_age(f.get('expires_at'))} · <a href='{_esc(src)}' target=_blank>open in its own tab</a>"
                 + ("" if f.get("hub_servable") else " · <span class=pill>own port only</span>")
                 + "</span></p>"
                 f"<iframe class=dframe src='{_esc(src)}' title='{_esc(f.get('title') or f['id'])}'></iframe>")
    rows = "".join(
        f"<tr><td><span class='pill {'ok' if f['status'] == 'answered' else 'bad'}'>{_esc(f['status'])}</span></td>"
        f"<td><b>{_esc(f.get('title') or f['id'])}</b><br><small>{_esc(f.get('form_path', ''))}</small>"
        + (f"<pre>{_esc(json.dumps(f.get('answers'), indent=1, sort_keys=True))}</pre>" if f.get("answers") else "")
        + f"</td><td class=age>{_age(f.get('answered_at') or f.get('created_at'))}</td></tr>" for f in d["history"])
    body += (f"<details class=hist><summary>History · {len(d['history'])} answered/expired</summary>"
             f"<table>{rows or '<tr><td class=dim>none yet</td></tr>'}</table></details>")
    key = ",".join(sorted(f["id"] for f in d["open"]))
    return page(f"decisions · {d['open_count']} open", "/decisions",
                body + DECISIONS_POLLER % json.dumps(key), refresh=0)


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


def _render_signal_quality(d: dict) -> str:
    loop = _signal_quality_loop(d)
    body = ("<h2>Signal quality — repeat-view unit</h2>"
            "<p class=dim>Same-input before/after eligibility and ranking invariants. "
            "This does not verify all sales signals or authorize outreach.</p>")
    link = _signal_quality_link()
    if link:
        body += f"<p><a href='{_esc(link)}' target=_blank rel=noopener>Inspect audit details in authenticated KB</a></p>"
    if not loop["observed"]:
        return body + "<p class='pill bad'>unavailable</p><p class=dim>Audit history is unknown. Check reader access and the KB module/migration.</p>"
    runs = d["signal_quality_runs"]
    if not runs:
        return body + "<p class=dim>No recorded audit runs (reader succeeded).</p>"
    last = runs[0]
    summary = last["summary"]
    status = last["status"]
    explanation = {
        "ok": "Audit executed successfully; covered checks passed.",
        "degraded": "Audit executed; covered quality checks need attention.",
        "failed": "Audit failed; quality has not been established.",
        "running": "Audit is running; final quality is not yet known.",
    }[status]
    body += (f"<p><span class='pill {'bad' if loop['stale'] else ('ok' if status == 'ok' else ('run' if status == 'running' else 'bad'))}'>"
             f"{'STALE · ' if loop['stale'] else ''}{_esc(status)}</span> {_esc(explanation)}<br>"
             f"<small>Rule {_esc(last['rule_version'])} · started {_esc(last['started_at'])} · "
             f"finished {_esc(last['finished_at'] or 'not yet')} · revision {_esc(last['source_revision'] or 'unknown')}</small></p>")
    cards = (
        ("Eligible before → after", f"{summary.get('before_count', '—')} → {summary.get('after_count', '—')}"),
        ("Repeat-view before → after", f"{summary.get('repeat_before_count', '—')} → {summary.get('repeat_after_count', '—')}"),
        ("Changed", summary.get("changed_count", "—")),
        ("Withheld stale / unknown date", f"{summary.get('withheld_stale_count', '—')} / {summary.get('withheld_unknown_date_count', '—')}"),
        ("Violations", summary.get("violation_count", "—")),
        ("Window days / people", f"{summary.get('window_days', '—')} / {summary.get('person_count', '—')}"),
    )
    body += "<div class=cards>" + "".join(
        f"<div class=card><div class=t>{_esc(title)}</div><div class=n>{_esc(value)}</div></div>"
        for title, value in cards) + "</div>"
    rows = []
    for run in runs[:10]:
        counts = run["summary"]
        rows.append(
            f"<tr><td><span class='pill {'ok' if run['status'] == 'ok' else ('run' if run['status'] == 'running' else 'bad')}'>{_esc(run['status'])}</span></td>"
            f"<td>{_esc(run['started_at'])}<br><small>finished {_esc(run['finished_at'] or 'not yet')} · {_esc(run['rule_version'])}</small></td>"
            f"<td>eligible {_esc(counts.get('before_count', '—'))} → {_esc(counts.get('after_count', '—'))}<br>"
            f"<small>repeat {_esc(counts.get('repeat_before_count', '—'))} → {_esc(counts.get('repeat_after_count', '—'))} · "
            f"changed {_esc(counts.get('changed_count', '—'))} · violations {_esc(counts.get('violation_count', '—'))}</small></td></tr>")
    return body + "<h3>Latest 10 audit runs</h3><table>" + "".join(rows) + "</table>"


def render_kb() -> str:
    d = CACHES["kb"].get()
    body = _render_signal_quality(d)
    if d.get("error"):
        return page("kb", "/kb", body + f"<h2>KB reader unavailable</h2><pre>{_esc(d['error'])}</pre>", refresh=120)
    hb = d.get("heartbeat") or {}
    if hb:
        systems = hb.get("systems") or {}
        rows = "".join(
            f"<tr><td><span class='pill {'ok' if v.get('status') == 'healthy' else ('' if v.get('status') == 'unknown' else 'bad')}'>{_esc(v.get('status'))}</span></td>"
            f"<td><b>{_esc(k)}</b><br><small>{_esc(v.get('code'))}</small></td></tr>"
            for k, v in systems.items() if isinstance(v, dict))
        dropped = hb.get("unrecognized_count") or 0
        body += (f"<h2>Fleet heartbeat — {_esc(hb.get('healthy_count'))}/{_esc(hb.get('total_count'))} healthy, "
                 f"{_esc(hb.get('checked_count'))} checked, snapshot {_age(hb.get('generated_at'))} ago"
                 f"{' · DIVERGENT' if hb.get('divergent') else ''}</h2>"
                 + (f"<p class=dim>{dropped} snapshot entr{'y' if dropped == 1 else 'ies'} withheld: not a KB checker.</p>" if dropped else "")
                 + f"<table>{rows}</table>")
    elif d.get("heartbeat_error"):
        body += f"<h2>Fleet heartbeat</h2><p class='pill bad'>unavailable</p><p class=dim>{_esc(d['heartbeat_error'])}</p>"
    else:
        body += "<h2>Fleet heartbeat</h2><p class=dim>No snapshot yet.</p>"
    runs = d.get("runs") or []
    if runs:
        rows = "".join(f"<tr><td><span class='pill {'ok' if _nightly_status(r) in ('ok', 'success', 'completed') else ('run' if _nightly_status(r) == 'running' else 'bad')}'>{_esc(_nightly_status(r))}</span></td>"
                       f"<td>{_esc(r['weekday'])} · {_esc(r['host'])} · <small>{_esc((r.get('git_sha') or '')[:7])}</small></td>"
                       f"<td class=dim>{r.get('total_steps') or '?'} steps</td><td class=age title='{_esc(r['started_at'])}'>{_age(r['started_at'])}</td></tr>" for r in runs)
        body += f"<h2>Nightly runs</h2><table>{rows}</table>"
        steps = "".join(f"<tr><td><span class='pill {'ok' if s['status'] in ('ok', 'success') else ('bad' if s['status'] in ('failed', 'error') else '')}'>{_esc(s['status'])}</span></td>"
                        f"<td>{_esc(s['step_label'])}<br><small>{_esc((s.get('error_class') or '')[:160])}</small></td><td class=dim>×{s.get('attempts') or 1} · {s.get('duration_s') or 0}s</td></tr>"
                        for s in d.get("steps") or [])
        body += f"<h2>Steps of the latest run</h2><table>{steps or '<tr><td class=dim>none</td></tr>'}</table>"
    elif d.get("ledger_error"):
        body += f"<h2>Nightly ledger</h2><pre>{_esc(d['ledger_error'])}</pre>"
    else:
        body += "<h2>Nightly ledger</h2><p class=dim>No recorded nightly runs.</p>"
    return page("knowledge-base", "/kb", body or "<p class=dim>nothing to show</p>", refresh=300)


def render_links() -> str:
    d = CACHES["links"].get()
    systems = ((CACHES["kb"].get() or {}).get("heartbeat") or {}).get("systems") or {}
    rows = ""
    for s in d.get("surfaces", []):
        verdict = systems.get(s["hb"]) if s["hb"] else None
        v = (f"<span class='pill {'ok' if verdict.get('status') == 'healthy' else ('' if verdict.get('status') == 'unknown' else 'bad')}'>"
             f"KB heartbeat {_esc(s['hb'])}: {_esc(verdict.get('status'))}</span>") if isinstance(verdict, dict) else ""
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
        cls = "bad" if lp["stale"] else ("run" if lp["outcome"] == "running" else ("ok" if lp["outcome"] in ("ok", "success", "healthy") else "bad"))
        name = f"<a href='{_esc(lp['link'])}'>{_esc(lp['name'])}</a>" if lp.get("link") and not str(lp["link"]).startswith("file://") else _esc(lp["name"])
        rows += (f"<tr><td><span class='pill {cls}'>{'STALE · ' if lp['stale'] else ''}{_esc(lp['outcome'])}</span></td>"
                 f"<td><b>{name}</b><br><small>{_esc(lp['cadence'])} · {_esc(lp['detail'])}</small></td>"
                 f"<td class=age title='{_esc(lp['last'])}'>{_loop_age(lp)}</td></tr>")
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
                {"attention": len(h.get("attention", [])), "open_decisions": f.get("open_count", 0),
                 "open_ids": ",".join(sorted(x["id"] for x in f.get("open", [])))}).encode())
        if path.startswith("/decisions/"):
            code, body = serve_stored_form(path[len("/decisions/"):].strip("/"))
            return self._send(code, "text/html; charset=utf-8" if code == 200 else "text/plain", body)
        if path not in PAGES:
            return self._send(404, "text/plain", b"not found")
        render, source = PAGES[path]
        if "json=1" in query:
            data = {n: CACHES[n].get() for n in CACHES} if source is None else CACHES[source].get()
            return self._send(200, "application/json", json.dumps(data, default=str).encode())
        try:
            return self._send(200, "text/html; charset=utf-8", render().encode())
        except Exception:  # a render bug must never publish exception text on an unauthenticated surface
            return self._send(500, "text/plain", b"page render unavailable")

    def do_POST(self):
        path, _, _ = self.path.partition("?")
        if path.startswith("/decisions/") and path.endswith("/submit"):
            form_id = path[len("/decisions/"):-len("/submit")].strip("/")
            n = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(n) if n > 0 else b"{}"
            try:
                payload = json.loads(raw.decode("utf-8") or "{}")
            except (UnicodeDecodeError, json.JSONDecodeError) as e:
                return self._send(400, "text/plain", f"bad json: {e}".encode())
            if not isinstance(payload, dict):
                return self._send(400, "text/plain", b"answers must be a JSON object")
            code, body = record_answer(form_id, payload)
            return self._send(code, "application/json" if code == 200 else "text/plain", body)
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
