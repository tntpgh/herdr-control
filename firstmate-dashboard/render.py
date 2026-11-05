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
   the motion plays for under a minute after each load (the page redraws
   the ship when the work changes, so it replays as the cue) and then holds still.
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
.fm-decision[data-answered]{border-left-color:var(--info)}
.fm-decision h4{margin:0 0 4px;font-size:14px}
.fm-meta{font-size:12px;color:var(--muted);display:flex;flex-wrap:wrap;gap:4px 12px;align-items:center}
.fm-chip{font-weight:700;font-size:11px;padding:0 6px;border-radius:4px;border:1px solid currentColor;color:var(--info)}
.fm-chip[data-s=earlier]{color:var(--warn)}
.fm-reason{white-space:pre-wrap;word-break:break-word;margin:8px 0;font-size:13.5px}
.fm-decision form{display:grid;gap:6px;margin-top:8px}
.fm-decision textarea{width:100%;min-height:72px;font:inherit;resize:vertical}
.fm-act{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center}
.fm-decision button{justify-self:start;font:600 12px system-ui;padding:5px 12px;border-radius:5px;border:1px solid var(--accent);background:transparent;color:var(--accent);cursor:pointer}
.fm-decision button:hover{background:var(--accent);color:var(--bg)}
.fm-decision form[data-busy] button{cursor:progress;background:transparent;color:var(--accent)}
.fm-decision form[data-busy] button::before{content:"";display:inline-block;width:.8em;height:.8em;margin-right:6px;vertical-align:-1px;
  border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:fm-spin .7s linear infinite}
@keyframes fm-spin{to{transform:rotate(1turn)}}
.fm-hint,.fm-count{font-size:11.5px;color:var(--muted)}
.fm-count{margin-left:auto;font-variant-numeric:tabular-nums}
.fm-count[data-near]{color:var(--warn);font-weight:700}
.fm-sent{font-size:12.5px;margin:6px 0 0;padding-left:18px}
.fm-howto{font-size:12.5px;color:var(--muted)}
.fm-flash{border:2px solid var(--ok);border-radius:8px;padding:8px 12px;margin:10px 0}
.fm-flash.bad{border-color:var(--bad)}
.crew-badge{display:inline-flex;align-items:center;gap:4px;font-size:11px;color:var(--muted);white-space:nowrap}
.crew-badge::before{content:"";width:9px;height:9px;border-radius:50%;background:var(--c,var(--brass));border:1px solid var(--border)}
td .dim,.fm-detail{font-size:12px;color:var(--muted);word-break:break-word}
.fm-room tr[data-attn]>td:first-child{box-shadow:inset 4px 0 var(--warn)}
.fm-empty{color:var(--muted);font-style:italic}
.fm-unknown{color:var(--warn);font-style:normal;font-weight:600}
/* header: section counts, filter, live indicator. The filter and the live
   indicator need the script, so they are not drawn without it. */
.fm-n{display:inline-block;min-width:1.5em;margin-left:4px;padding:0 5px;border-radius:9px;background:var(--surface-2);
  color:var(--fg);font-size:11px;font-weight:700;text-align:center;font-variant-numeric:tabular-nums}
.fm-n[data-hot]{background:var(--warn);color:var(--bg)}
.fm-find{display:inline-flex;align-items:center;gap:6px}
.fm-find input{width:16em;font:13px system-ui;padding:3px 8px}
.fm-find kbd{font:11px ui-monospace,monospace;color:var(--muted);border:1px solid var(--border);border-radius:4px;padding:0 5px}
.fm-find-n{font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}
.fm-live{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--muted);white-space:nowrap}
.fm-live-dot{position:relative;flex:none;width:8px;height:8px;border-radius:50%;background:var(--ok)}
.fm-live-dot::after{content:"";position:absolute;inset:0;border-radius:50%;background:inherit;opacity:0}
.fm-live.p0 .fm-live-dot::after{animation:fm-ping0 .9s ease-out 1}
.fm-live.p1 .fm-live-dot::after{animation:fm-ping1 .9s ease-out 1}
@keyframes fm-ping0{from{opacity:.7;transform:scale(1)}to{opacity:0;transform:scale(2.8)}}
@keyframes fm-ping1{from{opacity:.7;transform:scale(1)}to{opacity:0;transform:scale(2.8)}}
.fm-live[data-s=wait] .fm-live-dot{background:var(--info)}.fm-live[data-s=wait] .fm-live-txt{color:var(--info)}
.fm-live[data-s=warn] .fm-live-dot{background:var(--warn)}.fm-live[data-s=warn] .fm-live-txt{color:var(--warn);font-weight:700}
.fm-live[data-s=bad] .fm-live-dot{background:var(--bad)}.fm-live[data-s=bad] .fm-live-txt{color:var(--bad);font-weight:700}
html[data-live=warn] .fm-callbar time,html[data-live=bad] .fm-callbar time{color:var(--warn);font-weight:700}
html:not([data-js]) .fm-find,html:not([data-js]) .fm-live,html:not([data-js]) .fm-js{display:none}
.fm-out{display:none!important}
button.fm-bstat{font:700 12px system-ui;background:none;cursor:pointer}
button.fm-bstat:disabled{cursor:default}
button.fm-bstat[aria-pressed=true]{box-shadow:0 0 0 2px var(--bg),0 0 0 4px currentColor}
button.fm-bstat[data-bounty=verified][aria-pressed=true]{box-shadow:0 0 0 2px var(--bg),0 0 0 4px var(--ok)}
/* live update: what changed glows once, what is new slides in once; a
   jump target glows the same way. One-shot, so nothing runs at idle, and
   base.css's reduce-motion switch stops all of it. */
@keyframes fm-hl{from{box-shadow:0 0 0 3px var(--accent),0 0 18px color-mix(in srgb,var(--accent) 45%,transparent)}
  to{box-shadow:0 0 0 3px transparent,0 0 18px transparent}}
@keyframes fm-hl-row{from{background-color:color-mix(in srgb,var(--accent) 24%,transparent)}to{background-color:transparent}}
@keyframes fm-hl-in{from{opacity:0;transform:translateY(-4px)}to{opacity:1;transform:none}}
.fm-decision.fm-changed,.fm-bounty.fm-changed,.fm-callbar.fm-changed,.fm-slot.fm-changed>.fm-slot-link,
.fm-decision:target,.fm-bounty:target{animation:fm-hl 1.8s ease-out 1}
.fm-decision.fm-new,.fm-bounty.fm-new,.fm-slot.fm-new>.fm-slot-link{animation:fm-hl 1.8s ease-out 1,fm-hl-in .35s ease-out 1}
tr.fm-changed>td,tr.fm-new>td,tr:target>td,.fm-room:target>h2{animation:fm-hl-row 1.8s ease-out 1}
@media (prefers-reduced-motion:no-preference){html:not([data-reduce]){scroll-behavior:smooth}}
@media (min-width:__WIDE__px){body>header{position:sticky;top:0;z-index:20}main [id]{scroll-margin-top:96px}}
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
  .fm-find{flex:1 1 100%}
  .fm-find input{flex:1;width:auto}
  .fm-hint,.fm-find kbd{display:none}
}
""".replace("__NARROW__", str(NARROW_PX)).replace("__WIDE__", str(NARROW_PX + 1)).replace(
    "__SCAN__", f"{HULL[3] / HULL[2] * 100:.2f}")

_BOOT = ("(function(){var d=document.documentElement;d.setAttribute('data-js','1');"
         "try{if(localStorage.getItem('fmdash.reduce'))d.setAttribute('data-reduce','1')}catch(e){}})();")
# Every page: the reduce-motion toggle (stored per browser), pausing ambient
# motion in a hidden tab or with the art scrolled away, relative ages on
# <time>, the filter (`/` focuses it, Esc clears), the bounty status chips,
# and the answer form's busy state, length counter and Cmd/Ctrl+Enter.
# The ship page (C.live) also polls /api/summary every C.poll seconds; the
# header says live / update waiting / data old / read failing / offline, and
# a new fingerprint swaps <main> in place (open <details>, filter and focus
# kept) and marks what changed. It never swaps under an answer being
# written: a decision's text must not change under the captain's reply.
# No timer but the poll; every animation is one-shot.
_SCRIPT = r"""(function(){var d=document.documentElement,C=__CFG__,b=document.getElementById('fm-motion');
function $(s,r){return (r||document).querySelector(s)}
function $$(s,r){return Array.prototype.slice.call((r||document).querySelectorAll(s))}
var KEY='.fm-slot[id],.fm-decision[id],.fm-bounty[id],.fm-room tr[id],#fm-callbar';
function sig(e){return e.outerHTML.replace(/<time\b[^>]*>[^<]*<\/time>/g,'')}
function collect(r){var m={};$$(KEY,r).forEach(function(e){m[e.id]=sig(e)});return m}
var sigs=collect(document);
function set(r){if(r)d.setAttribute('data-reduce','1');else d.removeAttribute('data-reduce');if(b)b.setAttribute('aria-pressed',r?'true':'false')}
set(d.hasAttribute('data-reduce'));
if(b)b.addEventListener('click',function(){var r=!d.hasAttribute('data-reduce');try{localStorage.setItem('fmdash.reduce',r?'1':'')}catch(e){}set(r)});
var io=window.IntersectionObserver?new IntersectionObserver(function(es){es.forEach(function(e){e.target.classList.toggle('offscreen',!e.isIntersecting)})}):null;
function watchArt(){if(!io)return;io.disconnect();var a=$('.fm-art');if(a)io.observe(a)}
watchArt();
function rel(iso){var t=Date.parse(iso);if(isNaN(t))return '';var s=(Date.now()-t)/1000;if(s<45)return 'just now';
var m=Math.round(s/60);if(m<60)return m+'m ago';var h=Math.round(m/60);return h<48?h+'h ago':Math.round(h/24)+'d ago'}
function times(r){$$('time[datetime]',r).forEach(function(e){var iso=e.getAttribute('datetime'),x=rel(iso);if(!x)return;
var t=new Date(iso).toLocaleString();if(e.textContent!==x)e.textContent=x;if(e.title!==t)e.title=t})}
var q='',bs='',auto=false,fi=$('#fm-find'),fn=$('#fm-find-n');
function apply(){var n=0;$$('.fm-decision,.fm-bounty,.fm-room tbody tr').forEach(function(e){
var hit=!q||e.textContent.toLowerCase().indexOf(q)>=0;if(q&&hit)n++;
if(bs&&e.classList.contains('fm-bounty')&&e.getAttribute('data-bounty')!==bs)hit=false;e.classList.toggle('fm-out',!hit)});
$$('.fm-room table').forEach(function(t){t.classList.toggle('fm-out',!!q&&!$('tbody tr:not(.fm-out)',t))});
var v=$('#fm-verified');if(v){var want=!!(q||bs)&&!!$('.fm-bounty:not(.fm-out)',v);
if(want&&!v.open){v.open=true;auto=true}else if(!want&&auto){v.open=false;auto=false}}
if(fn)fn.textContent=q?n+(n===1?' match':' matches'):'';
$$('.fm-tally button').forEach(function(x){x.disabled=false;x.setAttribute('aria-pressed',x.getAttribute('data-bounty')===bs?'true':'false')})}
function count(t){var c=t.form&&$('.fm-count',t.form);if(!c)return;var n=t.value.length;
c.textContent=n?n+' / '+t.maxLength:'';if(n>t.maxLength*0.9)c.setAttribute('data-near','');else c.removeAttribute('data-near')}
document.addEventListener('input',function(e){var t=e.target;if(t===fi){q=t.value.trim().toLowerCase();apply()}
else if(t.matches('.fm-decision textarea'))count(t)});
document.addEventListener('keydown',function(e){var t=e.target,tag=t.tagName;
if(e.key==='/'&&fi&&!e.metaKey&&!e.ctrlKey&&!e.altKey&&tag!=='INPUT'&&tag!=='TEXTAREA'&&!t.isContentEditable){e.preventDefault();fi.focus();fi.select()}
else if(e.key==='Escape'&&t===fi){fi.value='';q='';apply();fi.blur()}
else if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)&&tag==='TEXTAREA'&&t.form){e.preventDefault();t.form.requestSubmit()}});
document.addEventListener('click',function(e){var x=e.target.closest&&e.target.closest('.fm-tally button');if(!x)return;
var s=x.getAttribute('data-bounty');bs=bs===s?'':s;apply()});
document.addEventListener('submit',function(e){var f=e.target;if(!f.closest('.fm-decision'))return;
if(f.hasAttribute('data-busy')){e.preventDefault();return}
f.setAttribute('data-busy','');f.setAttribute('aria-busy','true');var x=$('button[type=submit]',f);if(x)x.textContent='Sending\u2026'});
document.addEventListener('animationend',function(e){if(e.animationName.indexOf('fm-hl')!==0)return;
var k=e.target.closest('.fm-changed,.fm-new');if(k)k.classList.remove('fm-changed','fm-new')});
document.addEventListener('visibilitychange',function(){if(document.hidden)d.setAttribute('data-hidden','1');
else{d.removeAttribute('data-hidden');if(C.live)tick()}});
if(/[?&](sent|err)=/.test(location.search)){var u=new URL(location.href);u.searchParams.delete('sent');u.searchParams.delete('err');
history.replaceState(null,'',u.pathname+u.search+u.hash)}
times(document);apply();$$('.fm-decision textarea').forEach(count);
if(!C.live)return;
var fp=C.fp,busy=false,ph=0,live=$('#fm-live'),say1=$('#fm-announce'),state=live?live.getAttribute('data-s'):'ok';
d.setAttribute('data-live',state);
function typing(){return $$('.fm-decision textarea').some(function(t){return t.value.trim()||document.activeElement===t})}
function say(s,txt,tip){if(!live)return;live.setAttribute('data-s',s);d.setAttribute('data-live',s);
$('.fm-live-txt',live).textContent=txt;live.title=tip;if(s!==state&&say1)say1.textContent='Dashboard: '+txt+'. '+tip;state=s}
function tick(){fetch('/api/summary',{cache:'no-store'}).then(function(r){return r.json()}).then(function(s){
if(!s.ok){say('bad','read failing',s.error||'The last read of the Firstmate home failed.');return}
var g=$('#fm-callbar time');if(g)g.setAttribute('datetime',s.generated);
var change=!!s.fingerprint&&s.fingerprint!==fp,wait=change&&typing();
if(Date.now()-Date.parse(s.generated)>C.stale*1000)say('warn','data '+rel(s.generated).replace(' ago','')+' old',
'No read of the Firstmate home has finished since '+new Date(s.generated).toLocaleTimeString()+'.');
else if(wait)say('wait','update waiting','The fleet changed. The page holds still while you write an answer: send or clear it to update.');
else say('ok','live','Read '+rel(s.generated)+'; checked every '+C.poll+'s.');
if(change&&!wait)swap(s.fingerprint);times(document)
}).catch(function(){say('bad','offline','The dashboard server is not answering; this is the last data it sent.')})}
function swap(nfp){if(busy)return;busy=true;fetch(location.pathname+location.search,{cache:'no-store'}).then(function(r){
if(!r.ok)throw new Error(r.status);return r.text()}).then(function(t){if(typing())return;
var doc=new DOMParser().parseFromString(t,'text/html'),nm=doc.getElementById('main'),main=$('#main');if(!nm||!main)return;
var ns=collect(doc),hot=Object.keys(ns).filter(function(k){return ns[k]!==sigs[k]});
var open=$$('details[open][id]',main).map(function(e){return e.id});
var ae=document.activeElement,fid=ae&&ae!==main&&main.contains(ae)?ae.id:'';
main.innerHTML=nm.innerHTML;var nav=doc.getElementById('fm-nav'),on=$('#fm-nav');if(nav&&on)on.innerHTML=nav.innerHTML;
document.title=doc.title;fp=nfp;
open.forEach(function(i){var e=document.getElementById(i);if(e)e.open=true});
if(fid){var f=document.getElementById(fid);if(f)f.focus({preventScroll:true})}
hot.forEach(function(k){var e=document.getElementById(k);if(e)e.classList.add(k in sigs?'fm-changed':'fm-new')});
sigs=ns;apply();times(main);watchArt();
if(hot.length){ph=1-ph;live.classList.remove('p0','p1');live.classList.add('p'+ph);
if(say1)say1.textContent='Dashboard updated: '+hot.length+(hot.length===1?' item changed.':' items changed.')}
}).catch(function(){}).then(function(){busy=false})}
setInterval(tick,C.poll*1000)})();"""
POLL_S = 15
STALE_S = 90


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


def _time(iso: str | None) -> str:
    """An instant, as its ISO text; the page script rewrites it as an age ("3m ago")."""
    return f"<time datetime='{esc(iso)}'>{esc(iso)}</time>" if iso else ""


def page(title: str, body: str, theme: dict, nonce: str, live: dict | None = None) -> str:
    """`live` (the ship page only): {"ok", "fp", "nav": {"decisions"|"bounties"|"rooms": (n, hot)}}.
    It turns on the poll, the filter and the live indicator, and puts counts in the nav."""
    tid = theme["id"]
    switch = " ".join(
        f"<a href='/{_q(t)}'{' aria-current=page' if t == tid else ''}>{esc(THEMES[t].get('name') or t)}</a>"
        for t in sorted(THEMES))
    tagline = esc(theme.get("tagline") or "")
    n = esc(nonce)
    counts = (live or {}).get("nav", {})

    def nav(anchor: str, label: str, key: str = "") -> str:
        c = counts.get(key)
        badge = (f" <span class=fm-n{' data-hot' if c[1] else ''}>{esc(c[0])}</span>" if c else "")
        return f"<a href='/{_q(tid)}#{anchor}'>{label}{badge}</a>"

    tools = ("<label class=fm-find><span class=sr-only>Filter calls, crews and bounties</span>"
             "<input type=search id=fm-find autocomplete=off spellcheck=false placeholder='Filter: id, repo, title'>"
             "<kbd aria-hidden=true>/</kbd><span id=fm-find-n class=fm-find-n aria-live=polite></span></label>"
             f"<span id=fm-live class=fm-live data-s={'ok' if live.get('ok') else 'bad'}><span class=fm-live-dot aria-hidden=true></span>"
             f"<span class=fm-live-txt>{'live' if live.get('ok') else 'read failing'}</span></span>") if live else ""
    cfg = json.dumps({"live": bool(live), "fp": (live or {}).get("fp", ""), "poll": POLL_S, "stale": STALE_S})
    return (f"<!doctype html><html lang=en data-theme='{esc(tid)}'><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            f"<title>{esc(title)}</title><script nonce='{n}'>{_BOOT}</script>"
            f"<style>{hub_ui._theme_css()}{hub_ui.BASE_CSS}{DASH_CSS}{_art_css(theme)}</style></head><body>"
            "<a class=skip href='#main'>Skip to content</a>"
            f"<header><b class='brand fm-brand'>FIRSTMATE{f'<small>{tagline}</small>' if tagline else ''}</b>"
            f"<nav id=fm-nav aria-label=Sections>{nav('ship', 'Ship')}{nav('decisions', 'Your calls', 'decisions')}"
            f"{nav('rooms', 'Rooms', 'rooms')}{nav('bounties', 'Bounties', 'bounties')}</nav>{tools}"
            f"<span class='dim hdr-meta'>read-only · theme: {switch} · <a href='/api/summary'>json</a></span>"
            "<button type=button id=fm-motion class=fm-motion aria-pressed=false>Reduce motion</button></header>"
            f"<main id=main tabindex=-1>{body}</main><p id=fm-announce class=sr-only role=status aria-live=polite></p>"
            f"<script nonce='{n}'>{_SCRIPT.replace('__CFG__', cfg)}</script></body></html>")


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


UNKNOWN = "Unknown: the last read of the Firstmate home failed."


def _answer_state(d: dict) -> str:
    """"current" when this dashboard sent an answer bound to the decision text
    shown now, "earlier" when only to an earlier text, else ""."""
    answers = d.get("answers") or []
    if any(a.get("digest8") == d["digest"][:8] for a in answers):
        return "current"
    return "earlier" if answers else ""


def _needs_you(calls: list[dict]) -> list[dict]:
    return [d for d in calls if _answer_state(d) != "current"]


def _slot(theme: dict, st: dict, tasks: list[dict], calls: list[dict], art: bool, tid: str, ok: bool = True) -> str:
    name, crew = _room_names(theme, st)
    live = any(t["crew"]["state"] == "working" for t in tasks)
    needs = _needs_you(calls)
    hot = bool(needs) or any(t["attention"] for t in tasks)
    sums = ([_plural(len(needs), "call for you", "calls for you")] if needs else []) \
        + ([f"{len(calls) - len(needs)} answered"] if len(calls) > len(needs) else []) \
        + ([_plural(len(tasks), "crew", "crews")] if tasks else [])
    ranked = sorted(tasks, key=lambda t: (not t["attention"], t["crew"]["state"] != "working"))
    if not ok:
        top, dot, word = "The last read failed.", "unknown", "unknown"
    elif needs:
        top, dot, word = needs[0]["title"], "call", "waiting on you"
    elif calls:
        top, dot, word = calls[0]["title"], "in_review", "answered · Firstmate to act"
    elif ranked:
        top, word = ranked[0]["title"], ranked[0]["crew"]["state"]
        dot = STATE_STYLE.get(word, "unknown")
    else:
        top, dot, word = "No crew here right now.", "quiet", "quiet"
    return (f"<li class=fm-slot data-station='{st['id']}'{' data-live' if live else ''}{' data-hot' if hot else ''}"
            f" id='slot-{st['id']}'><a class=fm-slot-link href='/{_q(tid)}#room-{st['id']}'>"
            + (f"<span class=fm-banner data-station='{st['id']}' aria-hidden=true></span>" if art else "")
            + f"<span class=fm-slot-name>{esc(name)}{f'<small class=dim>{esc(crew)}</small>' if crew else ''}</span>"
            f"<span class=fm-slot-sum>{esc(' · '.join(sums) or ('Quiet' if ok else 'Unknown'))}</span>"
            f"<span class=fm-slot-top>{esc(top)}</span>"
            f"<span class=fm-slot-state><span class=fm-dot data-d='{dot}' aria-hidden=true></span>{esc(word)}</span></a></li>")


def _empty(text: str, ok: bool) -> str:
    return f"<p class=fm-empty>{esc(text)}</p>" if ok else f"<p class='fm-empty fm-unknown'>{esc(UNKNOWN)}</p>"


def _crew_table(theme: dict, tasks: list[dict], ok: bool = True) -> str:
    if not tasks:
        return _empty("No crew here right now.", ok)

    def when(t: dict) -> str:
        parts = ([f"last report {_time(t['updated_at'])}"] if t.get("updated_at") else []) \
            + ([f"state read {_time(t['crew']['observed_at'])}"] if t["crew"].get("observed_at") else [])
        return f"<div class=dim>{' · '.join(parts)}</div>" if parts else ""

    rows = "".join(
        f"<tr id='t-{esc(t['id'])}'{' data-attn' if t['attention'] else ''}><td>{_badge(theme, t['kind'])}</td>"
        f"<td><b>{esc(t['title'])}</b><div class=dim><code>{esc(t['id'])}</code>"
        f" · {esc(t['repo'])} · {esc(t['kind'])}{(' · ' + esc(t['mode'])) if t['mode'] else ''}</div></td>"
        f"<td>{_state(t['crew']['state'])}<div class=fm-detail>{esc(t['crew']['detail'])}</div>{when(t)}</td>"
        f"<td>{_links(t['prs'])}</td><td class=dim>{esc(t['window'])}</td></tr>"
        for t in tasks)
    return ("<table><thead><tr><th><span class=sr-only>Crew</span></th><th>Task</th><th>State</th><th>PR</th><th>Window</th></tr></thead>"
            f"<tbody>{rows}</tbody></table>")


def _decisions(snap: dict, theme: dict, token: str, flash: str = "", flash_bad: bool = False) -> str:
    tid = theme["id"]
    ds = snap.get("decisions", [])
    out = [f"<h3 id=decisions>Your calls ({len(ds)})</h3>"]
    # The answer's outcome sits where the answer was typed: the redirect lands here.
    if flash:
        out.append(f"<p class='fm-flash{' bad' if flash_bad else ''}' role={'alert' if flash_bad else 'status'}>{esc(flash)}</p>")
    if not ds:
        out.append(_empty("Nothing is waiting on you.", snap.get("ok", False)))
    for d in ds:
        state = _answer_state(d)
        reports = " ".join(f"<a href='/report{_q(tid, path=r)}'>{esc(r)}</a>" for r in d["reports"])
        sent = "".join(
            f"<li>sent as inbox note <code>{esc(a['note'])}</code> {_time(a['at']) or ''} · "
            f"{'picked up by Firstmate' if a['acknowledged'] else 'waiting for Firstmate'}"
            f"{'' if a.get('digest8') == d['digest'][:8] else ' · answered an earlier version of this text'}"
            f"{' · reply: ' + esc(a['reply']) if a.get('reply') else ''}</li>" for a in d.get("answers", []))
        chip = {"current": "<span class=fm-chip>answered</span>",
                "earlier": "<span class=fm-chip data-s=earlier>text changed since your answer</span>"}.get(state, "")
        origin = f"<span>from {esc(d['origin'])}</span>" if d.get("origin") else ""
        out.append(
            f"<article class=fm-decision id='d-{esc(d['id'])}' data-decision='{esc(d['id'])}'{' data-answered' if state == 'current' else ''}>"
            f"<h4>{esc(d['title'])}</h4><div class=fm-meta>{chip}{_badge(theme, d['kind'])}<code>{esc(d['id'])}</code>"
            f"<span>{esc(d['repo'])}</span>{origin}"
            f"<span>held {esc(d['created'])}</span></div>"
            f"<p class=fm-reason>{esc(d['reason'])}</p>"
            + (f"<div class=fm-meta>Report: {reports}</div>" if reports else "")
            + (f"<ul class=fm-sent>{sent}</ul>" if sent else "")
            + (f"<form method=post action='/answer'><input type=hidden name=token value='{esc(token)}'>"
               f"<input type=hidden name=decision value='{esc(d['id'])}'><input type=hidden name=digest value='{esc(d['digest'])}'>"
               f"<input type=hidden name=theme value='{esc(tid)}'>"
               f"<label class=sr-only for='a-{esc(d['id'])}'>Your answer to {esc(d['title'])}</label>"
               f"<textarea id='a-{esc(d['id'])}' name=text maxlength={MAX_ANSWER_CHARS} required "
               "placeholder='Your answer. It becomes a note in the Firstmate inbox naming this decision; nothing runs from this page.'></textarea>"
               "<div class=fm-act><button type=submit>Send to Firstmate inbox</button>"
               "<span class='fm-hint fm-js'>\u2318/Ctrl+Enter sends</span><span class=fm-count aria-hidden=true></span></div></form>"
               if token else "<p class='fm-hint fm-readonly'>Read-only view: answer this on the Mac.</p>")
            + "</article>")
    out.append("<p class=fm-howto>Typing an answer adds a note to Firstmate's captain inbox (<code>fm-inbox.sh note</code>) "
               "naming the decision; Firstmate reads it and acts. An answer is tied to the decision text you saw: if that "
               "text changed, the page asks you to look again, and it never redraws a call while you are writing an answer. "
               "This page merges, approves, starts and runs nothing.</p>")
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
    ok = snap.get("ok", False)
    board = snap.get("bounties", [])
    tally = {s: sum(1 for b in board if b["status"] == s) for s in BOUNTY_LABEL}
    host = _char(theme, "bigshot")
    out = ["<aside id=bounties class=fm-bigshot aria-labelledby=bounties-h>"]
    if theme.get("ship_image"):
        out.append(f"<div class=fm-bigshot-art role=img aria-label='{esc((host.get('name') or 'Big Shot') + ' bounty board')}'></div>")
    out.append("<h2 id=bounties-h>Bounty board</h2>"
               "<p class=fm-intro>Firstmate work outside the crew rooms, and the evidence that closes it. "
               "No money, rewards, points or revenue; a card reads Verified only when a merged PR or report is on record.</p>")
    # Each chip filters the board to its status (the page script enables them; without it they are a plain tally).
    if ok:
        out.append("<ul class=fm-tally aria-label='Bounties by status; press one to show only that status'>"
                   + "".join(f"<li><button type=button class=fm-bstat data-bounty='{s}' aria-pressed=false disabled>"
                             f"<span aria-hidden=true>{BOUNTY_LABEL[s][0]}</span> {BOUNTY_LABEL[s][1]} {tally[s]}</button></li>"
                             for s in BOUNTY_LABEL) + "</ul>")
    active = [b for b in board if b["status"] != "verified"]
    verified = [b for b in board if b["status"] == "verified"]
    out.append("".join(_bounty(b, theme, tid) for b in active) if active else _empty("No open bounties.", ok))
    if verified:
        out.append(f"<details class=fm-verified id=fm-verified><summary>Verified ({len(verified)})</summary>"
                   + "".join(_bounty(b, theme, tid) for b in verified) + "</details>")
    if cargo:
        guys = _char(theme, FALLBACK_CREW)
        out.append("<div class=fm-cargo>" + ("<div class=fm-oldguys aria-hidden=true></div>" if theme.get("ship_image") else "")
                   + f"<p><b>{esc(guys.get('name') or CARGO['label'])}</b>: {_plural(len(cargo), 'crew', 'crews')} of a kind no room "
                   f"claims. <a href='/{_q(tid)}#room-cargo'>See the cargo hold</a></p></div>")
    out.append("</aside>")
    return "".join(out)


def _callbar(snap: dict, tid: str) -> str:
    q = _q(tid)
    c = snap.get("counts", {})
    when = f"<span class='dim fm-meta'>as of {_time(snap.get('generated'))} · <a href='/{q}'>refresh</a></span>"
    if not snap.get("ok"):
        # Never zeros for a failed read: that would read as "nothing needs you".
        return (f"<p class='fm-callbar hot' id=fm-callbar><span>Needs your call: <strong>?</strong></span>"
                f"<span class=fm-unknown>{esc(UNKNOWN)} Counts are unknown until a read succeeds.</span>{when}</p>")
    calls = snap.get("decisions", [])
    needs = len(_needs_you(calls))
    answered = len(calls) - needs
    attn = [t for t in snap.get("in_flight", []) if t["attention"]]
    look = esc(_plural(len(attn), "crew needs", "crews need")) + " a look"
    if attn:
        look = f"<a href='/{q}#t-{esc(attn[0]['id'])}'>{look}</a>"
    return (f"<p class='fm-callbar{' hot' if needs else ''}' id=fm-callbar><span>Needs your call: <strong>{needs}</strong>"
            + (f" <span class=dim>· {answered} answered, waiting for Firstmate</span>" if answered else "") + "</span>"
            f"<a href='/{q}#decisions'>Answer on the Bridge</a>"
            f"<span>{look} · {esc(c.get('in_flight', 0))} in flight · {esc(c.get('queued', 0))} queued</span>{when}</p>")


def dashboard(snap: dict, theme: dict, token: str, nonce: str, flash: str = "", flash_bad: bool = False) -> str:
    tid = theme["id"]
    art = bool(theme.get("ship_image"))
    ok = snap.get("ok", False)
    c = snap.get("counts", {})
    parts = [f"<p class='fm-flash bad' role=alert>Read problem: {esc(e)}</p>" for e in snap.get("errors", [])]
    by, cargo = _rooms(snap)
    calls = snap.get("decisions", [])
    slots = "".join(_slot(theme, st, by[st["id"]], calls if st["id"] == "bridge" else [], art, tid, ok) for st in STATIONS)
    ship_label = f"{theme.get('name') or 'Ship'} cutaway: " + ", ".join(_room_names(theme, st)[0] for st in STATIONS)

    def room(st: dict, tasks: list[dict]) -> str:
        name, crew = _room_names(theme, st)
        return (f"<section class=fm-room id='room-{st['id']}' aria-labelledby='rh-{st['id']}'>"
                f"<h2 id='rh-{st['id']}'>{esc(name)}{f'<small>{esc(crew)}</small>' if crew else ''}</h2>"
                f"<p class=dim>{esc(st['what'])}</p>"
                + (_decisions(snap, theme, token, flash, flash_bad) + "<h3>Captain-kind crews</h3>" if st["id"] == "bridge" else "")
                + _crew_table(theme, tasks, ok) + "</section>")

    # One column of work under the ship: the Bridge (your calls), then every
    # other room's crews. Big Shot's screen runs beside it when wide and
    # follows it when narrow, so on a phone the rooms come before the board.
    parts.append(
        "<section id=ship class=fm-stage aria-label=Ship><div class=fm-deck>"
        f"<div class='fm-ship{' fm-art-on' if art else ''}'>"
        + (f"<div class=fm-art role=img aria-label='{esc(ship_label)}'>"
           "<div class=ship-ambient aria-hidden=true></div><div class=ship-scanline aria-hidden=true></div></div>" if art else "")
        + f"<ol class=fm-slots aria-label='Rooms, live'>{slots}</ol></div>"
        + _callbar(snap, tid) + room(STATIONS[0], by["bridge"])
        + "<section id=rooms aria-label='Crew rooms'>"
        + "".join(room(st, by[st["id"]]) for st in STATIONS[1:])
        + (room(CARGO, cargo) if cargo else "") + "</section></div>"
        + _bigshot(snap, theme, cargo) + "</section>"
        f"<p class=dim>Firstmate home <code>{esc(snap.get('home'))}</code></p>")
    needs = len(_needs_you(calls))
    active = sum(1 for b in snap.get("bounties", []) if b["status"] != "verified")
    nav = ({"decisions": (needs, needs > 0), "rooms": (c.get("in_flight", 0), c.get("attention_tasks", 0) > 0),
            "bounties": (active, False)} if ok else {"decisions": ("?", True)})
    title = ("(!) " if not ok else f"({needs}) " if needs else "") + "Firstmate"
    return page(title, "".join(parts), theme, nonce, {"ok": ok, "fp": snap.get("fingerprint", ""), "nav": nav})


def report(rel: str, text: str, theme: dict, nonce: str) -> str:
    body = (f"<p><a href='/{_q(theme['id'])}#decisions'>&larr; back to the ship</a></p>"
            f"<h2>{esc(rel)}</h2><pre>{esc(text)}</pre>")
    return page(f"Report · {rel}", body, theme, nonce)


def message(title: str, text: str, theme: dict, nonce: str) -> str:
    return page(title, f"<p class='fm-flash bad' role=alert>{esc(text)}</p><p><a href='/{_q(theme['id'])}'>Back</a></p>", theme, nonce)
