#!/usr/bin/env python3
"""List every owner-inbox exchange that still needs handling, oldest first.

Why: the typed [INBOX] notice is deliberately generic -- publisher.deliver_owner
strips every digit so a notice landing on a numbered permission menu cannot
select an option -- so it can never name the exchange_id or a count. Two
notices arriving mid-turn are indistinguishable, and an owner that reads only
the newest file silently drops the other (2026-10-22, oex_..._278f218e). The
pending set is therefore derived from DISK on every call, never from notices:

  pending = messages/*.md
            - replies/<id>.md          (reply written, awaiting pickup)
            - replies/sent/<id>.md     (reply delivered)
            - handled.tsv entries      (explicit non-reply disposition)

handled.tsv lines: <exchange_id> TAB <class> TAB <ref> TAB <note>
  class: answered_elsewhere | superseded | held | triaged_historic
  ref:   the exchange_id that carried the answer / superseded it ('-' if none)
A disposition is recorded with --mark; it is append-only (latest line wins)
and NEVER executes anything. Restart-safe by construction: no in-memory state.

  owner-inbox-pending.py <label> [--since YYYYMMDDTHHMMSSZ]
  owner-inbox-pending.py <label> --mark <id> <class> <ref> <note...>
Exit 0 always for listing; prints 'PENDING <n>' then one id per line.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

CLASSES = {"answered_elsewhere", "superseded", "held", "triaged_historic"}
ID_RE = re.compile(r"^oex_\d{8}T\d{6}Z_[0-9a-f]{8}$")


def root(label: str) -> Path:
    base = Path(os.environ.get("HERDR_INBOX_ROOT", Path.home() / ".local/state/herdr/inbox"))
    return base / label


def dispositions(d: Path) -> dict[str, tuple[str, str]]:
    out: dict[str, tuple[str, str]] = {}
    f = d / "handled.tsv"
    if not f.exists():
        return out
    for line in f.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and ID_RE.match(parts[0]) and parts[1] in CLASSES:
            out[parts[0]] = (parts[1], parts[2])
    return out


def pending(label: str, since: str = "") -> list[str]:
    d = root(label)
    msgs = sorted(p.stem for p in (d / "messages").glob("oex_*.md") if ID_RE.match(p.stem))
    done = dispositions(d)
    res = []
    for x in msgs:
        if since and x[4:20] < since:
            continue
        if (d / "replies" / f"{x}.md").exists() or (d / "replies" / "sent" / f"{x}.md").exists():
            continue
        if x in done:
            continue
        res.append(x)
    return res


def mark(label: str, xid: str, cls: str, ref: str, note: str) -> None:
    if not ID_RE.match(xid) or cls not in CLASSES or not (ref == "-" or ID_RE.match(ref)):
        sys.exit(f"refused: id/class/ref invalid (classes: {sorted(CLASSES)})")
    d = root(label)
    if not (d / "messages" / f"{xid}.md").exists():
        sys.exit(f"refused: no message {xid}")
    note = note.replace("\t", " ").replace("\n", " ")
    with open(d / "handled.tsv", "a") as fh:
        fh.write(f"{xid}\t{cls}\t{ref}\t{note}\n")
        fh.flush()
        os.fsync(fh.fileno())


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    label = argv[0]
    if len(argv) >= 5 and argv[1] == "--mark":
        mark(label, argv[2], argv[3], argv[4], " ".join(argv[5:]))
        return 0
    since = argv[2] if len(argv) >= 3 and argv[1] == "--since" else ""
    p = pending(label, since)
    print(f"PENDING {len(p)}")
    for x in p:
        print(x)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
