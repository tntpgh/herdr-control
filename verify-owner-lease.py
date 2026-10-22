#!/usr/bin/env python3
"""verify-owner-lease.py — offline synthetic proofs for lib/owner_lease.py.

Real SQLite files and real separate processes for the races; no registry,
panes or network. Prints OK/FAIL per case; exit 1 on any FAIL.

  python3 verify-owner-lease.py
"""
import multiprocessing as mp
import os
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import owner_lease as ol  # noqa: E402

T0 = 1_792_000_000.0
TTL = 600
FAILS = []


def case(name, cond):
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def raises(fn, exc):
    try:
        fn()
    except exc:
        return True
    return False


def fresh(label="kb", project="tntpgh/knowledge-base"):
    fd, path = tempfile.mkstemp(suffix=".sqlite3")
    os.close(fd)
    c = ol.connect(path)
    c.execute("PRAGMA journal_mode=WAL")
    ol.migrate(c)
    if label:
        ol.register_owner(c, label, project, T0)
    return path, c


def count(c, sql, *a):
    return c.execute(sql, a).fetchone()[0]


def _race_acquire(args):
    path, i = args
    c = ol.connect(path)
    try:
        return ("won", ol.acquire(c, "kb", f"w1:p{i}", f"term_{i}", TTL, T0))
    except ol.LeaseConflict:
        return ("lost", None)
    finally:
        c.close()


def _race_enqueue(args):
    path, gen, i = args
    c = ol.connect(path)
    try:
        return ol.enqueue(c, "kb", gen, "w1:p1", "term_1", f"req_{i:02d}", bound=5, now=T0)["state"]
    except ol.QueueFull:
        return "full"
    finally:
        c.close()


def main():
    ctx = mp.get_context("spawn")

    # --- schema / migration ---
    p, c = fresh(label=None)
    case("migrate is versioned and idempotent", ol.migrate(c) == 1 and count(c, "SELECT COUNT(*) FROM owner_schema_version") == 1)
    ol.register_owner(c, "kb", "tntpgh/knowledge-base", T0)
    case("events: DELETE rejected by trigger", raises(lambda: c.execute("DELETE FROM owner_events"), sqlite3.IntegrityError))
    case("events: UPDATE rejected by trigger", raises(lambda: c.execute("UPDATE owner_events SET kind='x'"), sqlite3.IntegrityError))
    case("DB itself forbids a second live lease row (partial unique index)",
         raises(lambda: [c.execute("INSERT INTO owner_leases(lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,expires_at) "
                                   "VALUES (?,?,?,?,?,?,?,?)", (f"x{i}", "kb", "p", "b", i, "a", "a", "z")) for i in (1, 2)],
                sqlite3.IntegrityError))
    c.close()

    # --- labels / canonical project mapping ---
    p, c = fresh(label=None)
    case("canonical project: URL forms collapse to tntpgh/<lower>",
         {ol.canonical_project(v) for v in ["tntpgh/Knowledge-Base", "https://github.com/tntpgh/knowledge-base.git",
                                             "git" + chr(64) + "github.com:tntpgh/knowledge-base.git", "github.com/tntpgh/knowledge-base/"]}
         == {"tntpgh/knowledge-base"})
    case("invalid labels refused", all(raises(lambda l=l: ol.register_owner(c, l, "tntpgh/a", T0), ol.InvalidOwner)
                                       for l in ["", "KB", "-kb", "kb owner", "a" * 49, "kb;drop"]))
    case("non-tntpgh / path-ish projects refused", all(raises(lambda v=v: ol.canonical_project(v), ol.InvalidOwner)
                                                       for v in ["other/kb", "tntpgh/../x", "/Users/x/Code/kb", "tntpgh/a/b"]))
    ol.register_owner(c, "knowledge-base", "tntpgh/knowledge-base", T0)
    case("same label+project re-register is idempotent", ol.register_owner(c, "knowledge-base", "github.com/tntpgh/knowledge-base", T0) == "tntpgh/knowledge-base")
    case("ADVERSARIAL: a second label cannot own the same project (any URL spelling)",
         raises(lambda: ol.register_owner(c, "kb-2", "https://github.com/tntpgh/Knowledge-Base.git", T0), ol.InvalidOwner))
    case("one label cannot own two projects", raises(lambda: ol.register_owner(c, "knowledge-base", "tntpgh/tourguide", T0), ol.InvalidOwner))
    case("unregistered label cannot acquire", raises(lambda: ol.acquire(c, "ghost", "w1:p1", "t", TTL, T0), ol.InvalidOwner))
    c.close()

    # --- lease CAS race ---
    p, c = fresh()
    c.close()
    with ctx.Pool(8) as pool:
        res = pool.map(_race_acquire, [(p, i) for i in range(16)])
    c = ol.connect(p)
    case("CAS: 16 concurrent contenders -> exactly 1 winner at gen 1", [g for r, g in res if r == "won"] == [1])
    holder = c.execute("SELECT pane_id, pane_birth FROM owner_leases").fetchone()
    case("renewal by same pane+birth keeps generation", ol.acquire(c, "kb", *holder, TTL, T0 + 10) == 1)
    case("same pane id with recycled birth -> conflict", raises(lambda: ol.acquire(c, "kb", holder[0], "recycled", TTL, T0 + 11), ol.LeaseConflict))
    c.close()
    c = ol.connect(p)
    case("restart: lease + generation survive reconnect", ol.acquire(c, "kb", *holder, TTL, T0 + 20) == 1)
    c.close()

    # --- fencing of every queue mutation ---
    p, c = fresh()
    H = ("w1:p1", "term_1")
    g1 = ol.acquire(c, "kb", *H, TTL, T0)
    ol.enqueue(c, "kb", g1, *H, "r1", now=T0)
    case("enqueue by wrong pane at the right gen -> FencedOut",
         raises(lambda: ol.enqueue(c, "kb", g1, "w9:p9", "term_1", "rX", now=T0), ol.FencedOut))
    case("transition by wrong birth -> FencedOut",
         raises(lambda: ol.transition(c, "r1", "delivering", "kb", g1, "w1:p1", "other", now=T0), ol.FencedOut))
    case("illegal transition queued -> replied refused",
         raises(lambda: ol.transition(c, "r1", "replied", "kb", g1, *H, now=T0), ol.InvalidTransition))
    case("caller cannot set 'stale'", raises(lambda: ol.transition(c, "r1", "stale", "kb", g1, *H, now=T0), ol.InvalidTransition))
    case("full disposition path queued->delivering->replied->evidence",
         [ol.transition(c, "r1", s, "kb", g1, *H, now=T0 + i) for i, s in enumerate(["delivering", "replied", "evidence"])]
         == ["delivering", "replied", "evidence"])
    ol.enqueue(c, "kb", g1, *H, "r2", now=T0)
    case("held -> queued -> blocked -> queued -> delivering -> timeout",
         [ol.transition(c, "r2", s, "kb", g1, *H, now=T0) for s in ["held", "queued", "blocked", "queued", "delivering", "timeout"]][-1] == "timeout")
    case("terminal timeout cannot be revived", raises(lambda: ol.transition(c, "r2", "queued", "kb", g1, *H, now=T0), ol.InvalidTransition))

    # --- STALE TRANSITION + SUCCESSOR QUEUE ---
    for i in range(3):
        ol.enqueue(c, "kb", g1, *H, f"old{i}", bound=5, now=T0 + 1)
    ol.transition(c, "old0", "delivering", "kb", g1, *H, now=T0 + 2)
    # holder vanishes; lease expires; successor takes over
    S = ("w2:p1", "term_2")
    g2 = ol.acquire(c, "kb", *S, TTL, T0 + TTL + 5)
    case("successor after expiry gets gen 2", g2 == 2)
    case("all open gen-1 requests disposed 'stale' in the same transaction",
         count(c, "SELECT COUNT(*) FROM owner_requests WHERE generation=1 AND state IN ('queued','held','blocked','delivering')") == 0
         and count(c, "SELECT COUNT(*) FROM owner_requests WHERE state='stale'") == 3)
    case("terminal gen-1 outcomes kept (not rewritten to stale)",
         dict(c.execute("SELECT request_id, state FROM owner_requests WHERE request_id IN ('r1','r2')").fetchall()) == {"r1": "evidence", "r2": "timeout"})
    case("STALE TRANSITION: old holder cannot reply to its in-flight request",
         raises(lambda: ol.transition(c, "old0", "replied", "kb", g1, *H, now=T0 + TTL + 6), ol.FencedOut))
    case("STALE TRANSITION: successor cannot adopt a gen-1 request",
         raises(lambda: ol.transition(c, "old0", "replied", "kb", g2, *S, now=T0 + TTL + 6), (ol.FencedOut, ol.InvalidTransition)))
    case("REPLAY: re-enqueue of a stale id returns its durable outcome, no authority",
         ol.enqueue(c, "kb", g2, *S, "old1", now=T0 + TTL + 7) == {"request_id": "old1", "label": "kb", "generation": 1, "state": "stale", "authority": False})
    case("SUCCESSOR QUEUE: stale requests do not consume the successor's bound (5 fresh fit)",
         all(ol.enqueue(c, "kb", g2, *S, f"new{i}", bound=5, now=T0 + TTL + 8)["authority"] for i in range(5)))
    case("successor bound still enforced", raises(lambda: ol.enqueue(c, "kb", g2, *S, "new5", bound=5, now=T0 + TTL + 9), ol.QueueFull))
    case("old holder cannot release its successor", raises(lambda: ol.release(c, "kb", g1, *H, now=T0 + TTL + 10), ol.FencedOut))
    case("events log every transition (acquired/released/stale/queued)",
         {k for (k,) in c.execute("SELECT DISTINCT kind FROM owner_events")} >= {"registered", "acquired", "released", "request:stale", "request:queued", "request:evidence"})
    c.close()

    # --- bound race ---
    p, c = fresh()
    gen = ol.acquire(c, "kb", "w1:p1", "term_1", TTL, T0)
    c.close()
    with ctx.Pool(8) as pool:
        res = pool.map(_race_enqueue, [(p, gen, i) for i in range(20)])
    c = ol.connect(p)
    case("bound: 20 concurrent enqueues, bound 5 -> exactly 5 queued",
         res.count("queued") == 5 and res.count("full") == 15 and count(c, "SELECT COUNT(*) FROM owner_requests") == 5)
    q0 = c.execute("SELECT request_id FROM owner_requests ORDER BY request_id").fetchone()[0]
    case("duplicate of a queued id: prior outcome, authority False, no new row",
         ol.enqueue(c, "kb", gen, "w1:p1", "term_1", q0, now=T0)["authority"] is False and count(c, "SELECT COUNT(*) FROM owner_requests") == 5)
    c.close()

    # --- RENEWAL vs REAP ---
    p, c = fresh()
    H = ("w1:p1", "term_1")
    g = ol.acquire(c, "kb", *H, TTL, T0)
    obs = ol.observe_stale(c, set(), T0 + 10)  # stale snapshot: pane list missed the holder
    case("observe: holder missing from pane snapshot -> pane-gone", [o["reason"] for o in obs] == ["pane-gone"])
    case("dry-run reap changes nothing", not ol.reap(c, obs, T0 + 11)[0]["released"] and ol.check_fence(c, "kb", g, *H, now=T0 + 11) is None)
    ol.acquire(c, "kb", *H, TTL, T0 + 12)  # holder renews after the observation
    r = ol.reap(c, obs, T0 + 13, dry_run=False)
    case("RENEWAL vs REAP: renewal after observation wins; CAS reap releases nothing",
         r[0]["released"] is False and ol.check_fence(c, "kb", g, *H, now=T0 + 14) is None)
    obs2 = ol.observe_stale(c, set(), T0 + 20)
    r2 = ol.reap(c, obs2, T0 + 21, dry_run=False)
    case("unchanged observation -> reap releases the lease (registry row only)",
         r2[0]["released"] is True and raises(lambda: ol.check_fence(c, "kb", g, *H, now=T0 + 22), ol.FencedOut))
    case("double reap of the same observation is a no-op", ol.reap(c, obs2, T0 + 23, dry_run=False)[0]["released"] is False)
    case("reap-skipped and reaped both recorded as events",
         {k for (k,) in c.execute("SELECT kind FROM owner_events WHERE kind LIKE 'reap%'")} == {"reaped", "reap-skipped"})
    ol.acquire(c, "kb", *H, TTL, T0 + 30)
    case("expired lease observed as stale even with a live pane",
         [o["reason"] for o in ol.observe_stale(c, {H}, T0 + 30 + TTL + 1)] == ["expired"])
    c.close()

    print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
