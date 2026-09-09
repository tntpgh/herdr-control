"""Claim-once updates for a decision record that two surfaces can answer.

A formserve decision lives in one JSON file that TWO processes write: the
form's own port (`formserve.py`) and the hub service (`hub.py`, launchd
`com.herdr-control.hub`). Both did:

    row = json.loads(path.read_text())
    if row["status"] != "open": return 409     # "first writer wins"
    row.update(status="answered", ...)
    path.write_text(json.dumps(row))           # truncate, then refill

The comment claimed first-writer-wins; the code could not deliver it. Nothing
holds between the read and the write, so both surfaces can see `open`, both
pass the guard, and the slower one silently overwrites the recorded answer —
including `answered_via`, which is the audit field saying WHERE the human
answered. And `write_text` truncates first: a crash or a full disk mid-write
leaves an unparseable decision record, which the dashboard and the poller both
treat as "no such decision".

For an approval record that is exactly the wrong failure. This module makes the
check-and-write one critical section (advisory `flock` on a sidecar) landing via
atomic rename, so the loser genuinely loses and the file is never half-written.

Advisory locking is enough here: both writers are ours, on one machine, on a
local filesystem. It is NOT enough across NFS or for a foreign process — if a
third surface ever answers forms, it imports this too.
"""

from __future__ import annotations

import fcntl
import json
import os
import tempfile
from pathlib import Path
from typing import Any, Callable


class NotClaimable(Exception):
    """The record was not in a claimable state; carries the state it was in."""

    def __init__(self, state: str, row: dict[str, Any]):
        super().__init__(state)
        self.state = state
        self.row = row


def write_atomic(path: Path, data: dict[str, Any], *, indent: int = 1) -> None:
    """Replace `path` with `data`, atomically. Never leaves a partial file."""
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=indent)
            f.flush()
            os.fsync(f.fileno())          # rename is atomic; the CONTENT still has to be on disk
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def claim_and_update(
    path: Path,
    mutate: Callable[[dict[str, Any]], dict[str, Any]],
    *,
    require_status: str = "open",
    indent: int = 1,
) -> dict[str, Any]:
    """Re-read under an exclusive lock, verify the record is still claimable,
    apply `mutate`, and write the result atomically.

    The re-read inside the lock is the point: the caller's earlier read (for
    token checks, rendering) is stale by the time we get here.

    Raises NotClaimable when another surface already answered, FileNotFoundError
    when the record is gone, and json.JSONDecodeError when it is corrupt — all
    conditions the caller must report rather than paper over.
    """
    path = Path(path)
    lock_path = path.with_suffix(path.suffix + ".lock")
    with open(lock_path, "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        row = json.loads(path.read_text(encoding="utf-8"))
        state = row.get("status")
        if require_status is not None and state != require_status:
            raise NotClaimable(str(state), row)
        row = mutate(row)
        write_atomic(path, row, indent=indent)
        return row
