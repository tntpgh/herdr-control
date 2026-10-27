"""hub_ui — the hub's replaceable presentation layer.

hub.py owns the data, routes, controls and every render_* body. This module
owns only the page chrome (head, nav, display prefs), the stylesheet, the
theme files and the Ship view (layout B on `/`).

The split that must hold:
- CANONICAL (here, in Python): station membership, job-class labels, display
  states and the words that describe them. A theme cannot move a job class,
  rename a state or soften a status word.
- THEME (themes/<id>/theme.json): palette, place names, crew drawings,
  captions. Drop a folder in themes/ and it appears in the Display menu after
  a hub restart. Themes are dark only; a palette that fails validation is
  skipped and named in the Display menu rather than half-applied.

Nothing here reads a store, opens a socket or adds a route: chrome() is a pure
function of its arguments, and ship_snapshot() is a pure function of cache
values hub.py already holds.
"""
from __future__ import annotations

import base64
import datetime as dt
import html
import json
import re
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_THEME = "bebop"

# lib/agent-profiles.sh:135 KNOWN_JOB_CLASSES, same order. check.py compares
# the two so a class added there cannot silently land in "unrecognized" here.
JOB_CLASSES = ("plan", "architect", "review", "deep-review", "design", "implement", "debug",
               "code", "docs", "explore", "research", "quick", "mechanical")
JOB_LABELS = {"plan": "Planning", "architect": "Architecture", "review": "Review",
              "deep-review": "Deep review", "design": "Design", "implement": "Build",
              "debug": "Debug", "code": "Code", "docs": "Docs", "explore": "Explore",
              "research": "Research", "quick": "Quick check", "mechanical": "Mechanical sweep"}

# Ship stations: the 5 rooms of T's approved reference (Bridge/Project Deck/
# Build Bay/Scout Desk/Quality Gate). Labels are the plain heading; a theme
# adds a place name and a crew member underneath, never instead. Quality
# Gate folds Ein's quick/mechanical checks and Vicious's independent review
# into one room, per the approved layout -- review's literalness (state
# still comes only from hub.py's own data) is unaffected by which room
# draws it. Tasks whose job has no station (job_of() fell back to
# "unrecognized") get station=None and are not drawn as a 6th room; they
# surface, by label, in the Maintenance side panel instead (ui.js).
STATIONS = (
    {"id": "bridge", "label": "Bridge", "jobs": ["plan", "architect"], "shows": ["decisions"]},
    {"id": "projectdeck", "label": "Project Deck", "jobs": ["debug"], "shows": ["projects"]},
    {"id": "buildbay", "label": "Build Bay", "jobs": ["design", "implement", "code", "docs"], "shows": []},
    {"id": "scout", "label": "Scout Desk", "jobs": ["research", "explore"], "shows": []},
    {"id": "qualitygate", "label": "Quality Gate", "jobs": ["quick", "mechanical", "review", "deep-review"], "shows": []},
)

# Display states. `attention` mirrors hub.ATTENTION (blocked/stalled/ready_review)
# plus the states that mean "this is not what it claims". Only `executing`
# may animate, and only while herdr's subscription is connected.
DISPLAY = {
    "executing":       {"label": "Working (herdr live)", "icon": "\u25B6", "attention": False},
    "unconfirmed":     {"label": "Running? unconfirmed", "icon": "\u25CC", "attention": False},
    "starting":        {"label": "Starting", "icon": "\u25CB", "attention": False},
    "blocked":         {"label": "Waiting on a person", "icon": "?", "attention": True},
    "stalled":         {"label": "Stalled, owes an action", "icon": "\u25B3", "attention": True},
    "in_review":       {"label": "Ready for review, not done", "icon": "\u25C9", "attention": True},
    "done_with_proof": {"label": "Completed, proof on file", "icon": "\u2714", "attention": False},
    "closed":          {"label": "Completed, no proof on file", "icon": "\u25A0", "attention": False},
    "failed":          {"label": "Failed", "icon": "\u2716", "attention": True},
    "cancelled":       {"label": "Cancelled", "icon": "\u2298", "attention": False},
    "lost":            {"label": "Lost", "icon": "\u2205", "attention": True},
    "gone":            {"label": "Pane gone", "icon": "\u2205", "attention": True},
    "unknown":         {"label": "Unrecognized state", "icon": "\u00BF", "attention": True},
}
TERMINAL = ("completed", "failed", "cancelled", "lost", "gone")
RECENT_FINISHED_S = 24 * 3600
SHIP_TASK_CAP = 60

# Which pages carry which crew emblem (theme.panels maps the key to a character).
PANELS = {"/": "overview", "/projects": "projects", "/decisions": "decisions", "/loops": "loops",
          "/timeline": "timeline", "/herdr": "herdr", "/kb": "kb", "/owners": "owners",
          "/links": "links", "/search": "search"}
DIAGNOSTICS = ("/herdr", "/owners", "/kb", "/links", "/search")
REQUIRED_PALETTE = ("--bg", "--surface", "--surface-2", "--fg", "--muted", "--accent",
                    "--brass", "--border", "--ok", "--warn", "--bad", "--info")
_THEME_ID = re.compile(r"[a-z][a-z0-9-]{0,31}")
_HEX = re.compile(r"#[0-9a-fA-F]{6}")


def _esc(s) -> str:
    return html.escape("" if s is None else str(s), quote=True)


def load_themes(root: Path = HERE / "themes") -> tuple[dict, list[str]]:
    """({id: theme}, [problems]). A theme whose folder name or palette is
    invalid is skipped and reported; the default theme must load."""
    themes, problems = {}, []
    for p in sorted(root.glob("*/theme.json")):
        tid = p.parent.name
        try:
            t = json.loads(p.read_text())
        except (OSError, ValueError) as e:
            problems.append(f"{tid}: unreadable ({type(e).__name__})")
            continue
        pal = t.get("palette") if isinstance(t, dict) else None
        bad = [k for k in REQUIRED_PALETTE if not (isinstance(pal, dict) and _HEX.fullmatch(str(pal.get(k, ""))))]
        if not _THEME_ID.fullmatch(tid) or bad:
            problems.append(f"{tid}: skipped ({'bad folder name' if not _THEME_ID.fullmatch(tid) else 'palette missing ' + ', '.join(bad)})")
            continue
        t["id"] = tid
        themes[tid] = t
    if DEFAULT_THEME not in themes:
        raise RuntimeError(f"hub_ui: default theme {DEFAULT_THEME!r} did not load: {problems}")
    return themes, problems


THEMES, THEME_PROBLEMS = load_themes()
# The approved reference image (T, 2026-10-27), copied verbatim into the
# theme folder -- not generated, not re-encoded. Only a theme that ships its
# own ship.png gets the art backdrop; plain has none, by design (no
# drawings in plain mode, same as the sprite characters it also omits).
for _tid, _t in THEMES.items():
    _ship_png = HERE / "themes" / _tid / "ship.png"
    if _ship_png.is_file():
        _t["ship_image"] = "data:image/png;base64," + base64.b64encode(_ship_png.read_bytes()).decode("ascii")
# Inlined into every page, so comments are stripped: page-level checks look
# for status words in the HTML, and a comment must not be able to match one.
BASE_CSS = re.sub(r"/\*.*?\*/", "", (HERE / "base.css").read_text(), flags=re.S)
UI_JS = re.sub(r"^\s*//.*\n", "", re.sub(r"\A/\*.*?\*/\s*", "", (HERE / "ui.js").read_text(), flags=re.S), flags=re.M)


def _script_json(obj) -> str:
    """JSON safe inside <script type=application/json>: no `</script>` or
    `<!--` can close or confuse the element."""
    return json.dumps(obj, separators=(",", ":"), default=str).replace("<", "\\u003c")


def _theme_css() -> str:
    return "".join(
        f"html[data-theme=\"{tid}\"]{{" + ";".join(f"{k}:{t['palette'][k]}" for k in REQUIRED_PALETTE) + "}"
        for tid, t in THEMES.items())


def _client_themes() -> dict:
    """What ui.js needs per theme: names and drawings, never the palette (CSS has it)."""
    keep = ("name", "sprite_style", "characters", "stations", "panels", "ship_image")
    return {tid: {k: t.get(k) for k in keep if t.get(k) is not None} for tid, t in THEMES.items()}


_BOOT = """<script>(function(){var d=document.documentElement,p={};
try{p=JSON.parse(localStorage.getItem('hub.ui')||'{}')||{}}catch(e){}
var T=%s;d.setAttribute('data-js','1');
if(T.indexOf(p.theme)>=0)d.setAttribute('data-theme',p.theme);
if(p.reduce)d.setAttribute('data-reduce','1');if(p.flavour)d.setAttribute('data-flavour','1');
var v=null;try{v=new URLSearchParams(location.search).get('view')}catch(e){}
v=v||p.view;d.setAttribute('data-view',v==='overview'?'overview':'ship');})();</script>"""


def chrome(title: str, path: str, body: str, nav, refresh: int = 15, scope: str = "", json_extra: str = "") -> str:
    """The whole page around a render_* body. Same contract as hub.page():
    refresh=0 disables the meta refresh; `scope` rides on the refresh URL and
    the json link; `json_extra` is appended to the json link only."""
    q = f"?repo={urllib.parse.quote(scope)}" if scope else ""
    meta = f"<meta http-equiv=refresh content='{refresh};url={path}{q}'>" if refresh else ""
    label = f"refresh {refresh}s" if refresh else "reloads only on change"
    json_href = f"{path}?json=1{('&repo=' + urllib.parse.quote(scope)) if scope else ''}{_esc(json_extra)}"

    def link(p: str, n: str) -> str:
        on = p == path
        return f"<a href='{p}' class='{'on' if on else ''}'{' aria-current=page' if on else ''}>{n}</a>"
    main_nav = " ".join(link(p, n) for p, n in nav if p not in DIAGNOSTICS)
    diag_nav = " ".join(link(p, n) for p, n in nav if p in DIAGNOSTICS)
    options = "".join(f"<option value='{_esc(tid)}'>{_esc(t.get('name') or tid)}</option>" for tid, t in THEMES.items())
    problems = (f"<p class=dim>Themes skipped: {_esc('; '.join(THEME_PROBLEMS))}</p>" if THEME_PROBLEMS else "")
    prefs = ("<details class=prefs><summary>Display</summary><div class=prefs-body>"
             f"<label>Theme <select id=pref-theme>{options}</select></label>"
             "<label><input type=checkbox id=pref-reduce> Reduce motion</label>"
             "<label><input type=checkbox id=pref-flavour> Character captions</label>"
             f"{problems}</div></details>")
    panel = PANELS.get(path, "")
    return (f"<!doctype html><html lang=en data-theme='{DEFAULT_THEME}'><head><meta charset=utf-8>{meta}"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            f"<title>{_esc(title)}</title>"
            + _BOOT % json.dumps(sorted(THEMES))
            + f"<style>{_theme_css()}{BASE_CSS}</style></head><body>"
            "<a class=skip href='#main'>Skip to content</a>"
            f"<header><b class=brand>hub</b><nav aria-label='Hub pages'>{main_nav}"
            f"<span class=navgroup><span class=navlabel>diagnostics</span> {diag_nav}</span></nav>"
            f"<span class='dim hdr-meta'>{label} · <a href='{json_href}'>json</a></span>{prefs}</header>"
            f"<main id=main tabindex=-1 data-view='{_esc(panel or path.strip('/'))}'>"
            f"<div class=crew-slot data-panel='{_esc(panel)}' aria-hidden=true></div>{body}</main>"
            f"<script type=application/json id=hub-themes>{_script_json(_client_themes())}</script>"
            f"<script>{UI_JS}</script></body></html>")


# ── Ship view (layout B) ───────────────────────────────────────────────────────
def job_of(label) -> str:
    """spawn-task.sh:481 labels tasks `<job>:<branch>`. Anything else is
    'unrecognized': a fallback, not a class."""
    head = str(label or "").split(":", 1)[0]
    return head if ":" in str(label or "") and head in JOB_CLASSES else "unrecognized"


def station_of(job: str) -> str | None:
    for st in STATIONS:
        if job in st["jobs"]:
            return st["id"]
    return None


def display_of(t: dict) -> tuple[str, str]:
    """(display key, plain words) for one herdr_data() task row. Words come
    only from fields on the row; nothing is inferred beyond them."""
    st, src = t.get("state"), t.get("state_source")
    reason, proof = t.get("closure_reason"), t.get("closure_proof")
    if st == "running":
        key = "executing" if src == "live" else "unconfirmed"
    elif st == "ready_review":
        key = "in_review"
    elif st == "completed":
        key = "done_with_proof" if proof else "closed"
    elif st in DISPLAY:
        key = st
    else:
        key = "unknown"
    words = {
        "executing": "herdr reports this pane working.",
        "unconfirmed": "Registry says running; herdr has no live status for this pane. Not known to be working.",
        "starting": "Launched; no work reported yet.",
        "blocked": "Waiting on a person.",
        "stalled": "Idle while owing the conductor an action.",
        "in_review": "Finished; waiting on review. Not done until reviewed.",
        "done_with_proof": f"Completed ({reason or 'no reason recorded'}). Proof: {proof}.",
        "closed": f"Completed: {reason or 'no reason recorded'}. No proof on file.",
        "failed": "Failed.",
        "cancelled": f"Cancelled ({reason or 'no reason recorded'}).",
        "lost": "Lost: the worker disappeared without a result.",
        "gone": "herdr no longer has this pane; the worker is not running.",
        "unknown": f"Engine state \u201c{st}\u201d is not one this view knows; shown as-is.",
    }[key]
    if src == "stored" and key not in ("executing", "unconfirmed"):
        words += " Unconfirmed: registry copy, herdr has no live status."
    if t.get("state_stale") and t.get("stored_state"):
        words += f" Registry still says {t['stored_state']}."
    return key, words


def _epoch(iso) -> float | None:
    try:
        return dt.datetime.fromisoformat(str(iso).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def ship_snapshot(h: dict, forms: dict, portal: dict, loops: dict, live_connected: bool, now: float) -> dict:
    """Everything the Ship view draws, from cache values render_overview()
    already read. Field lists are allow-lists: no form token, port, worktree
    path or conductor id leaves this function."""
    tasks = h.get("tasks") or []
    shown, hidden_finished = [], 0
    for t in tasks:
        state = t.get("state")
        age = now - (_epoch(t.get("updated_at")) or 0)
        if state in TERMINAL and age > RECENT_FINISHED_S:
            hidden_finished += 1
            continue
        shown.append(t)
    capped = max(0, len(shown) - SHIP_TASK_CAP)
    shown = shown[:SHIP_TASK_CAP]
    rows = []
    for t in shown:
        key, words = display_of(t)
        job = job_of(t.get("label"))
        rows.append({"label": t.get("label") or t.get("task_id"), "job": job,
                     "job_label": JOB_LABELS.get(job, "Unrecognized job class"),
                     "station": station_of(job), "display": key, "words": words,
                     "state": t.get("state"), "source": t.get("state_source"),
                     "repo": str(t.get("repo") or "").rsplit("/", 1)[-1],
                     "project": t.get("project") or str(t.get("repo") or "").rsplit("/", 1)[-1],
                     "pane": t.get("pane_id"), "updated_at": t.get("updated_at")})
    projects: dict = {}
    for r in rows:
        p = projects.setdefault(r["project"], {"name": r["project"], "tasks": 0, "attention": 0})
        p["tasks"] += 1
        p["attention"] += DISPLAY[r["display"]]["attention"]
    history = forms.get("history") or []
    decisions = {
        "open": [{"title": f.get("title") or f.get("id"), "created_at": f.get("created_at"),
                  "expires_at": f.get("expires_at")} for f in (forms.get("open") or [])],
        "expired_recent": sum(1 for f in history if f.get("status") in ("expired", "gone")),
        "portal_open": portal.get("open_count", 0), "portal_error": bool(portal.get("error")),
    }
    sugg_words = {"deciding": "Decision form open.", "accept": "Accepted; awaiting conductor dispatch.",
                  "hold": "On hold."}
    suggestions = [{"kind": s.get("kind"), "text": str(s.get("text") or "")[:240],
                    "status": sugg_words.get((s.get("decision") or {}).get("state"), "No decision yet.")}
                   for s in (loops.get("suggestions") or [])
                   if (s.get("decision") or {}).get("state") != "dismissed"][:3]
    lps = loops.get("loops") or []
    bad_loops = [x.get("name", "").split(" \u2014 ")[0] for x in lps
                 if x.get("stale") or x.get("outcome") not in ("ok", "success", "healthy")]
    return {"generated_at": dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "live_connected": bool(live_connected), "error": h.get("error"),
            "stations": STATIONS, "display": DISPLAY, "tasks": rows,
            "hidden_finished": hidden_finished, "capped": capped,
            "attention_registry": len(h.get("attention") or []),
            "unrecognized": [r for r in rows if r["station"] is None],
            "projects": sorted(projects.values(), key=lambda p: (-p["attention"], p["name"])),
            "decisions": decisions, "suggestions": suggestions,
            "loops": {"total": len(lps), "bad": bad_loops}}


def home(chips: str, overview_body: str, snapshot: dict) -> str:
    """`/`: Ship (B, default with JS) and Overview (A, the server-rendered
    page, always present and the only view without JS)."""
    return (chips
            + "<fieldset class=viewbar><legend>Layout</legend>"
              "<label><input type=radio name=hub-view value=ship> Ship</label>"
              "<label><input type=radio name=hub-view value=overview> Overview</label></fieldset>"
            + "<section id=ship-view aria-labelledby=ship-h><h2 id=ship-h>Ship</h2><div id=ship-body></div></section>"
            + f"<section id=overview-view aria-label=Overview>{overview_body}</section>"
            + f"<script type=application/json id=ship-data>{_script_json(snapshot)}</script>")
