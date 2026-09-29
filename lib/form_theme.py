"""Force every decision form to render dark, standalone and inside the hub.

Terrence, 2026-09-29: forms "should always be dark mode, even in iframe".
Forms built from examples/form-template.html (and every generator copied from
it) carried a light palette plus a `prefers-color-scheme: dark` override. In
the hub's inbox the form sits in an iframe, and an iframe resolves
`prefers-color-scheme` from its embedder's used color scheme, which the hub
never declared, so the form showed light on a dark page.

Applied when a form is SERVED (hub + formserve), not when it is written, so
it also covers every form already on disk. The override is appended at the
end of <head>: later rules at higher specificity (`html:root`) win over the
form's own `:root` palette, whichever order its rules come in.
"""
from __future__ import annotations

import re

# The template's own dark values, so a form looks exactly like its dark variant.
DARK_STYLE = (
    '<meta name="color-scheme" content="dark">'
    "<style id=\"herdr-force-dark\">html:root{color-scheme:dark;"
    "--ground:#0c1316;--surface:#131e22;--line:#2c3b41;--ink:#e6edee;"
    "--ink-2:#a9bcc1;--accent:#58b6c8;--accent-soft:#12323a;"
    "background:#0c1316;color:#e6edee}</style>"
)

_HEAD_END = re.compile(r"</head\s*>", re.I)
_BODY_OPEN = re.compile(r"<body[^>]*>", re.I)


def force_dark(html: str) -> str:
    """Return `html` with the dark override appended to <head>.

    No <head>: put it right after <body> (still in the document), else prepend.
    Idempotent: a second pass leaves the output unchanged."""
    if 'id="herdr-force-dark"' in html:
        return html
    m = _HEAD_END.search(html)
    if m:
        return html[:m.start()] + DARK_STYLE + html[m.start():]
    m = _BODY_OPEN.search(html)
    if m:
        return html[:m.end()] + DARK_STYLE + html[m.end():]
    return DARK_STYLE + html
