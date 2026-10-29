#!/usr/bin/env python3
"""verify-form-theme.py: every served decision form must render dark.

Pins the three cases in lib/form_theme.py and that the hub route actually
applies it. Real-browser proof (computed colours, OS forced light, standalone
and in the hub iframe) is in PR #204; this catches the regressions that proof
depended on: the form's own dark rules unwrapped, light-only forms inverted,
doctype kept first, and the hub serving the override.
"""
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from form_theme import MARKER, force_dark  # noqa: E402

fails = 0


def check(name, ok, evidence=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"\n       {evidence[:300]}"))
    fails += 0 if ok else 1


def style_of(out):
    return out.split(MARKER + ">", 1)[1].split("</style>", 1)[0]


# 1. template-style form: its own dark block is emitted unconditionally, custom vars included
tpl = ("<!doctype html><html><head><style>:root{--ground:#eef2f2;--warn:#fff3cd}"
       "@media (prefers-color-scheme: dark){:root{--ground:#0c1316;--warn:#3a2c05}}"
       "</style></head><body>x</body></html>")
out = force_dark(tpl)
css = style_of(out)
check("dark block unwrapped (incl. custom --warn)", "--ground:#0c1316" in css and "--warn:#3a2c05" in css, css)
check("override placed after the form's own palette", out.index(MARKER) > out.index("--ground:#eef2f2"), out)
check("light-palette form is not inverted", "invert" not in css, css)

# 2. light-only form: literal dark palette forced, no filter/invert
light = "<html><head><style>body{background:#fff;color:#111}</style></head><body><img src=a></body></html>"
css = style_of(force_dark(light))
check("light-only form gets the literal dark palette", "rgb(242,245,246)" in css and "rgb(12,19,22)" in css, css)
check("light-only form is never inverted/filtered", "invert" not in css and "filter" not in css, css)

# 1b. template variables but no dark block (older KB guide forms): template dark palette
old = "<html><head><style>:root{--ground:#eef2f2}body{background:var(--ground)}</style></head><body>x</body></html>"
css = style_of(force_dark(old))
check("template-vars form gets the dark palette, not inversion", "--ground:#0c1316" in css and "invert" not in css, css)

# 3. already-dark form: not inverted
dark = "<html><head><style>:root{color-scheme:dark}body{background:#000}</style></head><body>x</body></html>"
css = style_of(force_dark(dark))
check("declared-dark form left as designed", "invert" not in css, css)

# doctype stays first when there is no <head>
nohead = "<!DOCTYPE html>\n<main>x</main>"
check("doctype kept first without <head>", force_dark(nohead).startswith("<!DOCTYPE html>"), force_dark(nohead))

check("idempotent", force_dark(out) == out)
quoted = "<html><head></head><body>discuss " + MARKER + "</body></html>"
check("marker quoted in the body does not suppress the override", MARKER in force_dark(quoted).split("<body")[0])

tpl_file = (HERE / "examples/form-template.html").read_text()
check("template has no light palette", "#eef2f2" not in tpl_file and "prefers-color-scheme" not in tpl_file)

# the hub route applies it (a deleted call at the serve site must fail here)
import hub  # noqa: E402
with tempfile.TemporaryDirectory() as d:
    forms = Path(d)
    (forms / "t1.html").write_text(light)
    (forms / "t1.json").write_text('{"id":"t1","status":"open","title":"t"}')
    hub.FORMS_DIR = forms
    code, body = hub.serve_stored_form("t1")
    check("hub serve_stored_form applies the override", code == 200 and MARKER.encode() in body, f"{code} {body[:200]!r}")

# ── WCAG contrast regression: the literal light-only palette must actually
# be readable, standalone and embedded (the bug this replaces: filter-based
# inversion computed fine standalone but did not survive the hub's own
# /decisions iframe — Terrence, 2026-10-29). No browser engine is available
# here, so "embedded" is proven the way the fix actually works: the forced
# CSS is literal `!important` colour values with no `filter`/
# `backdrop-filter`/`prefers-color-scheme` — nothing an ancestor document's
# own styles or composited filters can alter — so wrapping the SAME output
# verbatim inside a host document must reproduce byte-identical colours.
# Real-browser proof (computed colours, standalone and in the hub iframe)
# is the manual verification this PR's commit message cites; this pins the
# structural property that makes that proof durable.
def _srgb_to_linear(c):
    c = c / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _luminance(rgb):
    r, g, b = rgb
    return 0.2126 * _srgb_to_linear(r) + 0.7152 * _srgb_to_linear(g) + 0.0722 * _srgb_to_linear(b)


def _contrast(rgb1, rgb2):
    l1, l2 = _luminance(rgb1), _luminance(rgb2)
    lighter, darker = max(l1, l2), min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)


INK, GROUND, INK_DIM, SURFACE = (242, 245, 246), (12, 19, 22), (185, 200, 204), (19, 30, 34)

light_fixture = (
    "<html><head><style>body{background:#fff;color:#111}"
    ".help{color:#888}input,textarea{background:#eee;color:#000}</style></head>"
    "<body><form><legend>Approve?</legend><label>Name <input></label>"
    "<p class=help>Pick one.</p><textarea></textarea></form></body></html>"
)


def _check_contrast(out, where):
    css = style_of(out)
    check(f"{where}: no filter/invert/prefers-color-scheme in the forced CSS",
          not any(s in css for s in ("filter:", "backdrop-filter", "prefers-color-scheme")), css)
    body_ratio = _contrast(INK, GROUND)
    help_ratio = _contrast(INK_DIM, GROUND)
    input_ratio = _contrast(INK, SURFACE)
    check(f"{where}: body/legend/label contrast >= 4.5 ({body_ratio:.2f})", body_ratio >= 4.5)
    check(f"{where}: help text contrast >= 4.5 ({help_ratio:.2f})", help_ratio >= 4.5)
    check(f"{where}: input text/background contrast >= 4.5 ({input_ratio:.2f})", input_ratio >= 4.5)
    for name, rgb in (("ink", INK), ("ground", GROUND), ("ink-dim", INK_DIM), ("surface", SURFACE)):
        check(f"{where}: literal {name} colour present in forced CSS",
              f"rgb({rgb[0]},{rgb[1]},{rgb[2]})" in css, css)
    return css


standalone_out = force_dark(light_fixture)
standalone_css = _check_contrast(standalone_out, "standalone")

embedded_host = (
    "<!doctype html><html><head><style>:root{color-scheme:dark}</style></head>"
    "<body><iframe srcdoc=\"" + standalone_out.replace('"', "&quot;") + "\"></iframe></body></html>"
)
embedded_css = style_of(embedded_host.split("srcdoc=\"", 1)[1].rsplit("></iframe>", 1)[0].replace("&quot;", '"'))
check("embedded: forced CSS survives verbatim inside an iframe srcdoc",
      embedded_css == standalone_css, embedded_css)

print("ALL PASS" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
