#!/usr/bin/env python3
"""owner-lease-reap.py — one DRY-RUN-ONLY stale-pane reap report (OFF BY
DEFAULT, INERT here). No arguments; no --apply flag exists anywhere in this
file. Design: docs/design/lease-reap-wiring.md; S4(c) SPEC + DESIGN §3b.

Refuses unless HERDR_OWNER_LEASE_REAP == "1" and HERDR_OWNER_LEASE_DB names
an existing, migrated, private lease DB (never created or migrated here).
The lease store is opened READ-ONLY (sqlite3 `mode=ro` URI, via
lib/private_sqlite.open_private): any write attempt fails at SQLite, not
here. reap_tick() is then called with its own dry_run=True default, and
there is no parameter, flag or env read in this file that reaches
reap(dry_run=False).

Probe: `herdr pane list`, a single subprocess with a 5s timeout,
`captured_at` recorded BEFORE the call (a clock read before the RPC can only
make the snapshot look OLDER than it is, which only ever makes
plan_reap()'s claimed-after-snapshot hold MORE conservative, never less).
Any OSError, TimeoutExpired, non-zero exit or empty stdout gives
payload=None, which lib/owner_lease_reap.reap_tick() turns into a
whole-tick `probe_unavailable` SKIP: zero candidates, zero holds, nothing
reaped that tick. That is the fail-safe for "the probe failed or timed out:
treat every pane as alive".

Every run appends one JSON report line to HERDR_OWNER_LEASE_REAP_LOG
(default ~/.local/state/herdr/owner-lease-reap.jsonl), opened 0600 with
O_APPEND|O_CREAT|O_NOFOLLOW (lib/queue_supervisor.py Lane.append pattern).
This full record is the phase-3 acceptance evidence; the hub's own live log
keeps only a short summary line.

Exit: 0 report written (status ok OR skip); 4 refused:flags_off or
refused:lease_<private_sqlite reason> (store never opened read/write, never
created); 3 error_<ExceptionType> (a SQLite error during the tick -- the
report line is still appended if the log file itself opens).
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import owner_lease_reap as olr  # noqa: E402
import private_sqlite  # noqa: E402

DEFAULT_LOG = str(Path.home() / ".local" / "state" / "herdr" / "owner-lease-reap.jsonl")


def _probe() -> tuple[str | None, int | None]:
    """`herdr pane list` -> (stdout, returncode). (None, rc) on any failure:
    non-zero exit, empty stdout, a timeout, or the binary not existing."""
    try:
        proc = subprocess.run(["herdr", "pane", "list"], capture_output=True, text=True, timeout=5)
    except (subprocess.TimeoutExpired, OSError):
        return None, None
    if proc.returncode != 0 or not proc.stdout:
        return None, proc.returncode
    return proc.stdout, proc.returncode


def _append_report(log_path: str, rec: dict) -> None:
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, (json.dumps(rec, sort_keys=True) + "\n").encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def main(environ=os.environ) -> int:
    os.umask(0o077)
    if environ.get("HERDR_OWNER_LEASE_REAP") != "1" or not environ.get("HERDR_OWNER_LEASE_DB"):
        print("refused:flags_off")
        return 4
    log_path = environ.get("HERDR_OWNER_LEASE_REAP_LOG") or DEFAULT_LOG
    db = environ["HERDR_OWNER_LEASE_DB"]

    captured_at = time.time()  # BEFORE the probe: see module docstring.
    payload, probe_rc = _probe()

    try:
        conn = private_sqlite.open_private(
            db, lambda p: sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=3, isolation_level=None),
            require_table="owner_leases")
    except ValueError as exc:
        print(f"refused:lease_{exc}")
        return 4
    try:
        try:
            res = olr.reap_tick(conn, payload, captured_at)
        except sqlite3.Error as exc:
            try:
                _append_report(log_path, {"at": time.time(), "captured_at": captured_at, "probe_rc": probe_rc,
                                           "status": "error", "reason": f"error_{type(exc).__name__}"})
            except OSError:
                pass
            print(f"error_{type(exc).__name__}")
            return 3
    finally:
        conn.close()

    _append_report(log_path, {"at": time.time(), "captured_at": captured_at, "probe_rc": probe_rc, **res})
    if res["status"] == "ok":
        would, held = res.get("would_reap", []), res.get("held", [])
        labels = sorted({o["label"] for o in would} | {h["label"] for h in held})
        print(f"reap-dry ok would={len(would)} held={len(held)} labels={labels}")
    else:
        print(f"reap-dry skip {res.get('reason')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
