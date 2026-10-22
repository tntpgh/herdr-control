#!/usr/bin/env python3
"""verify-owner-lease.py — offline synthetic proofs for lib/owner_lease.py.

Real SQLite file, real separate processes for the concurrency cases; no
registry, panes or network. Each case prints OK/FAIL; exit 1 on any FAIL.

  python3 verify-owner-lease.py
"""
import multiprocessing as mp
import os
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import owner_lease as ol  # noqa: E402

# Same columns as lib/claims.sh's claims table (v5, with generation).
CLAIMS_DDL = """CREATE TABLE claims (
  claim_id TEXT PRIMARY KEY, scope TEXT NOT NULL, pane_id TEXT NOT NULL DEFAULT '',
  pane_birth TEXT NOT NULL DEFAULT '', purpose TEXT NOT NULL DEFAULT '', parent TEXT NOT NULL DEFAULT '',
  claimed_at TEXT NOT NULL, renewed_at TEXT NOT NULL, expires_at TEXT NOT NULL, released_at TEXT,
  generation INTEGER NOT NULL DEFAULT 1)"""

T0 = 1_792_000_000.0
FAILS = []


def fresh_db():
    fd, path = tempfile.mkstemp(suffix=".sqlite3")
    os.close(fd)
    c = ol.connect(path)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute(CLAIMS_DDL)
    ol.ensure_queue_table(c)
    c.close()
    return path


def case(name, cond):
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def _race_acquire(args):
    path, i = args
    c = ol.connect(path)
    try:
        return ("won", ol.acquire(c, "kb", f"w1:p{i}", f"term_{i}", 600, T0))
    except ol.LeaseConflict:
        return ("lost", None)
    finally:
        c.close()


def _race_enqueue(args):
    path, gen, i = args
    c = ol.connect(path)
    try:
        return ol.enqueue(c, "kb", gen, f"req_{i}", bound=5, now=T0)
    except ol.QueueFull:
        return "full"
    finally:
        c.close()


def main():
    ctx = mp.get_context("spawn")

    # 1. lease CAS under real concurrency: exactly one winner, generation 1.
    p = fresh_db()
    with ctx.Pool(8) as pool:
        res = pool.map(_race_acquire, [(p, i) for i in range(16)])
    wins = [g for r, g in res if r == "won"]
    case("CAS: 16 concurrent contenders -> exactly 1 winner, gen 1", wins == [1])
    c = ol.connect(p)
    case("CAS: exactly 1 live owner row", c.execute("SELECT COUNT(*) FROM claims WHERE released_at IS NULL").fetchone()[0] == 1)

    # 2. renewal keeps generation; a different pane conflicts.
    holder = c.execute("SELECT pane_id, pane_birth FROM claims").fetchone()
    case("renewal by same pane+birth keeps generation", ol.acquire(c, "kb", *holder, 600, T0 + 10) == 1)
    try:
        ol.acquire(c, "kb", "w9:p9", "term_9", 600, T0 + 20)
        case("different holder while live -> LeaseConflict", False)
    except ol.LeaseConflict:
        case("different holder while live -> LeaseConflict", True)
    case("same pane id, recycled birth -> conflict, not renewal",
         _raises(lambda: ol.acquire(c, "kb", holder[0], "term_recycled", 600, T0 + 21), ol.LeaseConflict))

    # 3. restart: a new connection (process restart) sees the same lease and generation.
    c.close()
    c = ol.connect(p)
    case("restart: lease + generation survive reconnect", ol.acquire(c, "kb", *holder, 600, T0 + 30) == 1)

    # 4. stale generation: release + new holder -> gen 2; gen-1 deliveries fenced out.
    case("holder releases its own gen", ol.release(c, "kb", 1, T0 + 40))
    g2 = ol.acquire(c, "kb", "w2:p1", "term_new", 600, T0 + 41)
    case("re-lease bumps generation to 2", g2 == 2)
    case("delivery at stale gen 1 -> FencedOut", _raises(lambda: ol.check_fence(c, "kb", 1, T0 + 42), ol.FencedOut))
    case("enqueue at stale gen 1 -> FencedOut (nothing queued)",
         _raises(lambda: ol.enqueue(c, "kb", 1, "req_stale", now=T0 + 42), ol.FencedOut)
         and c.execute("SELECT COUNT(*) FROM owner_requests").fetchone()[0] == 0)
    case("stale holder cannot release its successor", ol.release(c, "kb", 1, T0 + 43) is False)

    # 5. expired lease: anyone may take it; generation still monotonic.
    g3 = ol.acquire(c, "kb", "w3:p1", "term_3", 600, T0 + 41 + 601)
    case("expired lease -> new holder gets gen 3 (monotonic over history)", g3 == 3)
    case("gen 2 fenced after expiry takeover", _raises(lambda: ol.check_fence(c, "kb", 2, T0 + 700), ol.FencedOut))
    c.close()

    # 6. queue bound under real concurrency: 20 racing enqueues, bound 5 -> exactly 5 queued.
    p = fresh_db()
    c = ol.connect(p)
    gen = ol.acquire(c, "kb", "w1:p1", "term_1", 600, T0)
    c.close()
    with ctx.Pool(8) as pool:
        res = pool.map(_race_enqueue, [(p, gen, i) for i in range(20)])
    c = ol.connect(p)
    case("bound: 20 concurrent enqueues, bound 5 -> exactly 5 queued, 15 full",
         res.count("queued") == 5 and res.count("full") == 15
         and c.execute("SELECT COUNT(*) FROM owner_requests").fetchone()[0] == 5)
    queued = [r[0] for r in c.execute("SELECT request_id FROM owner_requests ORDER BY request_id")]
    case("idempotent retry of a queued id -> 'duplicate', no new row",
         ol.enqueue(c, "kb", gen, queued[0], now=T0 + 1) == "duplicate"
         and c.execute("SELECT COUNT(*) FROM owner_requests").fetchone()[0] == 5)
    case("6th distinct request refused while 5 open", _raises(lambda: ol.enqueue(c, "kb", gen, "req_x", now=T0 + 2), ol.QueueFull))
    case("ack -> done frees a slot; next request queues",
         ol.transition(c, queued[0], "acked", T0 + 3) and ol.transition(c, queued[0], "done", T0 + 4)
         and ol.enqueue(c, "kb", gen, "req_x", now=T0 + 5) == "queued")
    case("done cannot be re-acked", ol.transition(c, queued[0], "acked", T0 + 6) is False)

    # 7. stale-owner detection + reap: dry-run changes nothing; real reap releases row only.
    live = {("w1:p1", "term_1")}
    case("live holder is not stale", ol.stale_owners(c, live, T0 + 10) == [])
    gone = ol.reap(c, set(), T0 + 10)  # dry-run
    case("pane gone -> reported stale (dry-run)", [s["reason"] for s in gone] == ["pane-gone"])
    case("dry-run leaves the lease live", ol.check_fence(c, "kb", gen, T0 + 11) is None)
    done = ol.reap(c, set(), T0 + 12, dry_run=False)
    case("real reap releases the lease", done and done[0].get("released") is True
         and _raises(lambda: ol.check_fence(c, "kb", gen, T0 + 13), ol.FencedOut))
    case("expired lease is stale even if pane is live",
         [s["reason"] for s in ol.stale_owners(_with_lease(), live, T0 + 10_000)] == ["expired"])
    c.close()

    print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing")
    sys.exit(1 if FAILS else 0)


def _with_lease():
    c = ol.connect(fresh_db())
    ol.acquire(c, "kb", "w1:p1", "term_1", 600, T0)
    return c


def _raises(fn, exc):
    try:
        fn()
    except exc:
        return True
    return False


if __name__ == "__main__":
    main()
