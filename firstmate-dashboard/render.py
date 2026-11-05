"""render — HTML for the Firstmate dashboard, a pure function of a snapshot.

Palette, base stylesheet and ship art come from lib/hub_ui (the hub's
presentation module, which reads no store and opens no socket). Bebop crew
names are decoration only: a badge beside a row, never a word that replaces a
state. Every state shown is fm-crew-state.sh's own word.
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

DASH_CSS = """
.fm-brand small{display:block;font-size:11px;color:var(--muted);letter-spacing:.08em;text-transform:uppercase}
.fm-layout{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:20px;align-items:start;margin-top:14px}
@media (max-width:900px){.fm-layout{grid-template-columns:minmax(0,1fr)}.fm-rail{order:-1}}
.fm-ship{aspect-ratio:760/840;border-radius:10px;border:2px solid var(--brass);background-color:var(--surface-2);
  background-repeat:no-repeat;background-size:202.105% 121.905%;background-position:0% 38.043%}
.fm-rail .sidecard{margin-top:10px}
.fm-decision{background:var(--surface);border:1px solid var(--border);border-left:6px solid var(--accent);border-radius:12px;padding:12px 16px;margin:0 0 14px}
.fm-decision h3{margin:0 0 4px}
.fm-meta{font-size:12px;color:var(--muted);display:flex;flex-wrap:wrap;gap:4px 12px;align-items:center}
.fm-reason{white-space:pre-wrap;word-break:break-word;margin:8px 0;font-size:13.5px}
.fm-decision form{display:grid;gap:6px;margin-top:8px}
.fm-decision textarea{width:100%;min-height:72px;font:inherit;resize:vertical}
.fm-decision button{justify-self:start;font:600 12px system-ui;padding:5px 12px;border-radius:5px;border:1px solid var(--accent);background:transparent;color:var(--accent);cursor:pointer}
.fm-decision button:hover{background:var(--accent);color:var(--bg)}
.fm-sent{font-size:12.5px;margin:6px 0 0;padding-left:18px}
.fm-flash{border:2px solid var(--ok);border-radius:8px;padding:8px 12px;margin:10px 0}
.fm-flash.bad{border-color:var(--bad)}
.crew-badge{display:inline-flex;align-items:center;gap:4px;font-size:11px;color:var(--muted);white-space:nowrap}
.crew-badge::before{content:"";width:9px;height:9px;border-radius:50%;background:var(--c,var(--brass));border:1px solid var(--border)}
td .dim,.fm-detail{font-size:12px;color:var(--muted);word-break:break-word}
.fm-empty{color:var(--muted);font-style:italic}
.dim{color:var(--muted)}
"""

_POLLER = """(function(){var fp=%s;setInterval(function(){var ta=document.querySelectorAll('textarea');
for(var i=0;i<ta.length;i++){if(ta[i].value.trim()||document.activeElement===ta[i])return}
fetch('/api/summary',{cache:'no-store'}).then(function(r){return r.json()}).then(function(s){
if(s.fingerprint&&s.fingerprint!==fp)location.reload()}).catch(function(){})},15000)})();"""


def esc(s) -> str:
    return html.escape("" if s is None else str(s), quote=True)


def theme_of(query_theme: str | None) -> dict:
    return THEMES.get(query_theme or "", THEMES[DEFAULT_THEME])


def _badge(theme: dict, kind: str) -> str:
    chars = theme.get("characters") or {}
    who = chars.get(KIND_CREW.get(kind, FALLBACK_CREW))
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


def _state(word: str) -> str:
    return f"<span class=st data-d='{STATE_STYLE.get(word, 'unknown')}'>{esc(word)}</span>"


def _links(urls) -> str:
    return " ".join(f"<a href='{esc(u)}' rel=noreferrer>{esc(_short_pr(u))}</a>" for u in urls) or "<span class=dim>—</span>"


def _short_pr(url: str) -> str:
    m = re.search(r"github\.com/[^/]+/([^/]+)/pull/(\d+)", url)
    return f"{m.group(1)}#{m.group(2)}" if m else url


def _q(theme_id: str, **extra) -> str:
    params = {k: v for k, v in extra.items() if v}
    if theme_id != DEFAULT_THEME:
        params["theme"] = theme_id
    return ("?" + urllib.parse.urlencode(params)) if params else ""


def page(title: str, body: str, theme: dict, nonce: str, fingerprint: str = "") -> str:
    tid = theme["id"]
    switch = " ".join(
        f"<a href='/{_q(t)}'{' aria-current=page' if t == tid else ''}>{esc(THEMES[t].get('name') or t)}</a>"
        for t in sorted(THEMES))
    poll = f"<script nonce='{esc(nonce)}'>{_POLLER % json.dumps(fingerprint)}</script>" if fingerprint else ""
    tagline = esc(theme.get("tagline") or "")
    return (f"<!doctype html><html lang=en data-theme='{esc(tid)}'><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            f"<title>{esc(title)}</title><style>{hub_ui._theme_css()}{hub_ui.BASE_CSS}{DASH_CSS}</style></head><body>"
            "<a class=skip href='#main'>Skip to content</a>"
            f"<header><b class='brand fm-brand'>FIRSTMATE{f'<small>{tagline}</small>' if tagline else ''}</b>"
            f"<nav aria-label=Sections><a href='/{_q(tid)}#decisions'>Your calls</a><a href='/{_q(tid)}#crew'>Crew</a>"
            f"<a href='/{_q(tid)}#queue'>Queue</a><a href='/{_q(tid)}#done'>Done</a></nav>"
            f"<span class='dim hdr-meta'>read-only · theme: {switch} · <a href='/api/summary'>json</a></span></header>"
            f"<main id=main tabindex=-1>{body}</main>{poll}</body></html>")


def dashboard(snap: dict, theme: dict, token: str, nonce: str, flash: str = "", flash_bad: bool = False) -> str:
    tid = theme["id"]
    c = snap.get("counts", {})
    parts = []
    if flash:
        parts.append(f"<p class='fm-flash{' bad' if flash_bad else ''}' role=status>{esc(flash)}</p>")
    for e in snap.get("errors", []):
        parts.append(f"<p class='fm-flash bad' role=alert>Read problem: {esc(e)}</p>")
    parts.append(f"<p class=dim>Firstmate home <code>{esc(snap.get('home'))}</code> · as of {esc(snap.get('generated'))}"
                 f" · <a href='/{_q(tid)}'>refresh</a></p>")
    cards = (("Your calls", c.get("open_decisions", 0), "#decisions", "captain holds waiting on you"),
             ("Need attention", c.get("attention_tasks", 0), "#crew", "crews blocked, failed or parked"),
             ("In flight", c.get("in_flight", 0), "#crew", "crews running now"),
             ("Queued", c.get("queued", 0), "#queue", "waiting to start"))
    parts.append("<section class=cards aria-label=Counts>" + "".join(
        f"<a class='card{' hot' if n and i < 2 else ''}' href='{href}'><div class=t>{esc(t)}</div>"
        f"<div class=n>{esc(n)}</div><div class=s>{esc(s)}</div></a>"
        for i, (t, n, href, s) in enumerate(cards)) + "</section>")

    col = [f"<h2 id=decisions>Your calls ({len(snap.get('decisions', []))})</h2>"]
    if not snap.get("decisions"):
        col.append("<p class=fm-empty>Nothing is waiting on you.</p>")
    for d in snap.get("decisions", []):
        reports = " ".join(f"<a href='/report{_q(tid, path=r)}'>{esc(r)}</a>" for r in d["reports"])
        sent = "".join(
            f"<li>sent as inbox note <code>{esc(a['note'])}</code> {esc(a['at'])} · "
            f"{'picked up by Firstmate' if a['acknowledged'] else 'waiting for Firstmate'}"
            f"{' · reply: ' + esc(a['reply']) if a.get('reply') else ''}</li>" for a in d.get("answers", []))
        origin = f"<span>from {esc(d['origin'])}</span>" if d.get("origin") else ""
        col.append(
            f"<article class=fm-decision id='d-{esc(d['id'])}' data-decision='{esc(d['id'])}'>"
            f"<h3>{esc(d['title'])}</h3><div class=fm-meta>{_badge(theme, d['kind'])}<code>{esc(d['id'])}</code>"
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

    col.append(f"<h2 id=crew>Crew in flight ({len(snap.get('in_flight', []))})</h2>")
    if snap.get("in_flight"):
        rows = "".join(
            f"<tr><td>{_badge(theme, t['kind'])}</td><td><b>{esc(t['title'])}</b><div class=dim><code>{esc(t['id'])}</code>"
            f" · {esc(t['repo'])} · {esc(t['kind'])}{(' · ' + esc(t['mode'])) if t['mode'] else ''}</div></td>"
            f"<td>{_state(t['crew']['state'])}<div class=fm-detail>{esc(t['crew']['detail'])}</div></td>"
            f"<td>{_links(t['prs'])}</td><td class=dim>{esc(t['window'])}</td></tr>"
            for t in snap["in_flight"])
        col.append("<table><thead><tr><th><span class=sr-only>Crew</span></th><th>Task</th><th>State</th><th>PR</th><th>Window</th></tr></thead>"
                   f"<tbody>{rows}</tbody></table>")
    else:
        col.append("<p class=fm-empty>No crews running.</p>")

    col.append(f"<h2 id=queue>Queued ({len(snap.get('queued', []))})</h2>")
    if snap.get("queued"):
        rows = "".join(
            f"<tr><td>{_badge(theme, q['kind'])}</td><td><b>{esc(q['title'])}</b><div class=dim><code>{esc(q['id'])}</code>"
            f" · {esc(q['repo'])} · {esc(q['kind'])}</div></td>"
            f"<td>{('held (' + esc(q['hold_kind'] or 'hold') + '): ' + esc(q['hold_reason'])) if q['held'] else 'ready when a slot frees'}</td></tr>"
            for q in snap["queued"])
        col.append(f"<table><thead><tr><th><span class=sr-only>Crew</span></th><th>Task</th><th>Waiting on</th></tr></thead><tbody>{rows}</tbody></table>")
    else:
        col.append("<p class=fm-empty>Queue is empty.</p>")

    done = snap.get("done", [])
    rows = "".join(
        f"<tr><td>{_badge(theme, d['kind'])}</td><td>{esc(d['title'])}<div class=dim><code>{esc(d['id'])}</code> · {esc(d['repo'])}</div></td>"
        f"<td class=dim>{esc(d['closed'])}</td><td>{_links(d['prs'])}</td></tr>" for d in done)
    col.append(f"<details class=hist id=done><summary>Recently done ({len(done)})</summary>"
               + (f"<table><tbody>{rows}</tbody></table>" if done else "<p class=fm-empty>None kept.</p>") + "</details>")

    rail = ["<aside class=fm-rail aria-label='Ship'>"]
    if theme.get("ship_image"):
        rail.append(f"<div class=fm-ship role=img aria-label='{esc(theme.get('name'))} ship art' "
                    f"style=\"background-image:url('{esc(theme['ship_image'])}')\"></div>")
    rail.append("<div class=sidecard><h4>How answers work</h4><p>Typing an answer adds a note to Firstmate's captain inbox "
                "(<code>fm-inbox.sh note</code>) naming the decision. Firstmate reads it and acts. This page merges, approves, "
                "starts and runs nothing.</p><p>An answer is tied to the decision text you saw; if that text changed, the page asks you to look again.</p></div>")
    chars = theme.get("characters") or {}
    crew = "".join(f"<p>{_badge(theme, k)} {esc(k)} work</p>" for k in KIND_CREW if chars.get(KIND_CREW[k]))
    if crew:
        rail.append(f"<div class=sidecard aria-hidden=true><h4>Crew</h4>{crew}</div>")
    rail.append("</aside>")
    return page("Firstmate", "".join(parts) + "<div class=fm-layout><div class=fm-col>" + "".join(col)
                + "</div>" + "".join(rail) + "</div>", theme, nonce, snap.get("fingerprint", ""))


def report(rel: str, text: str, theme: dict, nonce: str) -> str:
    body = (f"<p><a href='/{_q(theme['id'])}#decisions'>&larr; back to your calls</a></p>"
            f"<h2>{esc(rel)}</h2><pre>{esc(text)}</pre>")
    return page(f"Report · {rel}", body, theme, nonce)


def message(title: str, text: str, theme: dict, nonce: str) -> str:
    return page(title, f"<p class='fm-flash bad' role=alert>{esc(text)}</p><p><a href='/{_q(theme['id'])}'>Back</a></p>", theme, nonce)
