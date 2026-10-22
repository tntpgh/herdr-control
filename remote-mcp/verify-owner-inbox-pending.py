#!/usr/bin/env python3
"""Offline fixtures for owner-inbox-pending.py: temp inbox only, no network."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

TOOL = Path(__file__).with_name("owner-inbox-pending.py")
A, B, C, D = (f"oex_20261022T0144{n}Z_{h}" for n, h in
              (("26", "278f218e"), ("27", "edcaf8d7"), ("30", "aaaaaaaa"), ("31", "bbbbbbbb")))
fails = 0


def run(root: Path, *args: str, label: str = "conductor") -> tuple[int, list[str]]:
    p = subprocess.run([sys.executable, str(TOOL), label, *args], capture_output=True, text=True,
                       env={**os.environ, "HERDR_INBOX_ROOT": str(root)})
    return p.returncode, [ln.split(" oldest_age_s=")[0].split(" age_s=")[0] for ln in p.stdout.splitlines()]


def check(name: str, got, want) -> None:
    global fails
    ok = got == want
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}" + ("" if ok else f": got {got!r} want {want!r}"))


def err(res) -> tuple[int, str]:
    rc, out = res
    return rc, (out[0].split()[0] if out else "")


def inbox(root: Path, label: str = "conductor") -> Path:
    d = root / label
    (d / "messages").mkdir(parents=True)
    (d / "replies" / "sent").mkdir(parents=True)
    return d


with tempfile.TemporaryDirectory() as t:
    root = Path(t).resolve()
    d = inbox(root)
    msg = lambda x, dd=d: (dd / "messages" / f"{x}.md").write_text("x")
    H = d / "handled.tsv"

    msg(A); msg(B)
    check("two mid-turn arrivals both pending, oldest first", run(root)[1], ["PENDING 2", A, B, "HELD 0"])
    (d / "replies" / f"{B}.md").write_text("r")
    check("newest-only reply leaves the older one pending", run(root)[1], ["PENDING 1", A, "HELD 0"])
    check("restart: disk-derived, identical on a fresh process", run(root)[1], ["PENDING 1", A, "HELD 0"])
    msg(A)
    check("duplicate notice does not duplicate the id", run(root)[1], ["PENDING 1", A, "HELD 0"])
    (d / "replies" / f"{B}.md").unlink(); (d / "replies" / "sent" / f"{B}.md").write_text("r")
    check("reply in sent/ counts as replied", run(root)[1], ["PENDING 1", A, "HELD 0"])

    msg(C); msg(D)
    check("first create of handled.tsv via --mark", (run(root, "--mark", C, "superseded", D, "D restates C")[0],
          oct(H.stat().st_mode & 0o777)), (0, "0o600"))
    check("superseded leaves pending; superseder stays", run(root)[1], ["PENDING 2", A, D, "HELD 0"])
    run(root, "--mark", A, "held", "-", "awaiting T")
    check("held item is not pending but is listed", run(root)[1], ["PENDING 1", D, "HELD 1", A])
    check("same mark again is idempotent", run(root, "--mark", A, "held", "-", "again")[0], 0)
    check("conflicting --mark refused", err(run(root, "--mark", A, "triaged_historic", "-", "x")), (3, "ERROR"))
    check("superseded ref = self refused", err(run(root, "--mark", D, "superseded", D, "x")), (3, "ERROR"))
    check("answered_elsewhere ref missing refused",
          err(run(root, "--mark", D, "answered_elsewhere", "oex_20990101T000000Z_deadbeef", "x")), (3, "ERROR"))
    check("superseded with '-' ref refused", err(run(root, "--mark", D, "superseded", "-", "x")), (3, "ERROR"))
    check("unknown class refused", err(run(root, "--mark", D, "done_lol", "-", "x")), (3, "ERROR"))
    check("mark of nonexistent message refused",
          err(run(root, "--mark", "oex_20990101T000000Z_deadbeef", "held", "-", "x")), (3, "ERROR"))
    check("--since filters backlog without marking it", run(root, "--since", "20261022T014430")[1],
          ["PENDING 1", D, "HELD 0"])

    good = H.read_bytes()
    H.write_bytes(good + f"{A}\ttriaged_historic\t-\tconflict\n".encode())
    check("conflicting duplicate line in file fails closed", err(run(root)), (3, "ERROR"))
    H.write_bytes(good + b"\xff\xfe garbage\n")
    check("non-UTF-8 handled.tsv fails closed (held not resurrected)", err(run(root)), (3, "ERROR"))
    H.write_bytes(good + f"{D}\theld\t-\tpartial".encode())
    check("truncated last line fails closed", err(run(root)), (3, "ERROR"))
    H.write_bytes(good + b"only\ttwo\n")
    check("malformed line fails closed", err(run(root)), (3, "ERROR"))
    H.write_bytes(good)
    os.chmod(H, 0)
    check("unreadable handled.tsv fails closed", err(run(root)), (3, "ERROR") if os.geteuid() else (0, "PENDING"))
    os.chmod(H, 0o600)

    ext = Path(t).parent / f"ext-{os.getpid()}.tsv"; H.rename(ext); os.symlink(ext, H)
    check("symlinked handled.tsv refused on read", err(run(root)), (3, "ERROR"))
    check("symlinked handled.tsv refused on append", err(run(root, "--mark", D, "held", "-", "x")), (3, "ERROR"))
    H.unlink(); ext.rename(H)

    outside = Path(tempfile.mkdtemp(dir=t + "/..")); (outside / "messages").mkdir()
    os.symlink(outside, root / "evil")
    check("symlinked label dir refused", err(run(root, label="evil")), (3, "ERROR"))
    check("traversal label refused", err(run(root, label="../conductor")), (3, "ERROR"))
    check("uppercase/odd label refused", err(run(root, label="Conductor")), (3, "ERROR"))
    e2 = inbox(root, "escape-test"); (e2 / "messages").rmdir(); os.symlink(outside / "messages", e2 / "messages")
    check("symlinked messages/ refused", err(run(root, label="escape-test")), (3, "ERROR"))
    (outside / "messages" / f"{A}.md").write_text("x")
    o2 = inbox(root, "other"); msg(B, o2)
    check("same ids across labels stay separate", run(root, label="other")[1], ["PENDING 1", B, "HELD 0"])
    check("ref must exist in the SAME label",
          err(run(root, "--mark", B, "answered_elsewhere", A, "x", label="other")), (3, "ERROR"))
    os.symlink(outside / "messages" / f"{A}.md", o2 / "messages" / f"{C}.md")
    check("symlinked message file ignored", run(root, label="other")[1], ["PENDING 1", B, "HELD 0"])

print(f"{'ALL PASS' if not fails else f'{fails} FAILED'}")
sys.exit(1 if fails else 0)
