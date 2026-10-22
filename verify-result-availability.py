#!/usr/bin/env python3
"""Offline scratch proofs for lib/result_availability.py. No live registry,
pane, network or herdr call: the lease holder and the notice sender are fakes."""
from __future__ import annotations

import os
import sqlite3
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import result_availability as ra  # noqa: E402

FAILS: list[str] = []
T0 = 1_800_000_000.0
OWNER = ("pane-1", "birth-1", 3)


def case(name, ok):
    print(("OK   " if ok else "FAIL ") + name)
    if not ok:
        FAILS.append(name)


def raises(fn):
    try:
        fn()
    except ra.Refused:
        return True
    return False


class Notices:
    def __init__(self, result=True):
        self.sent, self.result = [], result

    def __call__(self, text):
        self.sent.append(text)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def setup(root: Path, rid: str, req=b"REQ do the thing\n"):
    d = root / rid
    d.mkdir()
    (d / "request.txt").write_bytes(req)
    return d, req


def main() -> int:
    root = Path(os.path.realpath(tempfile.mkdtemp()))
    holder = lambda label: OWNER if label == "kb" else None  # noqa: E731

    # --- default off ---
    case("flag unset: from_env is None (no scan, no DB)",
         ra.from_env({"HERDR_RESULT_AVAILABILITY_DB": str(root / "x.db")}) is None and not (root / "x.db").exists())
    case("flag on without DB: refuses", raises(lambda: ra.from_env({"HERDR_RESULT_AVAILABILITY": "1"})))

    a = ra.Availability(str(root / "ra.db"))

    # --- binding ---
    d, req = setup(root, "kbreq_ok")
    case("register binds request digest + owner + manifest",
         a.register("kbreq_ok", str(d), req, "kb", *OWNER, ["result.md", "run.out"], T0) == "registered")
    case("same binding again is idempotent",
         a.register("kbreq_ok", str(d), req, "kb", *OWNER, ["run.out", "result.md"], T0) == "already_registered")
    case("same id, changed request text: refused (no inherited binding)",
         raises(lambda: a.register("kbreq_ok", str(d), b"other", "kb", *OWNER, ["result.md"], T0)))
    case("same id, different owner generation: refused",
         raises(lambda: a.register("kbreq_ok", str(d), req, "kb", "pane-1", "birth-1", 4, ["result.md", "run.out"], T0)))
    d2, req2 = setup(root, "kbreq_mm")
    case("dispatched text != request.txt on disk: refused",
         raises(lambda: a.register("kbreq_mm", str(d2), b"something else", "kb", *OWNER, ["result.md"], T0)))
    case("missing owner identity: refused",
         raises(lambda: a.register("kbreq_mm", str(d2), req2, "kb", "", "birth-1", 3, ["result.md"], T0)))
    case("dir not named after rid: refused",
         raises(lambda: a.register("kbreq_zz", str(d2), req2, "kb", *OWNER, ["result.md"], T0)))
    for bad in (["../x"], ["a/b"], [".hidden"], ["request.txt"], [], [f"f{i}" for i in range(9)], ["a", "a"]):
        case(f"manifest {bad[:2]}…: refused", raises(lambda b=bad: a.register("kbreq_mm", str(d2), req2, "kb", *OWNER, b, T0)))
    link = root / "kbreq_ln"
    link.symlink_to(d2)
    case("symlinked request dir: refused",
         raises(lambda: a.register("kbreq_ln", str(link), req2, "kb", *OWNER, ["result.md"], T0)))
    case("unregistered (legacy) dir is unverified_held, never scanned",
         a.state("kbreq_legacy")[0] == "unverified_held" and ra.classify_unregistered(root) == "unverified_held")

    # --- happy path with stability, staging, notice ---
    n = Notices()
    case("nothing written yet: pending, no notice", a.tick(holder, n, T0 + 1)["kbreq_ok"] == "pending" and not n.sent)
    (d / "result.md").write_text("ACK kbreq_ok\nbody")
    case("partial manifest: still pending", a.tick(holder, n, T0 + 2)["kbreq_ok"] == "pending")
    (d / "run.out").write_text("log")
    case("first full observation: observing", a.tick(holder, n, T0 + 3)["kbreq_ok"] == "observing")
    (d / "run.out").write_text("log more")
    case("changed before stable: observing again (not staged)", a.tick(holder, n, T0 + 4)["kbreq_ok"] == "observing")
    case("stable across two ticks: staged", a.tick(holder, n, T0 + 5)["kbreq_ok"] == "staged" and not n.sent)
    case("staged -> notified with fixed text, once",
         a.tick(holder, n, T0 + 6)["kbreq_ok"] == "notified" and len(n.sent) == 1
         and n.sent[0].startswith("RESULT AVAILABLE (UNVERIFIED") and "body" not in n.sent[0] and "log" not in n.sent[0])
    case("duplicate tick after notice: no second notice", "kbreq_ok" not in a.tick(holder, n, T0 + 7) and len(n.sent) == 1)

    def staged(rid, req=b"REQ x\n", owner=OWNER):
        dd, rq = setup(root, rid, req)
        a.register(rid, str(dd), rq, "kb", *owner, ["result.md"], T0)
        (dd / "result.md").write_text("r")
        a.tick(holder, Notices(), T0)
        a.tick(holder, Notices(), T0)
        assert a.state(rid)[0] == "staged", a.state(rid)
        return dd

    # --- changed content after staging ---
    dc = staged("kbreq_chg")
    (dc / "result.md").write_text("r2")
    n = Notices()
    case("CHANGED after staging: held:changed, no notice (no inherited observation)",
         a.tick(holder, n, T0 + 10)["kbreq_chg"] == "held:changed" and not n.sent)
    (dc / "result.md").write_text("r")
    case("held:changed is terminal even if reverted", "kbreq_chg" not in a.tick(holder, n, T0 + 11) and not n.sent)

    # --- request text changed after registration ---
    dq = staged("kbreq_req")
    (dq / "request.txt").write_text("tampered")
    case("request.txt changed: held:request_changed, no notice",
         a.tick(holder, n, T0 + 12)["kbreq_req"] == "held:request_changed" and not n.sent)

    # --- stale generation ---
    staged("kbreq_gen")
    newer = lambda label: ("pane-1", "birth-1", 4)  # noqa: E731
    case("lease moved to a new generation: held:stale_generation, no notice",
         a.tick(newer, n, T0 + 13)["kbreq_gen"] == "held:stale_generation" and not n.sent)
    staged("kbreq_gone")
    case("no lease holder: held:stale_generation",
         a.tick(lambda label: None, n, T0 + 14)["kbreq_gone"] == "held:stale_generation" and not n.sent)

    # --- symlinked artifact ---
    ds, rq = setup(root, "kbreq_sym")
    a.register("kbreq_sym", str(ds), rq, "kb", *OWNER, ["result.md"], T0)
    (root / "outside.md").write_text("secret")
    (ds / "result.md").symlink_to(root / "outside.md")
    a.tick(holder, n, T0 + 15)
    case("symlinked artifact never observed (stays pending)",
         a.tick(holder, n, T0 + 16)["kbreq_sym"] == "pending" and not n.sent)

    # --- crash boundaries ---
    staged("kbreq_pre")
    a.close()
    a = ra.Availability(str(root / "ra.db"))
    n = Notices()
    case("CRASH before notice boundary: staged survives restart and notifies once",
         a.tick(holder, n, T0 + 20)["kbreq_pre"] == "notified" and len(n.sent) == 1)
    staged("kbreq_mid")
    a.conn.execute("UPDATE ra_requests SET state='notifying' WHERE rid='kbreq_mid'")  # crash after the commit
    a.close()
    a = ra.Availability(str(root / "ra.db"))
    n = Notices()
    case("CRASH after notifying commit: ambiguous, never retried",
         a.tick(holder, n, T0 + 21)["kbreq_mid"] == "ambiguous" and not n.sent
         and "kbreq_mid" not in a.tick(holder, n, T0 + 22) and not n.sent)
    staged("kbreq_err")
    n = Notices(RuntimeError("deliver timed out"))
    case("notice raises: ambiguous, not retried",
         a.tick(holder, n, T0 + 23)["kbreq_err"] == "ambiguous" and len(n.sent) == 1
         and "kbreq_err" not in a.tick(holder, n, T0 + 24) and len(n.sent) == 1)
    staged("kbreq_ord")
    order = []
    def watch(text):
        order.append(a.conn.execute("SELECT state FROM ra_requests WHERE rid='kbreq_ord'").fetchone()[0])
        return True
    a.tick(holder, watch, T0 + 25)
    case("notifying is committed BEFORE the external call", order == ["notifying"]
         and sqlite3.connect(str(root / "ra.db")).execute(
             "SELECT state FROM ra_requests WHERE rid='kbreq_ord'").fetchone()[0] == "notified")
    a.close()

    print(f"{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failing")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
