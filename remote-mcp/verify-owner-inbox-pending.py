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
    check("--since is a view: authoritative count kept, older counted not hidden",
          run(root, "--since", "20261022T014432")[1],
          ["PENDING 1", "VIEW since=20261022T014432 shown=0 older_unanswered_not_shown=1", "HELD 1", A])
    check("bad --since (not a real UTC time) refused", err(run(root, "--since", "20261399T999999")), (3, "ERROR"))
    check("unknown flag -> usage exit 2", run(root, "--snice", "x")[0], 2)
    check("--mark missing note -> usage exit 2", run(root, "--mark", D, "held", "-")[0], 2)
    check("extra args after --since -> usage exit 2", run(root, "--since", "20261022T014430", "x")[0], 2)

    # restart with prior unanswered: a fresh process, no session state, still sees D
    msg_new = "oex_20261023T090000Z_cccccccc"; msg(msg_new)
    check("restart with prior unanswered: old D still pending next day", run(root)[1],
          ["PENDING 2", D, msg_new, "HELD 1", A])
    (d / "messages" / f"{msg_new}.md").unlink()

    # legitimate closure of a hold: a later reply resolves it, no conflict
    (d / "replies" / f"{A}.md").write_text("approved")
    check("held item later replied: closed (neither pending nor held)", run(root)[1], ["PENDING 1", D, "HELD 0"])
    check("closure did not need a conflicting mark; ledger still valid", run(root, "--mark", A, "held", "-", "same")[0], 0)
    (d / "replies" / f"{A}.md").unlink()

    # concurrency: two different marks for one id racing -> exactly one wins
    import concurrent.futures as cf
    E = "oex_20261022T014433Z_eeeeeeee"; msg(E)
    ok = 0
    for _ in range(8):
        H.write_bytes(H.read_bytes())  # unchanged
        with cf.ThreadPoolExecutor(2) as ex:
            r = list(ex.map(lambda c: run(root, "--mark", E, c[0], c[1], "race")[0],
                            [("held", "-"), ("superseded", D)]))
        rc_ok = sorted(r)
        lines = [l for l in H.read_text().splitlines() if l.startswith(E)]
        ok += rc_ok == [0, 3] and len({tuple(l.split("\t")[1:3]) for l in lines}) == 1
        H.write_text("".join(l + "\n" for l in H.read_text().splitlines() if not l.startswith(E)))
    check("concurrent different marks: exactly one succeeds, ledger unpoisoned (8 rounds)", ok, 8)
    (d / "messages" / f"{E}.md").unlink()

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
    check("symlinked message file -> ERROR (not silently skipped)", err(run(root, label="other")), (3, "ERROR"))
    (o2 / "messages" / f"{C}.md").unlink()
    os.symlink(outside / "messages" / f"{A}.md", o2 / "replies" / f"{B}.md")
    check("symlinked reply file -> ERROR (cannot fake a reply)", err(run(root, label="other")), (3, "ERROR"))
    (o2 / "replies" / f"{B}.md").unlink()
    (o2 / "replies" / "sent" / f"{B}.md").mkdir()
    check("directory named like a sent reply -> ERROR", err(run(root, label="other")), (3, "ERROR"))

print(f"{'ALL PASS' if not fails else f'{fails} FAILED'}")
sys.exit(1 if fails else 0)
