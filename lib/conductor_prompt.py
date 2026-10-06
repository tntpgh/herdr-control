#!/usr/bin/env python3
"""conductor_prompt — the ONE reader of a worker's last `CONDUCTOR:` request.

DESIGN-228 §1. hub.py imports it for signal 5 (`conductor_prompt`) and
send-to-agent.sh runs it as a CLI on the identical pane read
(`herdr pane read <pane> --source recent --lines 60`), so the request a
delivery captures and the request the hub sights are computed by one copy.

A request is (F, C, P):
  F    `fingerprint(block)`: the last `CONDUCTOR:` row plus its continuation
       rows, hashed whitespace-free (a rewrap/resize keeps F).
  C    digest of the nearest non-blank, non-`※` paragraph ABOVE the block,
       whitespace-free; `?` when that paragraph touches window row 0, when
       nothing is above, or when it holds tool-gutter rows (omp truncates
       those at the pane width, so they are width-dependent).
  P    paragraphs BELOW the block: blank-row separated, a `╭…╰` box counts
       one, each `※`-led paragraph counts 0, and so does a lone omp spinner
       row (`Working…` etc — furniture, not an answer). Characters are
       never counted.

CLI: pane text on stdin -> `{"fp":…,"ctx":…,"tail":…}` on stdout, or nothing
when no request is visible.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys

ANSI_RE = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]')
_COMPOSER_TOP_RE = re.compile(r'^\s*\u256d')        # ╭
_MD_LEADING_RE = re.compile(r'^[\*_]+')             # **CONDUCTOR:** / __CONDUCTOR:__
_RECAP = "\u203b"                                   # ※
_BOX_TOP, _BOX_BOTTOM = "\u256d", "\u2570"          # ╭ ╰
_GUTTER_LEADS = ("\u2502", "\u251c", "\u2514", "\u256d", "\u2570")   # │ ├ └ ╭ ╰
UNKNOWN_CTX = "?"
_SPINNER_WORDS = ("Working", "Thinking", "Running", "Compacting")  # the same
# keywords lib/attention.sh greps for on a live pane; here they mark a dead
# one-row paragraph, not a live state.
_PUA = r"[\uE000-\uF8FF\U000F0000-\U000FFFFD\U00100000-\U0010FFFD]"  # private
# use: icon fonts only, an agent's own words never start with one, so
# requiring it keeps a genuine one-word reply like "Working…" OUT of this.
_SPINNER_RE = re.compile(r"^%s+\s*(?:%s)\u2026$" % (_PUA, "|".join(_SPINNER_WORDS)))


def agent_output_lines(text: str) -> list[str]:
    """Everything ABOVE the omp composer's own top border (the LAST `╭` row,
    `lib/prompt-parse.sh` `_composer_input_rows`' complement). No `╭` in the
    window leaves nothing distinguishable as output: returns none rather than
    guessing."""
    raw = text.splitlines()
    top = None
    for i, line in enumerate(raw):
        if _COMPOSER_TOP_RE.match(ANSI_RE.sub("", line)):
            top = i
    return raw[:top] if top is not None else []


def fingerprint(line: str) -> str:
    """Whitespace-free, so a rewrap of the identical request keeps its F."""
    norm = re.sub(r"\s+", "", line)
    return f"cprompt:{hashlib.sha256(norm.encode()).hexdigest()[:16]}"


def _paragraphs(rows: list[str]) -> list[tuple[int, int, str]]:
    """[(first, last, kind)] over `rows`; kind is `text`, `box`, `recap` or
    `spinner`.

    A `╭…╰` box is one unit whatever it holds. A `※`-led paragraph runs from
    its first row to the next blank row. A `※` or `╭` row also ends the text
    paragraph above it, the same rule the request's own continuation join
    uses for `※`. A single-row paragraph that is nothing but an omp spinner
    glyph plus one of its status words (`Working…`, `Thinking…`, `Running…`,
    `Compacting…` — lib/attention.sh's own list) is `spinner`: furniture that
    can disappear on the very next render."""
    out: list[tuple[int, int, str]] = []
    i, n = 0, len(rows)
    while i < n:
        s = rows[i].strip()
        if not s:
            i += 1
            continue
        if s.startswith(_BOX_TOP):
            j = i
            while j < n - 1 and not rows[j].strip().startswith(_BOX_BOTTOM):
                j += 1
            out.append((i, j, "box"))
            i = j + 1
            continue
        kind = "recap" if s.startswith(_RECAP) else "text"
        j = i + 1
        while j < n and rows[j].strip() and not rows[j].strip().startswith((_RECAP, _BOX_TOP)):
            j += 1
        if kind == "text" and j - 1 == i and _SPINNER_RE.fullmatch(s):
            # A lone omp spinner row ("Working…" etc) can still be on screen
            # the instant herdr samples an otherwise-idle task, and vanishes
            # on the next render. Counting it would let P drop between two
            # sightings of the SAME answered occurrence, and only a decrease
            # in P can mint a false re-ask (hub.py
            # `_CpromptFold.same_line`) — so it counts 0, like `※` (r2 L2).
            kind = "spinner"
        out.append((i, j - 1, kind))
        i = j
    return out


def _context(rows: list[str]) -> str:
    """C over the rows above the block (see the module docstring)."""
    for first, last, kind in reversed(_paragraphs(rows)):
        if kind in ("recap", "spinner"):
            continue
        if first == 0:
            return UNKNOWN_CTX                      # may be clipped by the window
        para = rows[first:last + 1]
        if any(r.lstrip().startswith(_GUTTER_LEADS) or "\u2502" in r for r in para):
            return UNKNOWN_CTX                      # width-dependent tool rows
        norm = re.sub(r"\s+", "", "".join(para))
        return hashlib.sha256(norm.encode()).hexdigest()[:16]
    return UNKNOWN_CTX


def _tail(rows: list[str]) -> int:
    """P over the rows below the block (see the module docstring)."""
    return sum(1 for _, _, kind in _paragraphs(rows) if kind not in ("recap", "spinner"))


def last_request(text: str | None) -> dict | None:
    """The last `CONDUCTOR:` request in agent output, as
    {"line", "fp", "ctx", "tail"}, or None when none is visible."""
    if not text:
        return None
    rows = [ANSI_RE.sub("", ln).rstrip() for ln in agent_output_lines(text)]
    for i in range(len(rows) - 1, -1, -1):
        row = _MD_LEADING_RE.sub("", rows[i].strip())
        if not row.startswith("CONDUCTOR:"):
            continue
        parts = [row]
        j = i + 1
        while j < len(rows) and rows[j].strip() and not rows[j].strip().startswith(_RECAP):
            parts.append(rows[j].strip())
            j += 1
        line = " ".join(parts)
        return {"line": line, "fp": fingerprint(line),
                "ctx": _context(rows[:i]), "tail": _tail(rows[j:])}
    return None


def main() -> int:
    req = last_request(sys.stdin.read())
    if req:
        print(json.dumps({"fp": req["fp"], "ctx": req["ctx"], "tail": req["tail"]},
                         separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
