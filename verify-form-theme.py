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

# 2. light-only form: inverted, media re-inverted
light = "<html><head><style>body{background:#fff;color:#111}</style></head><body><img src=a></body></html>"
css = style_of(force_dark(light))
check("light-only form inverted", "invert(.92)" in css and "img" in css, css)

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

print("ALL PASS" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
