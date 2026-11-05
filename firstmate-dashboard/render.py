"""render — HTML for the Firstmate dashboard, a pure function of a snapshot.

Palette, base stylesheet and ship art come from lib/hub_ui (the hub's
presentation module, which reads no store and opens no socket). Under a
theme that ships art (Bebop), the page IS the ship: the approved cutaway
(ship.png) is the backdrop, each room's status panel on the art carries that
room's live Firstmate work, and Big Shot's screen is the bounty board. A
theme without art (Plain dark, the accessible alternative) draws the same
rooms as a text hull grid, after prototype/board.

Crew names are decoration only: a badge beside a row, never a word that
replaces a state. Every crew state shown is fm-crew-state.sh's own word.
"""
from __future__ import annotations

import html
import json
import re
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import hub_ui  # noqa: E402

THEMES = hub_ui.THEMES
DEFAULT_THEME = hub_ui.DEFAULT_THEME
STATIC_ASSETS = hub_ui.STATIC_ASSETS
MAX_ANSWER_CHARS = 4000
_HEX = re.compile(r"#[0-9a-fA-F]{6}")

# Firstmate task kind -> Bebop crew member (decoration; a theme without that
# character just draws no badge).
KIND_CREW = {"captain": "jet", "secondmate": "spike", "ship": "ed", "scout": "faye", "review": "vicious"}
FALLBACK_CREW = "old-guys"
# fm-crew-state.sh state -> hub_ui .st[data-d] style. The visible word stays the crew-state word.
STATE_STYLE = {"working": "executing", "parked": "in_review", "done": "done_with_proof", "blocked": "blocked",
               "paused": "starting", "failed": "failed", "unknown": "unknown"}

# The ship's rooms, top to bottom as ship.png draws them. Which room a crew
# sits in is decided here by Firstmate task kind; a theme only names and
# draws the room. Captain calls (captain holds) are Bridge work. A kind no
# room claims lands in CARGO (the three old guys), never in a guessed room.
STATIONS = (
    {"id": "bridge", "label": "Bridge", "kinds": ("captain",), "what": "Your calls and captain-kind work."},
    {"id": "projectdeck", "label": "Project Deck", "kinds": ("secondmate",), "what": "Secondmates running their own homes."},
    {"id": "buildbay", "label": "Build Bay", "kinds": ("ship",), "what": "Ship crews building and fixing."},
    {"id": "scout", "label": "Scout Desk", "kinds": ("scout",), "what": "Scouts reading and reporting."},
    {"id": "qualitygate", "label": "Quality Gate", "kinds": ("review",), "what": "Independent review."},
)
CARGO = {"id": "cargo", "label": "Cargo hold", "kinds": (), "what": "Work of a kind no room claims."}
_STATION_OF = {k: st for st in STATIONS for k in st["kinds"]}

BOUNTY_LABEL = {"open": ("\u25CB", "Open"), "in_progress": ("\u25B6", "In progress"),
                "awaiting_evidence": ("\u25D0", "Awaiting evidence"), "verified": ("\u2714", "Verified")}

# ── art geometry: pixel boxes in ship.png (1536x1024) ─────────────────────────
# Measured on the image itself; every CSS percentage below is computed from
# these, never hand-rounded. HULL drops the baked top nav band, the Big Shot
# column and the baked bottom bar. SLOT_* are the five baked status panels on
# the hull's right edge (padded 2px so no baked text shows at their edges);
# the live room cards cover them exactly. ROW_Y bands are each room's own
# strip (x 0..752, left of the panels), used as the room banner when the
# page is too narrow to overlay the cutaway.
ART = (1536, 1024)
HULL = (0, 68, 992, 850)
SLOT_X = (761, 968)
SLOT_Y = {"bridge": (245, 330), "projectdeck": (375, 461), "buildbay": (511, 600),
          "scout": (647, 733), "qualitygate": (789, 878)}
ROW_X = 752
ROW_Y = {"bridge": (150, 338), "projectdeck": (344, 470), "buildbay": (480, 604),
         "scout": (614, 740), "qualitygate": (750, 888)}
BIGSHOT = (1012, 92, 508, 153)
OLDGUYS = (1025, 788, 200, 108)
NARROW_PX = 720


def _pct(v: float) -> str:
    return f"{v:.4f}".rstrip("0").rstrip(".") + "%"


def _crop(x: int, y: int, w: int, h: int) -> str:
    """CSS that shows exactly the (x, y, w, h) box of the art in an element."""
    aw, ah = ART
    px = 0 if aw == w else x / (aw - w) * 100
    py = 0 if ah == h else y / (ah - h) * 100
    return (f"aspect-ratio:{w}/{h};background-size:{_pct(aw / w * 100)} {_pct(ah / h * 100)};"
            f"background-position:{_pct(px)} {_pct(py)}")


def _art_css(theme: dict) -> str:
    url = theme.get("ship_image")
    if not url:
        return ""
    hx, hy, hw, hh = HULL
    slots = "".join(
        f".fm-art-on .fm-slot[data-station={sid}]{{left:{_pct((SLOT_X[0] - hx) / hw * 100)};"
        f"top:{_pct((y0 - hy) / hh * 100)};width:{_pct((SLOT_X[1] - SLOT_X[0]) / hw * 100)};"
        f"height:{_pct((y1 - y0) / hh * 100)}}}"
        for sid, (y0, y1) in SLOT_Y.items())
    banners = "".join(f".fm-banner[data-station={sid}]{{{_crop(0, y0, ROW_X, y1 - y0)}}}"
                      for sid, (y0, y1) in ROW_Y.items())
    return (f".fm-art,.fm-banner,.fm-bigshot-art,.fm-oldguys{{background-image:url('{url}')}}"
            f".fm-art{{{_crop(*HULL)}}}.fm-bigshot-art{{{_crop(*BIGSHOT)}}}.fm-oldguys{{{_crop(*OLDGUYS)}}}"
            f"{banners}@media (min-width:{NARROW_PX + 1}px){{{slots}}}")


DASH_CSS = """
main{max-width:1680px}
.fm-brand small{display:block;font-size:11px;color:var(--muted);letter-spacing:.08em;text-transform:uppercase}
.fm-motion{font:12px system-ui;color:var(--muted);background:none;border:1px solid var(--border);border-radius:6px;padding:2px 8px;cursor:pointer}
.fm-motion[aria-pressed=true]{color:var(--fg);border-color:var(--accent)}
html:not([data-js]) .fm-motion{display:none}
.fm-stage{display:grid;grid-template-columns:minmax(0,1.85fr) minmax(300px,1fr);gap:16px;align-items:start;margin-top:12px}
@media (max-width:1100px){.fm-stage{grid-template-columns:minmax(0,1fr)}}
.fm-deck{min-width:0}
.fm-ship{position:relative;container-type:inline-size;min-width:0}
.fm-art{position:relative;overflow:hidden;border:2px solid var(--brass);border-radius:12px;background-color:var(--surface-2);background-repeat:no-repeat}
.fm-slots{list-style:none;margin:0;padding:0}
.fm-slot{min-width:0}
.fm-slot-link{display:grid;align-content:center;gap:.2em;height:100%;padding:.55em .8em;color:var(--fg);text-decoration:none;
  background:var(--surface-2);border:1px solid var(--border);border-top:3px solid var(--accent);border-radius:8px;overflow:hidden}
.fm-slot-link:hover .fm-slot-top{text-decoration:underline}
.fm-slot-name{font-weight:700}
.fm-slot-name small{font-weight:400;margin-left:.5em}
.fm-slot-sum{font-weight:600;color:var(--accent)}
.fm-slot[data-hot] .fm-slot-sum{color:var(--warn)}
.fm-slot-top{overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;word-break:break-word}
.fm-slot-state{display:flex;gap:.45em;align-items:center;color:var(--muted)}
.fm-dot{flex:none;display:inline-block;width:.75em;height:.75em;border-radius:50%;background:var(--muted);border:1px solid var(--bg)}
.fm-dot[data-d=executing]{background:var(--accent)}.fm-dot[data-d=blocked],.fm-dot[data-d=call]{background:var(--warn)}
.fm-dot[data-d=failed],.fm-dot[data-d=unknown]{background:var(--bad)}.fm-dot[data-d=done_with_proof]{background:var(--ok)}
.fm-dot[data-d=in_review],.fm-dot[data-d=starting]{background:var(--info)}
.fm-slot[data-live] .fm-dot{animation:sp-bob 1.4s ease-in-out 3}
.fm-banner{display:none;background-repeat:no-repeat}
/* art on, wide: each room card sits on that room's own status panel */
.fm-art-on .fm-slots{position:absolute;inset:0;pointer-events:none}
.fm-art-on .fm-slot{position:absolute;pointer-events:auto}
.fm-art-on .fm-slot-link{font-size:clamp(9px,1.3cqw,15px);line-height:1.25;gap:.15em;padding:.35em .6em;background:var(--bg);
  border:2px solid var(--brass);border-radius:.6em;box-shadow:0 0 .8em rgba(0,0,0,.55)}
.fm-art-on .fm-slot[data-live] .fm-slot-link{border-color:var(--accent)}
.fm-art-on .fm-slot-name{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
.fm-art-on .fm-slot-top{-webkit-line-clamp:1}
/* no art (plain): the prototype's hull outline around a grid of rooms */
.fm-ship:not(.fm-art-on) .fm-slots{display:grid;gap:10px;grid-template-columns:repeat(2,minmax(0,1fr));padding:16px 16px 16px 44px;
  border:3px solid var(--brass);border-radius:160px 22px 22px 160px/110px 22px 22px 110px}
.fm-ship:not(.fm-art-on) .fm-slot[data-station=bridge]{grid-column:1/-1}
.fm-ship:not(.fm-art-on) .fm-slot-link{min-height:96px}
/* Same ambient look as base.css, with two speed fixes. Compositor-only:
   base.css drifts the starfield by background-position and runs the
   scanline by `top`, which repaint (and re-lay-out) every frame. Finite:
   any endless loop keeps Chrome producing 60 frames a second, about 11%
   of a core across its processes for as long as the tab is visible, so
   the motion plays for under a minute after each load (the page reloads
   when the work changes, so it replays as the cue) and then holds still.
   Pauses name the pseudo-elements: animation-play-state does not inherit. */
.fm-art .ship-ambient::before{inset:-300px -400px 0 0;animation-name:fm-starfield;animation-iteration-count:1;will-change:transform}
@keyframes fm-starfield{to{transform:translate(-400px,300px)}}
.fm-art .ship-ambient::after{animation-iteration-count:8;will-change:opacity}
.fm-art .ship-scanline{top:0;animation-name:fm-scan;animation-iteration-count:2;will-change:transform}
@keyframes fm-scan{0%{transform:translateY(-2px);opacity:0}5%{opacity:.05}95%{opacity:.05}100%{transform:translateY(__SCAN__cqw);opacity:0}}
.fm-art.offscreen .ship-ambient::before,.fm-art.offscreen .ship-ambient::after,.fm-art.offscreen .ship-scanline,
html[data-hidden] .ship-ambient::before,html[data-hidden] .ship-ambient::after,html[data-hidden] .fm-dot,
.fm-ship:has(.fm-art.offscreen) .fm-dot{animation-play-state:paused}
.fm-bigshot{background:var(--surface);border:2px solid var(--brass);border-radius:12px;padding:12px;min-width:0}
.fm-bigshot-art{border-radius:8px;border:1px solid var(--border);background-repeat:no-repeat}
.fm-bigshot h2{margin-top:10px}
.fm-intro{font-size:12.5px;color:var(--muted);margin:4px 0 8px}
.fm-tally{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 6px;padding:0;list-style:none}
.fm-bstat{display:inline-flex;gap:5px;align-items:center;font-weight:700;font-size:12px;padding:1px 7px;border-radius:4px;border:2px solid currentColor;white-space:nowrap}
.fm-bstat[data-bounty=open]{color:var(--muted);border-style:dashed}
.fm-bstat[data-bounty=in_progress]{color:var(--accent)}
.fm-bstat[data-bounty=awaiting_evidence]{color:var(--warn);border-style:dashed;border-width:3px}
.fm-bstat[data-bounty=verified]{color:var(--bg);background:var(--ok);border-color:var(--ok)}
.fm-bounty{background:var(--surface-2);border:2px solid var(--border);border-left-width:6px;border-radius:8px;padding:8px 10px;margin:8px 0 0;min-width:0}
.fm-bounty[data-bounty=open]{border-style:dashed}
.fm-bounty[data-bounty=in_progress]{border-color:var(--accent)}
.fm-bounty[data-bounty=awaiting_evidence]{border-color:var(--warn);border-style:dashed}
.fm-bounty[data-bounty=verified]{border-color:var(--ok)}
.fm-bounty h3{margin:0 0 4px;font-size:13.5px;line-height:1.35;word-break:break-word}
.fm-bounty h3 a{color:inherit}
.fm-bline{margin:0 0 4px;font-size:12.5px;line-height:1.5}
.fm-facts{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:1px 10px;margin:0;font-size:12px;line-height:1.45}
.fm-facts dt{color:var(--muted)}.fm-facts dd{margin:0;min-width:0;word-break:break-word}
.fm-facts dd[data-verified=no] strong{color:var(--muted)}
.fm-src{font-size:11.5px;color:var(--muted);margin:4px 0 0}
details.fm-verified{margin-top:10px}
details.fm-verified>summary{cursor:pointer;font-size:12.5px;font-weight:700;color:var(--muted)}
.fm-cargo{display:flex;gap:10px;align-items:center;margin-top:12px;padding:8px;border:1px dashed var(--border);border-radius:8px;font-size:12.5px}
.fm-oldguys{flex:none;width:96px;border-radius:6px;background-repeat:no-repeat}
.fm-callbar{display:flex;flex-wrap:wrap;gap:6px 18px;align-items:baseline;margin:14px 0 0;padding:10px 14px;background:var(--surface);
  border:2px solid var(--brass);border-radius:10px;font-size:13px}
.fm-callbar strong{color:var(--accent);font-size:15px}
.fm-callbar.hot strong{color:var(--warn)}
.fm-callbar .fm-meta{margin-left:auto}
.fm-room{margin-top:6px}
.fm-room>h2 small{text-transform:none;letter-spacing:0;margin-left:6px}
.fm-room>p.dim{margin:0 0 8px;font-size:12.5px}
.fm-decision{background:var(--surface);border:1px solid var(--border);border-left:6px solid var(--accent);border-radius:12px;padding:12px 16px;margin:0 0 14px}
.fm-decision h4{margin:0 0 4px;font-size:14px}
.fm-meta{font-size:12px;color:var(--muted);display:flex;flex-wrap:wrap;gap:4px 12px;align-items:center}
.fm-reason{white-space:pre-wrap;word-break:break-word;margin:8px 0;font-size:13.5px}
.fm-decision form{display:grid;gap:6px;margin-top:8px}
.fm-decision textarea{width:100%;min-height:72px;font:inherit;resize:vertical}
.fm-decision button{justify-self:start;font:600 12px system-ui;padding:5px 12px;border-radius:5px;border:1px solid var(--accent);background:transparent;color:var(--accent);cursor:pointer}
.fm-decision button:hover{background:var(--accent);color:var(--bg)}
.fm-sent{font-size:12.5px;margin:6px 0 0;padding-left:18px}
.fm-howto{font-size:12.5px;color:var(--muted)}
.fm-flash{border:2px solid var(--ok);border-radius:8px;padding:8px 12px;margin:10px 0}
.fm-flash.bad{border-color:var(--bad)}
.crew-badge{display:inline-flex;align-items:center;gap:4px;font-size:11px;color:var(--muted);white-space:nowrap}
.crew-badge::before{content:"";width:9px;height:9px;border-radius:50%;background:var(--c,var(--brass));border:1px solid var(--border)}
td .dim,.fm-detail{font-size:12px;color:var(--muted);word-break:break-word}
.fm-empty{color:var(--muted);font-style:italic}
@media (max-width:__NARROW__px){
  .fm-art{display:none}
  .fm-art-on .fm-slots{position:static;display:grid;gap:12px}
  .fm-art-on .fm-slot{position:static}
  .fm-art-on .fm-banner{display:block;margin:-.55em -.8em .35em}
  .fm-art-on .fm-slot-link{height:auto;font-size:14px;padding:.55em .8em;border-radius:10px;box-shadow:none}
  .fm-art-on .fm-slot-name{position:static;width:auto;height:auto;clip:auto;white-space:normal}
  .fm-art-on .fm-slot-top{-webkit-line-clamp:2}
  .fm-ship:not(.fm-art-on) .fm-slots{grid-template-columns:minmax(0,1fr);padding:8px;border-radius:14px}
  .fm-facts{grid-template-columns:minmax(0,1fr)}
  .fm-callbar .fm-meta{margin-left:0}
  .fm-room table,.fm-room tbody,.fm-room tr,.fm-room td{display:block}
  .fm-room thead{display:none}
  .fm-room td{border-top:0;padding:2px 10px}
  .fm-room tr{border-top:1px solid var(--border);padding:6px 0}
  .fm-room tr:first-child{border-top:0}
}
""".replace("__NARROW__", str(NARROW_PX)).replace("__SCAN__", f"{HULL[3] / HULL[2] * 100:.2f}")

_BOOT = ("(function(){var d=document.documentElement;d.setAttribute('data-js','1');"
         "try{if(localStorage.getItem('fmdash.reduce'))d.setAttribute('data-reduce','1')}catch(e){}})();")
# Reduce-motion toggle (stored per browser), pause ambient motion in a hidden
# tab or with the art scrolled away, and reload when the snapshot changes
# unless an answer is being typed.
_SCRIPT = """(function(){var d=document.documentElement,b=document.getElementById('fm-motion');
function set(r){if(r)d.setAttribute('data-reduce','1');else d.removeAttribute('data-reduce');if(b)b.setAttribute('aria-pressed',r?'true':'false')}
set(d.hasAttribute('data-reduce'));
if(b)b.addEventListener('click',function(){var r=!d.hasAttribute('data-reduce');try{localStorage.setItem('fmdash.reduce',r?'1':'')}catch(e){}set(r)});
document.addEventListener('visibilitychange',function(){if(document.hidden)d.setAttribute('data-hidden','1');else d.removeAttribute('data-hidden')});
var a=document.querySelector('.fm-art');if(a&&window.IntersectionObserver)new IntersectionObserver(function(es){es.forEach(function(e){a.classList.toggle('offscreen',!e.isIntersecting)})}).observe(a);
var fp=%s;if(!fp)return;setInterval(function(){var ta=document.querySelectorAll('textarea');
for(var i=0;i<ta.length;i++){if(ta[i].value.trim()||document.activeElement===ta[i])return}
fetch('/api/summary',{cache:'no-store'}).then(function(r){return r.json()}).then(function(s){
if(s.fingerprint&&s.fingerprint!==fp)location.reload()}).catch(function(){})},15000)})();"""


def esc(s) -> str:
    return html.escape("" if s is None else str(s), quote=True)


def theme_of(query_theme: str | None) -> dict:
    return THEMES.get(query_theme or "", THEMES[DEFAULT_THEME])


def _char(theme: dict, key: str) -> dict:
    return (theme.get("characters") or {}).get(key) or {}


def _badge(theme: dict, kind: str) -> str:
    who = _char(theme, KIND_CREW.get(kind, FALLBACK_CREW))
    if not who:
        return ""
    # First of hair/coat/shirt light enough to read as a dot on the dark palette.
    sprite = who.get("sprite") or {}
    color = next((c for c in (sprite.get("hair_color"), sprite.get("coat"), sprite.get("shirt"))
                  if _HEX.fullmatch(c or "") and _luminance(c) >= 0.07), "")
    style = f" style='--c:{color}'" if color else ""
    return (f"<span class=crew-badge aria-hidden=true{style} title='{esc(who.get('name'))}: {esc(who.get('role'))}'>"
            f"{esc(who.get('name'))}</span>")


def _luminance(hex6: str) -> float:
    def lin(v: int) -> float:
        c = v / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hex6[i:i + 2], 16) for i in (1, 3, 5))
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def contrast(fg: str, bg: str) -> float:
    a, b = sorted((_luminance(fg), _luminance(bg)), reverse=True)
    return (a + 0.05) / (b + 0.05)


def _state(word: str) -> str:
    return f"<span class=st data-d='{STATE_STYLE.get(word, 'unknown')}'>{esc(word)}</span>"


def _links(urls) -> str:
    return " ".join(f"<a href='{esc(u)}' rel=noreferrer>{esc(_short_pr(u))}</a>" for u in urls) or "<span class=dim>—</span>"


def _short_pr(url: str) -> str:
    m = re.search(r"github\.com/[^/]+/([^/]+)/(?:pull|issues)/(\d+)", url)
    return f"{m.group(1)}#{m.group(2)}" if m else url


def _q(theme_id: str, **extra) -> str:
    params = {k: v for k, v in extra.items() if v}
    if theme_id != DEFAULT_THEME:
        params["theme"] = theme_id
    return ("?" + urllib.parse.urlencode(params)) if params else ""


def _plural(n: int, one: str, many: str) -> str:
    return f"{n} {one if n == 1 else many}"


def page(title: str, body: str, theme: dict, nonce: str, fingerprint: str = "") -> str:
    tid = theme["id"]
    switch = " ".join(
        f"<a href='/{_q(t)}'{' aria-current=page' if t == tid else ''}>{esc(THEMES[t].get('name') or t)}</a>"
        for t in sorted(THEMES))
    tagline = esc(theme.get("tagline") or "")
    n = esc(nonce)
    return (f"<!doctype html><html lang=en data-theme='{esc(tid)}'><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            f"<title>{esc(title)}</title><script nonce='{n}'>{_BOOT}</script>"
            f"<style>{hub_ui._theme_css()}{hub_ui.BASE_CSS}{DASH_CSS}{_art_css(theme)}</style></head><body>"
            "<a class=skip href='#main'>Skip to content</a>"
            f"<header><b class='brand fm-brand'>FIRSTMATE{f'<small>{tagline}</small>' if tagline else ''}</b>"
            f"<nav aria-label=Sections><a href='/{_q(tid)}#ship'>Ship</a><a href='/{_q(tid)}#bounties'>Bounties</a>"
            f"<a href='/{_q(tid)}#decisions'>Your calls</a><a href='/{_q(tid)}#rooms'>Rooms</a></nav>"
            f"<span class='dim hdr-meta'>read-only · theme: {switch} · <a href='/api/summary'>json</a></span>"
            "<button type=button id=fm-motion class=fm-motion aria-pressed=false>Reduce motion</button></header>"
            f"<main id=main tabindex=-1>{body}</main>"
            f"<script nonce='{n}'>{_SCRIPT % json.dumps(fingerprint)}</script></body></html>")


# ── rooms ─────────────────────────────────────────────────────────────────────
def _room_names(theme: dict, st: dict) -> tuple[str, str]:
    """(heading, crew line). Plain themes name rooms by label only."""
    place = ((theme.get("stations") or {}).get(st["id"]) or {}).get("place") or st["label"]
    who = _char(theme, KIND_CREW.get(st["kinds"][0]) if st["kinds"] else FALLBACK_CREW)
    return place, (f"{who.get('name')} · {who.get('role')}" if who else "")


def _rooms(snap: dict) -> tuple[dict, list[dict]]:
    by = {st["id"]: [] for st in STATIONS}
    cargo = []
    for t in snap.get("in_flight", []):
        st = _STATION_OF.get(t["kind"])
        (by[st["id"]] if st else cargo).append(t)
    return by, cargo


def _slot(theme: dict, st: dict, tasks: list[dict], calls: list[dict], art: bool, tid: str) -> str:
    name, crew = _room_names(theme, st)
    live = any(t["crew"]["state"] == "working" for t in tasks)
    hot = bool(calls) or any(t["attention"] for t in tasks)
    sums = ([_plural(len(calls), "call for you", "calls for you")] if calls else []) \
        + ([_plural(len(tasks), "crew", "crews")] if tasks else [])
    ranked = sorted(tasks, key=lambda t: (not t["attention"], t["crew"]["state"] != "working"))
    if calls:
        top, dot, word = calls[0]["title"], "call", "waiting on you"
    elif ranked:
        top, word = ranked[0]["title"], ranked[0]["crew"]["state"]
        dot = STATE_STYLE.get(word, "unknown")
    else:
        top, dot, word = "No crew here right now.", "quiet", "quiet"
    return (f"<li class=fm-slot data-station='{st['id']}'{' data-live' if live else ''}{' data-hot' if hot else ''}>"
            f"<a class=fm-slot-link href='/{_q(tid)}#room-{st['id']}'>"
            + (f"<span class=fm-banner data-station='{st['id']}' aria-hidden=true></span>" if art else "")
            + f"<span class=fm-slot-name>{esc(name)}{f'<small class=dim>{esc(crew)}</small>' if crew else ''}</span>"
            f"<span class=fm-slot-sum>{esc(' · '.join(sums) or 'Quiet')}</span>"
            f"<span class=fm-slot-top>{esc(top)}</span>"
            f"<span class=fm-slot-state><span class=fm-dot data-d='{dot}' aria-hidden=true></span>{esc(word)}</span></a></li>")


def _crew_table(theme: dict, tasks: list[dict]) -> str:
    if not tasks:
        return "<p class=fm-empty>No crew here right now.</p>"
    rows = "".join(
        f"<tr id='t-{esc(t['id'])}'><td>{_badge(theme, t['kind'])}</td><td><b>{esc(t['title'])}</b><div class=dim><code>{esc(t['id'])}</code>"
        f" · {esc(t['repo'])} · {esc(t['kind'])}{(' · ' + esc(t['mode'])) if t['mode'] else ''}</div></td>"
        f"<td>{_state(t['crew']['state'])}<div class=fm-detail>{esc(t['crew']['detail'])}</div></td>"
        f"<td>{_links(t['prs'])}</td><td class=dim>{esc(t['window'])}</td></tr>"
        for t in tasks)
    return ("<table><thead><tr><th><span class=sr-only>Crew</span></th><th>Task</th><th>State</th><th>PR</th><th>Window</th></tr></thead>"
            f"<tbody>{rows}</tbody></table>")


def _decisions(snap: dict, theme: dict, token: str) -> str:
    tid = theme["id"]
    ds = snap.get("decisions", [])
    out = [f"<h3 id=decisions>Your calls ({len(ds)})</h3>"]
    if not ds:
        out.append("<p class=fm-empty>Nothing is waiting on you.</p>")
    for d in ds:
        reports = " ".join(f"<a href='/report{_q(tid, path=r)}'>{esc(r)}</a>" for r in d["reports"])
        sent = "".join(
            f"<li>sent as inbox note <code>{esc(a['note'])}</code> {esc(a['at'])} · "
            f"{'picked up by Firstmate' if a['acknowledged'] else 'waiting for Firstmate'}"
            f"{' · reply: ' + esc(a['reply']) if a.get('reply') else ''}</li>" for a in d.get("answers", []))
        origin = f"<span>from {esc(d['origin'])}</span>" if d.get("origin") else ""
        out.append(
            f"<article class=fm-decision id='d-{esc(d['id'])}' data-decision='{esc(d['id'])}'>"
            f"<h4>{esc(d['title'])}</h4><div class=fm-meta>{_badge(theme, d['kind'])}<code>{esc(d['id'])}</code>"
            f"<span>{esc(d['repo'])}</span>{origin}"
            f"<span>held {esc(d['created'])}</span></div>"
            f"<p class=fm-reason>{esc(d['reason'])}</p>"
            + (f"<div class=fm-meta>Report: {reports}</div>" if reports else "")
            + (f"<ul class=fm-sent>{sent}</ul>" if sent else "")
            + f"<form method=post action='/answer'><input type=hidden name=token value='{esc(token)}'>"
            f"<input type=hidden name=decision value='{esc(d['id'])}'><input type=hidden name=digest value='{esc(d['digest'])}'>"
            f"<input type=hidden name=theme value='{esc(tid)}'>"
            f"<label class=sr-only for='a-{esc(d['id'])}'>Your answer to {esc(d['title'])}</label>"
            f"<textarea id='a-{esc(d['id'])}' name=text maxlength={MAX_ANSWER_CHARS} required "
            "placeholder='Your answer. It becomes a note in the Firstmate inbox naming this decision; nothing runs from this page.'></textarea>"
            "<button type=submit>Send to Firstmate inbox</button></form></article>")
    out.append("<p class=fm-howto>Typing an answer adds a note to Firstmate's captain inbox (<code>fm-inbox.sh note</code>) "
               "naming the decision; Firstmate reads it and acts. An answer is tied to the decision text you saw: if that "
               "text changed, the page asks you to look again. This page merges, approves, starts and runs nothing.</p>")
    return "".join(out)


# ── Big Shot's bounty board ───────────────────────────────────────────────────
def _href(tid: str, ref: str) -> str:
    if ref.startswith("#"):
        return f"/{_q(tid)}{ref}"
    return ref if ref.startswith("https://") else ""


def _bounty(b: dict, theme: dict, tid: str) -> str:
    icon, label = BOUNTY_LABEL[b["status"]]
    href = _href(tid, b["href"])
    title = f"<a href='{esc(href)}'>{esc(b['objective'])}</a>" if href else esc(b["objective"])
    proof = b.get("proof") or {}
    if b["status"] == "verified" and proof.get("kind") == "pr":
        done = f"<strong>Verified</strong>: merged PR <a href='{esc(proof['ref'])}' rel=noreferrer>{esc(_short_pr(proof['ref']))}</a> on record"
    elif b["status"] == "verified" and proof.get("kind") == "report":
        done = f"<strong>Verified</strong>: report <a href='/report{_q(tid, path=proof['ref'])}'>{esc(proof['ref'])}</a> on record"
    else:
        done = "<strong>NOT verified</strong>: no merged PR or report on record"
    alert = (f" · alert <a href='{esc(proof['ref'])}' rel=noreferrer>{esc(_short_pr(proof['ref']))}</a>"
             if proof.get("kind") == "issue" and proof.get("ref", "").startswith("https://") else "")
    owner = esc(b["owner"]) + (f" · {esc(b['kind'])} work" if b["kind"] else "")
    return (f"<article class=fm-bounty id='b-{esc(b['id'])}' data-bounty='{b['status']}'>"
            f"<h3>{title}</h3>"
            f"<p class=fm-bline><span class=fm-bstat data-bounty='{b['status']}'><span aria-hidden=true>{icon}</span> {label}</span> "
            f"{esc(b['note'])}</p><dl class=fm-facts>"
            f"<dt>Owner</dt><dd>{_badge(theme, b['kind']) if b['kind'] else ''} {owner} · {esc(b['source'])} "
            f"<code>{esc(b['id'])}</code>{alert}</dd>"
            f"<dt>Evidence needed</dt><dd>{esc(b['evidence'])}</dd>"
            f"<dt>Verified completion</dt><dd data-verified='{'yes' if b['status'] == 'verified' else 'no'}'>{done}</dd></dl></article>")


def _bigshot(snap: dict, theme: dict, cargo: list[dict]) -> str:
    tid = theme["id"]
    board = snap.get("bounties", [])
    tally = {s: sum(1 for b in board if b["status"] == s) for s in BOUNTY_LABEL}
    host = _char(theme, "bigshot")
    out = ["<aside id=bounties class=fm-bigshot aria-labelledby=bounties-h>"]
    if theme.get("ship_image"):
        out.append(f"<div class=fm-bigshot-art role=img aria-label='{esc((host.get('name') or 'Big Shot') + ' bounty board')}'></div>")
    out.append("<h2 id=bounties-h>Bounty board</h2>"
               "<p class=fm-intro>Firstmate work outside the crew rooms, and the evidence that closes it. "
               "No money, rewards, points or revenue; a card reads Verified only when a merged PR or report is on record.</p>"
               "<ul class=fm-tally aria-label='Bounties by status'>"
               + "".join(f"<li><span class=fm-bstat data-bounty='{s}'><span aria-hidden=true>{BOUNTY_LABEL[s][0]}</span> "
                         f"{BOUNTY_LABEL[s][1]} {tally[s]}</span></li>" for s in BOUNTY_LABEL) + "</ul>")
    active = [b for b in board if b["status"] != "verified"]
    verified = [b for b in board if b["status"] == "verified"]
    out.append("".join(_bounty(b, theme, tid) for b in active) if active
               else "<p class=fm-empty>No open bounties.</p>")
    if verified:
        out.append(f"<details class=fm-verified><summary>Verified ({len(verified)})</summary>"
                   + "".join(_bounty(b, theme, tid) for b in verified) + "</details>")
    if cargo:
        guys = _char(theme, FALLBACK_CREW)
        out.append("<div class=fm-cargo>" + ("<div class=fm-oldguys aria-hidden=true></div>" if theme.get("ship_image") else "")
                   + f"<p><b>{esc(guys.get('name') or CARGO['label'])}</b>: {_plural(len(cargo), 'crew', 'crews')} of a kind no room "
                   f"claims. <a href='/{_q(tid)}#room-cargo'>See the cargo hold</a></p></div>")
    out.append("</aside>")
    return "".join(out)


def dashboard(snap: dict, theme: dict, token: str, nonce: str, flash: str = "", flash_bad: bool = False) -> str:
    tid = theme["id"]
    art = bool(theme.get("ship_image"))
    c = snap.get("counts", {})
    parts = []
    if flash:
        parts.append(f"<p class='fm-flash{' bad' if flash_bad else ''}' role=status>{esc(flash)}</p>")
    for e in snap.get("errors", []):
        parts.append(f"<p class='fm-flash bad' role=alert>Read problem: {esc(e)}</p>")
    by, cargo = _rooms(snap)
    calls = snap.get("decisions", [])
    slots = "".join(_slot(theme, st, by[st["id"]], calls if st["id"] == "bridge" else [], art, tid) for st in STATIONS)
    ship_label = f"{theme.get('name') or 'Ship'} cutaway: " + ", ".join(_room_names(theme, st)[0] for st in STATIONS)
    n_calls = c.get("open_decisions", 0)
    callbar = (
        f"<p class='fm-callbar{' hot' if n_calls else ''}'><span>Needs your call: <strong>{esc(n_calls)}</strong></span>"
        f"<a href='/{_q(tid)}#decisions'>Answer on the Bridge</a>"
        f"<span>{esc(_plural(c.get('attention_tasks', 0), 'crew needs', 'crews need'))} a look · "
        f"{esc(c.get('in_flight', 0))} in flight · {esc(c.get('queued', 0))} queued</span>"
        f"<span class='dim fm-meta'>as of {esc(snap.get('generated'))} · <a href='/{_q(tid)}'>refresh</a></span></p>")

    def room(st: dict, tasks: list[dict]) -> str:
        name, crew = _room_names(theme, st)
        return (f"<section class=fm-room id='room-{st['id']}' aria-labelledby='rh-{st['id']}'>"
                f"<h2 id='rh-{st['id']}'>{esc(name)}{f'<small>{esc(crew)}</small>' if crew else ''}</h2>"
                f"<p class=dim>{esc(st['what'])}</p>"
                + (_decisions(snap, theme, token) + "<h3>Captain-kind crews</h3>" if st["id"] == "bridge" else "")
                + _crew_table(theme, tasks) + "</section>")

    # The Bridge (your calls) sits right under the ship; Big Shot's screen
    # runs beside both; the other rooms' full crew lists follow.
    parts.append(
        "<section id=ship class=fm-stage aria-label=Ship><div class=fm-deck>"
        f"<div class='fm-ship{' fm-art-on' if art else ''}'>"
        + (f"<div class=fm-art role=img aria-label='{esc(ship_label)}'>"
           "<div class=ship-ambient aria-hidden=true></div><div class=ship-scanline aria-hidden=true></div></div>" if art else "")
        + f"<ol class=fm-slots aria-label='Rooms, live'>{slots}</ol></div>"
        + callbar + room(STATIONS[0], by["bridge"]) + "</div>"
        + _bigshot(snap, theme, cargo) + "</section>")
    parts.append("<section id=rooms aria-label='Crew rooms'>"
                 + "".join(room(st, by[st["id"]]) for st in STATIONS[1:])
                 + (room(CARGO, cargo) if cargo else "") + "</section>"
                 f"<p class=dim>Firstmate home <code>{esc(snap.get('home'))}</code></p>")
    return page("Firstmate", "".join(parts), theme, nonce, snap.get("fingerprint", ""))


def report(rel: str, text: str, theme: dict, nonce: str) -> str:
    body = (f"<p><a href='/{_q(theme['id'])}#decisions'>&larr; back to the ship</a></p>"
            f"<h2>{esc(rel)}</h2><pre>{esc(text)}</pre>")
    return page(f"Report · {rel}", body, theme, nonce)


def message(title: str, text: str, theme: dict, nonce: str) -> str:
    return page(title, f"<p class='fm-flash bad' role=alert>{esc(text)}</p><p><a href='/{_q(theme['id'])}'>Back</a></p>", theme, nonce)
