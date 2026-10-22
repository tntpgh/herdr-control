#!/usr/bin/env python3
"""Offline: temp sqlite only."""
import importlib.util
import multiprocessing as mp
import os
import sys
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("wg", Path(__file__).with_name("lib") / "worker-grant.py")
wg = importlib.util.module_from_spec(spec); spec.loader.exec_module(wg)
FUTURE, PAST = "2999-01-01T00:00:00Z", "2000-01-01T00:00:00Z"
passed = failed = 0


def check(name, cond):
    global passed, failed
    passed += bool(cond); failed += not cond
    print(("ok   " if cond else "FAIL ") + name)


def refused(fn):
    try:
        fn(); return False
    except wg.Refused:
        return True


def fresh():
    p = tempfile.mktemp(suffix=".sqlite3"); db = wg.connect(p); wg.schema(db)
    wg.mint(db, "g1", "oex_test", 2, 1, FUTURE, "human:test")
    return p, db


def _race(path, tid, q):
    try:
        wg.claim(wg.connect(path), "g1", tid, "implement"); q.put("won")
    except wg.Refused:
        q.put("refused")


if __name__ == "__main__":
    p, db = fresh()
    check("no such grant refused", refused(lambda: wg.claim(db, "nope", "t0", "implement")))
    wg.claim(db, "g1", "t1", "implement"); wg.claim(db, "g1", "t2", "debug")
    check("third worker (REVIEW class) refused at cap 2 (the 15:24Z case)",
          refused(lambda: wg.claim(db, "g1", "t3", "review")))
    check("smoke has its own pool: one smoke allowed with workers full", wg.claim(db, "g1", "s1", "smoke")["pool"] == "smoke")
    check("second smoke refused", refused(lambda: wg.claim(db, "g1", "s2", "smoke")))
    check("same task cannot claim twice", refused(lambda: wg.claim(db, "g1", "t1", "implement")))
    db.execute("INSERT INTO tasks VALUES ('t1','lost')")
    db.execute("INSERT INTO tasks VALUES ('t2','running')")
    check("terminal task frees its slot", wg.claim(db, "g1", "t4", "review")["live_after"] == 2)
    check("running task still holds; cap enforced", refused(lambda: wg.claim(db, "g1", "t5", "plan")))
    check("registered task cannot be released early", refused(lambda: wg.release_unused(db, "t2")))
    wg.release_unused(db, "t4")
    check("unregistered failed spawn releases its claim", wg.claim(db, "g1", "t6", "plan")["live_after"] == 2)
    wg.mint(db, "gx", "oex_x", 5, 0, PAST, "human:test")
    check("expired grant refused", refused(lambda: wg.claim(db, "gx", "e1", "implement")))
    db.execute("UPDATE worker_grants SET revoked=1 WHERE grant_id='g1'")
    check("revoked grant refused", refused(lambda: wg.claim(db, "g1", "r1", "implement")))
    check("minting is not a CLI verb", wg.main(["x", p, "mint", "g9", "s", "9"]) == 2)
    os.unlink(p)

    # Race: 8 processes for 2 slots -> exactly 2 win.
    p, db = fresh(); q = mp.Queue()
    procs = [mp.Process(target=_race, args=(p, f"r{i}", q)) for i in range(8)]
    [x.start() for x in procs]; [x.join() for x in procs]
    res = [q.get() for _ in procs]
    check(f"8 concurrent claims on cap 2 -> exactly 2 won (got {res.count('won')})", res.count("won") == 2)
    os.unlink(p)

    print(f"worker-grant: {passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
