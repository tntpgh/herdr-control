#!/usr/bin/env python3
"""verify-form-theme.py: every served decision form must render dark.

The override must land AFTER the form's own palette (same-specificity rules,
later wins) and must survive a form with no <head>. A form served light inside
the hub's dark iframe was the 2026-09-29 complaint; the real-browser proof is
in the PR. This pins the placement rule that proof depended on.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from form_theme import force_dark  # noqa: E402

fails = 0


def check(name, ok, evidence=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"\n       {evidence}"))
    fails += 0 if ok else 1


light = "<html><head><style>:root{--ground:#eef2f2}</style></head><body>x</body></html>"
out = force_dark(light)
check("override comes after the form's own palette",
      out.index("herdr-force-dark") > out.index("--ground:#eef2f2"), out)
check("declares color-scheme dark", 'content="dark"' in out and "color-scheme:dark" in out, out)
check("idempotent", force_dark(out) == out)
headless = force_dark("<body class=a>x</body>")
check("no <head>: placed inside <body>", headless.startswith("<body class=a><meta"), headless)

# The generator's template must not reintroduce a light-first palette.
tpl = (Path(__file__).resolve().parent / "examples/form-template.html").read_text()
check("template has no light palette", "#eef2f2" not in tpl and "prefers-color-scheme" not in tpl)

print("ALL PASS" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
