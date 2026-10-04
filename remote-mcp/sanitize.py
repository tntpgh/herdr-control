"""Untrusted-text sanitizer shared by publisher.py (a message's text, on its
way into a live agent's pane) and tasks.py (a start_task/resume_task
objective/follow-up, on its way into a spawned task's SPEC.md or pane). Same
rule as the Worker's sanitizeMessage/sanitizeObjective (policy.ts),
re-applied here: the Mac re-checks everything it types, never trusts that the
Worker already did.

A separate module, not a function importable from publisher.py, because
tasks.py needs it and publisher.py will need tasks.py (to push task_config
and process leased commands) -- `from publisher import clean` there would be
a circular import the moment that wiring lands. read_single_link_regular
below lives here for the identical reason: F4 (security review round 2,
2026-10-04) wants tasks.py's ANSWER.md read and publisher.py's has_answer
check to use the exact same safe-read primitive, and publisher.py already
imports tasks.py.
"""
from __future__ import annotations

import os
import re
import stat as _stat
import unicodedata
from pathlib import Path

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


READ_CAP_DEFAULT = 1_000_000  # matches publisher.py's RESULT_READ_CAP


def read_single_link_regular(path: Path, cap: int = READ_CAP_DEFAULT) -> bytes:
    """Read at most `cap` bytes of a plain file with exactly one link: no
    symlink (O_NOFOLLOW), not a hard link to a file reachable elsewhere
    (st_nlink == 1), and both checks apply to the descriptor actually read
    (never a path re-resolved after the check, which a rename/symlink swap
    between stat and read could defeat). Raises OSError if the path is
    missing or fails either check. The one safe reader for a file an
    untrusted worker's pane wrote into its own worktree -- ANSWER.md here,
    publisher.py's read_regular is the same primitive for a synced reply."""
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not _stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            raise OSError(f"{path}: not a single-link regular file")
        with os.fdopen(fd, "rb", closefd=False) as f:
            return f.read(cap)
    finally:
        os.close(fd)
