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

import datetime as dt
import hashlib
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
# r4 review (tmp/in/REVIEW-r4.md item 3): the reference's top nav is 3 tabs
# (Ship/Projects/Decisions). Every other page (DIAGNOSTICS plus /loops and
# /timeline) moves into the closed-by-default disclosure in chrome().
#
# r19 fix (tmp/in/r19/R19-AMEND-SPA.md): a 4th "Bounties" tab was planned
# here and briefly rendered disabled (no backing route yet); T's amendment
# put the bounty board inline on Ship instead of behind a tab, so there is
# no 4th nav entry to wire or keep disabled.
PRIMARY_NAV = ("/", "/projects", "/decisions")
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
# Served from its own same-origin, content-addressed route (hub.py do_GET)
# instead of inlined as a data: URI in every page's #hub-themes JSON --
# r4 review (tmp/in/REVIEW-r4.md item 4): inlining put 2.9MB on every one
# of the 14 HTML routes, re-sent on every meta-refresh. The URL's hash
# segment is the asset's own content hash, so Cache-Control can be
# `immutable`: the URL only changes when the PNG does.
STATIC_ASSETS: dict[str, tuple[bytes, str]] = {}
for _tid, _t in THEMES.items():
    _ship_png = HERE / "themes" / _tid / "ship.png"
    if _ship_png.is_file():
        _bytes = _ship_png.read_bytes()
        _url = f"/static/ship-{hashlib.sha256(_bytes).hexdigest()[:8]}.png"
        STATIC_ASSETS[_url] = (_bytes, "image/png")
        _t["ship_image"] = _url
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
    keep = ("name", "tagline", "sprite_style", "characters", "stations", "panels", "ship_image")
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
    nav_by_path = dict(nav)
    other = [(p, n) for p, n in nav if p not in PRIMARY_NAV]
    # Ship / Projects / Decisions, in that order.
    #
    # r19 fix (tmp/in/r19/R19-AMEND-SPA.md, T's exact words: "i dont want
    # it on a tab, i want the dashboard closer to a one page SPA"): the
    # disabled "bounties" tab this comment used to describe is removed
    # entirely rather than enabled -- the bounty board now lives inline on
    # Ship itself (renderShip()'s own bounty-board section), not behind a
    # nav entry at all.
    main_nav = (
        link("/", nav_by_path.get("/", "ship"))
        + link("/projects", nav_by_path.get("/projects", "projects"))
        + link("/decisions", nav_by_path.get("/decisions", "decisions"))
    )
    diag_nav = " ".join(link(p, n) for p, n in other)
    diag_open = " open" if any(p == path for p, _ in other) else ""
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
            f"<details class=navgroup{diag_open}><summary class=navlabel>more pages</summary>"
            f"<nav class=navgroup-body aria-label='More hub pages'>{diag_nav}</nav></details></nav>"
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


def ship_snapshot(h: dict, forms: dict, portal: dict, loops: dict, live: dict, now: float,
                   synthetic: bool = False, scope: str = "") -> dict:
    """Everything the Ship view draws, from cache values render_overview()
    already read. Field lists are allow-lists: no form token, port, worktree
    path or conductor id leaves this function. `synthetic` is
    hub.PREVIEW_SYNTHETIC, true only under prototype/hub-preview/preview.py's
    fixture data (tmp/in/FIX-r14b.md item 4) -- never true against the live
    registry. `live` is hub.live_data()'s own dict (connected/agents/stats),
    the same source hub.py's _live_rows() reads for /herdr -- not just a
    connected flag, so the Ship workers section below can be built from a
    cache value already held, not a second live read of its own. `scope` is
    the same repo-scope string render_overview() passes to scoped(h_all,
    scope) -- `h` here is ALREADY that scoped dict, so h["tasks"] already
    only contains this repo's tasks; `scope` itself is only needed to tell
    "no scope, list every pane" apart from "scoped, drop panes with no task
    in this repo" (a hand-started pane with no task at all is legitimately
    shown under no scope)."""
    live_connected = bool(live.get("connected"))
    tasks = h.get("tasks") or []
    # Current workers (Ship's "workers" section): herdr's own live agent
    # list, joined to the registry task that owns each pane -- the same
    # join hub.py's _live_rows() does for /herdr, read from the same `live`
    # value, not a second subscription read. `agent` is herdr's AGENT KIND
    # (the CLI it launched: "omp", "claude", "codex" -- lib/herdr_live.py's
    # own field), never a model id: no source in this registry records
    # which model a task ran with (model_for_agent in lib/agent-profiles.sh
    # resolves one at LAUNCH time, to build the command line, and nothing
    # writes it back into the registry afterward). Showing it as a model
    # would be inventing a fact; the Ship workers section says so plainly
    # instead (tmp/in/REVIEW-DASH.md F2).
    tasks_by_pane = {t.get("pane_id"): t for t in tasks if t.get("pane_id")}
    agents = live.get("agents") or []
    workers_hidden = 0
    # N1 fix (tmp/in/REVIEW-DASH.md round-2 finding): under a repo scope, a
    # pane whose owning task is NOT in this repo must be dropped and
    # counted, exactly like _live_rows() (hub.py ~5263-5268) -- the "scoped
    # task list above an unscoped pane list" incident that function's own
    # docstring (hub.py ~5248-5254) warns is a real, previously-shipped bug.
    if scope:
        mine = set(tasks_by_pane.keys())
        kept = [p for p in agents if p.get("pane_id") in mine]
        workers_hidden = len(agents) - len(kept)
        agents = kept
    workers = []
    if live_connected:
        for p in agents:
            task = tasks_by_pane.get(p.get("pane_id")) or {}
            reg = task.get("state")
            blocked = p.get("agent_status") == "blocked"
            diverges = bool(reg) and ((reg == "blocked") != blocked) and reg not in TERMINAL
            since = p.get("since")
            workers.append({
                "pane": p.get("pane_id"), "task": task.get("label") or p.get("label") or "",
                "herdr_status": p.get("agent_status"), "registry_state": reg, "diverges": diverges,
                "agent": p.get("agent"), "workspace": p.get("workspace"),
                "since": (dt.datetime.fromtimestamp(since, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                          if isinstance(since, (int, float)) else None),
            })
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
                     "pane": t.get("pane_id"), "updated_at": t.get("updated_at"),
                     # r19 addendum (tmp/in/r19/R19-BOUNTY-MOTION.md section A):
                     # the bounty board needs the same closure_reason/proof
                     # herdr_data() already joins onto every task (see its own
                     # comment, hub.py ~line 930) and state_stale (hub.py's own
                     # derive()-vs-stored divergence flag) -- both were computed
                     # all along, just never copied past this loop before.
                     "closure_reason": t.get("closure_reason"), "closure_proof": t.get("closure_proof"),
                     "state_stale": bool(t.get("state_stale"))})
    projects: dict = {}
    for r in rows:
        p = projects.setdefault(r["project"], {"name": r["project"], "tasks": 0, "attention": 0})
        p["tasks"] += 1
        p["attention"] += DISPLAY[r["display"]]["attention"]
    history = forms.get("history") or []
    # r12 addendum (tmp/in/ITERATE-r12-ADDENDUM.md item 5): small slice of
    # forms["history"] for the Ship Decisions feed -- the same source the
    # real Decisions page's own History panel already reads (hub.py
    # render_decisions, ~line 5365); allow-listed the same way `open` is.
    recent_closed = sorted(history, key=lambda f: f.get("answered_at") or f.get("created_at") or "", reverse=True)[:5]
    decisions = {
        "open": [{"id": f.get("id"), "title": f.get("title") or f.get("id"), "created_at": f.get("created_at"),
                  "expires_at": f.get("expires_at")} for f in (forms.get("open") or [])],
        "recent_closed": [{"title": f.get("title") or f.get("id"), "status": f.get("status"),
                           "created_at": f.get("created_at"), "answered_at": f.get("answered_at")}
                          for f in recent_closed],
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
    # r14b fix (tmp/in/FIX-r14b.md item 4): DISPLAY["executing"]["label"] is
    # "Working (herdr live)" -- true for real production data (display_of()
    # only reaches "executing" for a task whose OWN state_source is a
    # confirmed-live herdr read), but under preview/synthetic fixtures that
    # "live" marking is itself invented by fixtures.py, not a real
    # connection. Swap just that one label so every call site that reads
    # S.display[key].label (room cards, pins, feed chips all go through it)
    # gets the honest word for free.
    display = dict(DISPLAY, executing=dict(DISPLAY["executing"], label="Working (synthetic)")) if synthetic else DISPLAY
    return {"generated_at": dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "live_connected": bool(live_connected), "synthetic": bool(synthetic), "error": h.get("error"),
            "stations": STATIONS, "display": display, "tasks": rows,
            "hidden_finished": hidden_finished, "capped": capped,
            "attention_registry": len(h.get("attention") or []),
            "unrecognized": [r for r in rows if r["station"] is None],
            "projects": sorted(projects.values(), key=lambda p: (-p["attention"], p["name"])),
            "decisions": decisions, "suggestions": suggestions,
            "workers": workers, "workers_live_error": (live.get("stats") or {}).get("last_error"),
            "workers_hidden": workers_hidden,
            "loops": {"total": len(lps), "bad": bad_loops}}


def home(chips: str, overview_body: str, snapshot: dict) -> str:
    """`/`: Ship (B, default with JS) and Overview (A, the server-rendered
    page, always present and the only view without JS). r14b fix
    (tmp/in/FIX-r14b.md item 7): repo chips and the Ship/Overview layout
    radio used to render inline above Ship, crowding the primary route
    alongside the room list, suggestions, maintenance and four feeds.
    Both are chrome (outside renderShip()'s own output, so check.js's
    form/button/input ban in prototype/hub-preview/check.js:45 does not
    reach them) and both are secondary to "what does Ship need me to see
    right now" -- collapsed behind one closed-by-default More section."""
    return ("<details class=chrome-more><summary>More</summary>"
            + chips
            + "<fieldset class=viewbar><legend>Layout</legend>"
              "<label><input type=radio name=hub-view value=ship> Ship</label>"
              "<label><input type=radio name=hub-view value=overview> Overview</label></fieldset>"
            + "</details>"
            + "<section id=ship-view aria-labelledby=ship-h><h2 id=ship-h>Ship</h2><div id=ship-body></div></section>"
            + f"<section id=overview-view aria-label=Overview>{overview_body}</section>"
            + f"<script type=application/json id=ship-data>{_script_json(snapshot)}</script>")
