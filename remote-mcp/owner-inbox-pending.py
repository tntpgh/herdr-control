#!/usr/bin/env python3
"""List every owner-inbox exchange that still needs handling, oldest first.

Why: the typed [INBOX] notice is deliberately generic -- publisher.deliver_owner
strips every digit so a notice landing on a numbered permission menu cannot
select an option -- so it can never name the exchange_id or a count. Two
notices arriving mid-turn are indistinguishable, and an owner that reads only
the newest file silently drops the other (2026-10-22). The pending set is
therefore derived from DISK on every call, never from notices:

  pending = messages/<id>.md - replies/<id>.md - replies/sent/<id>.md
            - handled.tsv dispositions (answered_elsewhere | superseded | triaged_historic)
  held    = handled.tsv 'held' entries: NOT pending, but always listed with age,
            so a held item is never hidden.

handled.tsv lines: <exchange_id> TAB <class> TAB <ref> TAB <note>
  ref: the exchange_id that answered/superseded it ('-' only for held/triaged_historic);
       must name an existing message of the same label and differ from <id>.
Append-only via --mark; NEVER executes anything; restart-safe (no memory state).

Fail-closed: a bad label, a symlinked or escaping path, an unreadable/corrupt/
non-UTF-8 handled.tsv, or conflicting duplicate dispositions -> 'ERROR <why>'
on stdout and exit 3. Nothing is then reported as pending OR as handled.

  owner-inbox-pending.py <label> [--since YYYYMMDDTHHMMSS]
  owner-inbox-pending.py <label> --mark <id> <class> <ref> <note...>
Output: 'PENDING <n> oldest_age_s=<s>' then ids; 'HELD <n>' then '<id> age_s=<s>'.
"""
from __future__ import annotations

import os
import re
import stat
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,40}$")          # == publisher.OWNER_LABEL_RE
ID_RE = re.compile(r"^oex_(\d{8}T\d{6})Z_[0-9a-f]{8}$")
CLASSES = {"answered_elsewhere", "superseded", "held", "triaged_historic"}
NEEDS_REF = {"answered_elsewhere", "superseded"}


class Refused(Exception):
    pass


def inbox_root() -> Path:
    return Path(os.environ.get("HERDR_INBOX_ROOT", Path.home() / ".local/state/herdr/inbox"))


def _real_dir(p: Path, root: Path) -> Path:
    """p must exist, be a real directory (not a symlink) and resolve exactly under root."""
    try:
        st = os.lstat(p)
    except OSError as e:
        raise Refused(f"missing {p.name}: {e.strerror}")
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise Refused(f"not a real directory: {p}")
    rp = p.resolve(strict=True)
    if rp != root / p.relative_to(root):
        raise Refused(f"escapes inbox root: {p}")
    return rp


def label_dir(label: str) -> Path:
    if not LABEL_RE.match(label):
        raise Refused(f"bad label {label!r}")
    try:
        root = inbox_root().resolve(strict=True)
    except (OSError, RuntimeError) as e:
        raise Refused(f"inbox root unavailable: {e}")
    d = root / label
    _real_dir(d, root)
    for sub in ("messages", "replies", "replies/sent"):
        if sub != "messages" and not os.path.lexists(d / sub):
            continue  # replies/ may legitimately not exist yet
        _real_dir(d / sub, root)
    return d


def _ids(dirpath: Path) -> set[str]:
    if not os.path.lexists(dirpath):
        return set()
    out = set()
    for e in os.scandir(dirpath):
        stem = e.name[:-3] if e.name.endswith(".md") else None
        if stem and ID_RE.match(stem) and e.is_file(follow_symlinks=False):
            out.add(stem)
    return out


def dispositions(d: Path, messages: set[str]) -> dict[str, tuple[str, str]]:
    f = d / "handled.tsv"
    if not os.path.lexists(f):
        return {}
    try:
        fd = os.open(f, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as fh:
            raw = fh.read()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise Refused(f"handled.tsv unreadable: {e}")
    if text and not text.endswith("\n"):
        raise Refused("handled.tsv truncated (no trailing newline)")
    out: dict[str, tuple[str, str]] = {}
    for n, line in enumerate(text.splitlines(), 1):
        parts = line.split("\t")
        if len(parts) != 4:
            raise Refused(f"handled.tsv line {n}: expected 4 fields")
        xid, cls, ref, _note = parts
        _validate(xid, cls, ref, messages, where=f"handled.tsv line {n}")
        if xid in out and out[xid] != (cls, ref):
            raise Refused(f"handled.tsv line {n}: conflicting disposition for {xid}")
        out[xid] = (cls, ref)
    return out


def _validate(xid: str, cls: str, ref: str, messages: set[str], where: str) -> None:
    if not ID_RE.match(xid) or xid not in messages:
        raise Refused(f"{where}: no such message {xid!r}")
    if cls not in CLASSES:
        raise Refused(f"{where}: unknown class {cls!r}")
    if cls in NEEDS_REF:
        if ref == xid or ref not in messages:
            raise Refused(f"{where}: ref must be a different existing message")
    elif ref != "-" and ref not in messages:
        raise Refused(f"{where}: ref must be '-' or an existing message")


def age_s(xid: str, now: float) -> int:
    m = ID_RE.match(xid)
    t = datetime.strptime(m.group(1), "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc).timestamp()
    return max(0, int(now - t))


def report(label: str, since: str = "") -> list[str]:
    d = label_dir(label)
    msgs = _ids(d / "messages")
    replied = _ids(d / "replies") | _ids(d / "replies" / "sent")
    disp = dispositions(d, msgs)
    now = time.time()
    keep = [x for x in sorted(msgs) if not since or ID_RE.match(x).group(1) >= since]
    pending = [x for x in keep if x not in replied and x not in disp]
    held = [x for x in keep if x not in replied and disp.get(x, ("",))[0] == "held"]
    oldest = age_s(pending[0], now) if pending else 0
    lines = [f"PENDING {len(pending)} oldest_age_s={oldest}", *pending, f"HELD {len(held)}"]
    lines += [f"{x} age_s={age_s(x, now)}" for x in held]
    return lines


def mark(label: str, xid: str, cls: str, ref: str, note: str) -> None:
    d = label_dir(label)
    msgs = _ids(d / "messages")
    _validate(xid, cls, ref, msgs, where="--mark")
    existing = dispositions(d, msgs)
    if xid in existing and existing[xid] != (cls, ref):
        raise Refused(f"--mark: conflicts with recorded disposition {existing[xid]}")
    note = note.replace("\t", " ").replace("\n", " ").replace("\r", " ")
    f = d / "handled.tsv"
    created = not os.path.lexists(f)
    try:
        fd = os.open(f, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        raise Refused(f"handled.tsv not appendable: {e}")
    try:
        os.write(fd, f"{xid}\t{cls}\t{ref}\t{note}\n".encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    if created:  # make the new directory entry itself durable
        dfd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    try:
        if len(argv) >= 5 and argv[1] == "--mark":
            mark(argv[0], argv[2], argv[3], argv[4], " ".join(argv[5:]))
            return 0
        since = argv[2] if len(argv) >= 3 and argv[1] == "--since" else ""
        print("\n".join(report(argv[0], since)))
        return 0
    except Refused as e:
        print(f"ERROR {e}")
        return 3
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
