#!/usr/bin/env python3
"""Copy fixtures/*.json and themes/*/theme.json into index.html.

Browsers refuse fetch() from file://, so the page reads <script type="application/json">
copies. The JSON files stay the source of truth; check.js fails if a copy drifts.
Usage (from anywhere): python3 prototype/board/sync.py
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
SOURCES = [
    ("data-board", "fixtures/board.json"),
    ("data-decisions", "fixtures/decisions.json"),
    ("data-job-classes", "fixtures/job-classes.json"),
    ("data-gbp-drafts", "fixtures/gbp-drafts.json"),
    ("data-bounties", "fixtures/bounties.json"),
    ("data-theme-bebop", "themes/bebop/theme.json"),
    ("data-theme-plain", "themes/plain/theme.json"),
]
BLOCK = re.compile(r"(<!-- inline-data:begin[^>]*-->\n).*?(<!-- inline-data:end -->)", re.S)


def main() -> None:
    blocks = []
    for el_id, rel in SOURCES:
        text = (HERE / rel).read_text(encoding="utf-8")
        json.loads(text)  # refuse to inline invalid JSON
        for bad in ("</", "<!--"):
            if bad in text:
                sys.exit(f"{rel}: contains {bad!r}, which would break the inline <script> element")
        blocks.append(f'<script type="application/json" id="{el_id}" data-src="{rel}">\n{text.rstrip()}\n</script>\n')
    page = HERE / "index.html"
    html = page.read_text(encoding="utf-8")
    new, n = BLOCK.subn(lambda m: m.group(1) + "".join(blocks) + m.group(2), html)
    if n != 1:
        sys.exit("index.html: inline-data markers not found exactly once")
    page.write_text(new, encoding="utf-8")
    print(f"inlined {len(blocks)} files into index.html")


main()
