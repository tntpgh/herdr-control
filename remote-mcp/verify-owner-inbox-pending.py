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


def run(root: Path, *args: str) -> tuple[int, list[str]]:
    p = subprocess.run([sys.executable, str(TOOL), "conductor", *args], capture_output=True, text=True,
                       env={**os.environ, "HERDR_INBOX_ROOT": str(root)})
    return p.returncode, (p.stdout + p.stderr).split()


def check(name: str, got, want) -> None:
    global fails
    ok = got == want
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}" + ("" if ok else f": got {got!r} want {want!r}"))


with tempfile.TemporaryDirectory() as t:
    root = Path(t)
    d = root / "conductor"
    (d / "messages").mkdir(parents=True)
    (d / "replies" / "sent").mkdir(parents=True)
    msg = lambda x: (d / "messages" / f"{x}.md").write_text("x")

    msg(A); msg(B)  # two notices arrive mid-turn, one second apart
    check("two mid-turn arrivals both pending, oldest first", run(root)[1], ["PENDING", "2", A, B])
    (d / "replies" / f"{B}.md").write_text("r")  # owner answers only the newest
    check("newest-only reply leaves the older one pending", run(root)[1], ["PENDING", "1", A])
    check("restart: state is disk-derived, identical on a fresh process", run(root)[1], ["PENDING", "1", A])
    msg(A)  # duplicate notice / retried delivery rewrites the same id
    check("duplicate notice does not duplicate the id", run(root)[1], ["PENDING", "1", A])
    (d / "replies" / f"{B}.md").unlink(); (d / "replies" / "sent" / f"{B}.md").write_text("r")
    check("reply moved to sent/ still counts as replied", run(root)[1], ["PENDING", "1", A])
    msg(C); msg(D)
    rc, _ = run(root, "--mark", C, "superseded", D, "D restates C")
    check("mark superseded accepted", rc, 0)
    check("superseded item leaves pending; superseder stays", run(root)[1], ["PENDING", "2", A, D])
    rc, out = run(root, "--mark", C, "done_lol", "-", "x")
    check("unknown class refused", (rc != 0, out[0]), (True, "refused:"))
    rc, out = run(root, "--mark", "oex_20990101T000000Z_deadbeef", "held", "-", "x")
    check("mark of a nonexistent message refused", (rc != 0, out[0]), (True, "refused:"))
    check("--since filters historic backlog without marking it", run(root, "--since", "20261022T014430")[1],
          ["PENDING", "1", D])
    check("handled.tsv is the only file the tool wrote", sorted(p.name for p in d.iterdir()),
          ["handled.tsv", "messages", "replies"])

print(f"{'ALL PASS' if not fails else f'{fails} FAILED'}")
sys.exit(1 if fails else 0)
