"""Untrusted-text sanitizer shared by publisher.py (a message's text, on its
way into a live agent's pane) and tasks.py (a start_task/resume_task
objective/follow-up, on its way into a spawned task's SPEC.md or pane). Same
rule as the Worker's sanitizeMessage/sanitizeObjective (policy.ts),
re-applied here: the Mac re-checks everything it types, never trusts that the
Worker already did.

A separate module, not a function importable from publisher.py, because
tasks.py needs it and publisher.py will need tasks.py (to push task_config
and process leased commands) -- `from publisher import clean` there would be
a circular import the moment that wiring lands.
"""
from __future__ import annotations

import re
import unicodedata

BLANKS = "\u115f\u1160\u3164\uffa0\u2800"


def clean(s: str) -> str:
    """NFKC fold; invisible and non-printing characters (control, format,
    private use, combining marks, variation selectors, blank fillers) and the
    bracket-piece symbols U+239B-U+23B3 become spaces; every opening/closing
    punctuation mark (Ps/Pe) except ASCII { } becomes ( / ), so nothing can
    imitate or close the envelope; "@" becomes fullwidth "＠" so omp/Claude
    Code never expand an @path mention into a file's contents (review H1)."""
    out = []
    for c in unicodedata.normalize("NFKC", s):
        cat = unicodedata.category(c)
        if c in BLANKS or cat[0] == "C" or cat in ("Zl", "Zp", "Mn", "Me") or "\u239b" <= c <= "\u23b3":
            out.append(" ")
        elif cat == "Ps" and c != "{":
            out.append("(")
        elif cat == "Pe" and c != "}":
            out.append(")")
        else:
            out.append("\uff20" if c == "@" else c)
    return re.sub(r"\s+", " ", "".join(out)).strip()
