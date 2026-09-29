"""Force every decision form to render dark, standalone and inside the hub.

Terrence, 2026-09-29: forms "should always be dark mode, even in iframe".
Forms carried a light palette plus a `prefers-color-scheme: dark` override. In
the hub's inbox the form sits in an iframe, and an iframe resolves
`prefers-color-scheme` from its embedder's used color scheme, which the hub
never declared, so the form showed light on a dark page.

Applied when a form is SERVED (hub + formserve), not when it is written, so
it also covers every form already on disk. Three cases, by what the form has:

1. A `@media (prefers-color-scheme: dark)` block: its OWN dark rules are
   re-emitted unconditionally at the end of <head>. The form looks exactly
   like its designed dark variant, custom variables (`--warn`, ...) included.
2. The template's variables (`--ground`, ...) with no dark block (older KB
   guide forms): the template's dark palette is set on those variables.
3. Already dark by declaration (`color-scheme: dark`): only the meta is added.
4. Light-only (no dark variant at all): the page is colour-inverted, with
   media re-inverted so photos stay true. Recolouring such a form by hand
   would leave its hard-coded light backgrounds under forced light text.
"""
from __future__ import annotations

import re

MARKER = 'id="herdr-force-dark"'
_META = '<meta name="color-scheme" content="dark">'
_INVERT = ("html{filter:invert(.92) hue-rotate(180deg);background:#fff}"
           "img,video,picture,canvas,svg image{filter:invert(1) hue-rotate(180deg)}")

_DARK_MEDIA = re.compile(r"@media[^{]*prefers-color-scheme\s*:\s*dark[^{]*\{", re.I)
# examples/form-template.html's palette
_TEMPLATE_DARK = ("html:root{--ground:#0c1316;--surface:#131e22;--line:#2c3b41;--ink:#e6edee;"
                  "--ink-2:#a9bcc1;--accent:#58b6c8;--accent-soft:#12323a}")
_DECLARED_DARK = re.compile(r"color-scheme\s*:\s*dark|name=[\"']color-scheme[\"']\s+content=[\"']dark", re.I)
_HEAD_END = re.compile(r"</head\s*>", re.I)
_HEAD_REGION_END = re.compile(r"<body[\s>]", re.I)
_AFTER_PREAMBLE = re.compile(r"(?:\s*<!doctype[^>]*>)?(?:\s*<html[^>]*>)?(?:\s*<head[^>]*>)?", re.I)


def _dark_media_bodies(html: str) -> list[str]:
    """Inner CSS of every `@media (prefers-color-scheme: dark) { ... }` block."""
    out = []
    for m in _DARK_MEDIA.finditer(html):
        depth, i = 1, m.end()
        while i < len(html) and depth:
            depth += {"{": 1, "}": -1}.get(html[i], 0)
            i += 1
        if depth == 0:
            out.append(html[m.end():i - 1])
    return out


def force_dark(html: str) -> str:
    """Return `html` with a dark override in its <head>. Idempotent."""
    head_end = _HEAD_REGION_END.search(html)
    if MARKER in html[:head_end.start() if head_end else len(html)]:
        return html
    bodies = _dark_media_bodies(html)
    if bodies:
        css = ":root{color-scheme:dark}" + "".join(bodies)
    elif "--ground" in html:
        css = ":root{color-scheme:dark}" + _TEMPLATE_DARK
    elif _DECLARED_DARK.search(html):
        css = ":root{color-scheme:dark}"
    else:
        css = _INVERT
    block = f"{_META}<style {MARKER}>{css}</style>"
    m = _HEAD_END.search(html)
    if m:  # last in <head>: later rules win over the form's own at equal specificity
        return html[:m.start()] + block + html[m.start():]
    # No </head>: go after doctype/<html>/<head> so the doctype still leads
    # (anything before it drops the page into quirks mode).
    cut = _AFTER_PREAMBLE.match(html).end()
    return html[:cut] + block + html[cut:]
