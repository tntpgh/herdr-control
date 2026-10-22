#!/usr/bin/env python3
"""verify-owner-lease.py — offline synthetic proofs for lib/owner_lease.py.

Real SQLite files and real separate processes for the races; no registry,
panes or network. Prints OK/FAIL per case; exit 1 on any FAIL.

  python3 verify-owner-lease.py
"""
import multiprocessing as mp
import os
import sqlite3
from datetime import datetime, timezone
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
        ol.register_owner(c, label, project, now=T0)
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
        return ol.enqueue(c, "kb", gen, "w1:p1", "term_1", f"req_{i:02d}", now=T0)["state"]
    except ol.QueueFull:
        return "full"
    finally:
        c.close()


def main():
    ctx = mp.get_context("spawn")

    # --- schema / migration ---
    p, c = fresh(label=None)
    case("migrate is versioned and idempotent", ol.migrate(c) == ol.SCHEMA_VERSION == 2 and count(c, "SELECT COUNT(*) FROM owner_schema_version") == 2)
    ol.register_owner(c, "kb", "tntpgh/knowledge-base", now=T0)
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
    case("invalid labels refused", all(raises(lambda l=l: ol.register_owner(c, l, "tntpgh/a", now=T0), ol.InvalidOwner)
                                       for l in ["", "KB", "-kb", "kb owner", "a" * 49, "kb;drop"]))
    case("non-tntpgh / path-ish projects refused", all(raises(lambda v=v: ol.canonical_project(v), ol.InvalidOwner)
                                                       for v in ["other/kb", "tntpgh/../x", "/Users/x/Code/kb", "tntpgh/a/b"]))
    ol.register_owner(c, "knowledge-base", "tntpgh/knowledge-base", now=T0)
    case("same label+project re-register is idempotent", ol.register_owner(c, "knowledge-base", "github.com/tntpgh/knowledge-base", now=T0) == "tntpgh/knowledge-base")
    case("ADVERSARIAL: a second label cannot own the same project (any URL spelling)",
         raises(lambda: ol.register_owner(c, "kb-2", "https://github.com/tntpgh/Knowledge-Base.git", now=T0), ol.InvalidOwner))
    case("one label cannot own two projects", raises(lambda: ol.register_owner(c, "knowledge-base", "tntpgh/tourguide", now=T0), ol.InvalidOwner))
    case("unregistered label cannot acquire", raises(lambda: ol.acquire(c, "ghost", "w1:p1", "term_1", TTL, T0), ol.InvalidOwner))
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
    case("same pane id with recycled birth -> conflict", raises(lambda: ol.acquire(c, "kb", holder[0], "term_recycled", TTL, T0 + 11), ol.LeaseConflict))
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
         raises(lambda: ol.transition(c, "r1", "delivering", "kb", g1, "w1:p1", "term_other", now=T0), ol.FencedOut))
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
        ol.enqueue(c, "kb", g1, *H, f"old{i}", now=T0 + 1)
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
         all(ol.enqueue(c, "kb", g2, *S, f"new{i}", now=T0 + TTL + 8)["authority"] for i in range(5)))
    case("successor bound still enforced", raises(lambda: ol.enqueue(c, "kb", g2, *S, "new5", now=T0 + TTL + 9), ol.QueueFull))
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

    # --- policy, validation, auth-before-metadata, foreign keys ---
    p, c = fresh(label=None)
    case("max_open policy validated at registration",
         all(raises(lambda m=m: ol.register_owner(c, "kb", "tntpgh/kb", max_open=m, now=T0), ol.InvalidOwner) for m in (0, 51, True, "5", 2.0)))
    ol.register_owner(c, "kb", "tntpgh/kb", max_open=2, now=T0)
    H = ("w1:p1", "term_1")
    g = ol.acquire(c, "kb", *H, TTL, T0)
    ol.enqueue(c, "kb", g, *H, "a", now=T0)
    ol.enqueue(c, "kb", g, *H, "b", now=T0)
    case("bound comes from owner policy (max_open=2); enqueue has no caller override",
         raises(lambda: ol.enqueue(c, "kb", g, *H, "c", now=T0), ol.QueueFull)
         and raises(lambda: ol.enqueue(c, "kb", g, *H, "c", bound=50, now=T0), TypeError))
    case("invalid pane / birth / request id / ttl refused",
         raises(lambda: ol.acquire(c, "kb", "pane1", "term_1", TTL, T0), ValueError)
         and raises(lambda: ol.acquire(c, "kb", "w1:p1", "birth", TTL, T0), ValueError)
         and raises(lambda: ol.enqueue(c, "kb", g, *H, "../x", now=T0), ValueError)
         and all(raises(lambda t=t: ol.acquire(c, "kb", *H, t, T0), ValueError) for t in (0, -5, 86_401, 1.5, True)))
    case("duplicate-request metadata only after holder authentication",
         raises(lambda: ol.enqueue(c, "kb", g, "w9:p9", "term_9", "a", now=T0), ol.FencedOut)
         and ol.enqueue(c, "kb", g, *H, "a", now=T0)["authority"] is False)
    case("foreign keys ON: request for a nonexistent lease generation rejected",
         raises(lambda: c.execute("INSERT INTO owner_requests(request_id,label,generation,state,created_at,updated_at) "
                                  "VALUES ('z','kb',99,'queued','t','t')"), sqlite3.IntegrityError))
    case("foreign keys ON: lease for an unregistered label rejected",
         raises(lambda: c.execute("INSERT INTO owner_leases(lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,expires_at) "
                                  "VALUES ('l','ghost','w1:p1','term_1',1,'a','a','z')"), sqlite3.IntegrityError))

    # --- reap matches the COMPLETE observed identity ---
    obs = ol.observe_stale(c, set(), T0 + 5)
    forged = [dict(obs[0], pane="w7:p7")]
    case("reap with a mismatched pane in the observation releases nothing",
         ol.reap(c, forged, T0 + 6, dry_run=False)[0]["released"] is False and ol.check_fence(c, "kb", g, *H, now=T0 + 6) is None)
    case("reap with a mismatched generation releases nothing",
         ol.reap(c, [dict(obs[0], generation=g + 1)], T0 + 6, dry_run=False)[0]["released"] is False)
    case("reap rejects incomplete observations", raises(lambda: ol.reap(c, [{"lease_id": obs[0]["lease_id"]}], T0 + 6), ValueError))
    ev = c.execute("SELECT label, generation FROM owner_events WHERE kind='reaped'").fetchall()
    ol.reap(c, obs, T0 + 7, dry_run=False)
    case("reaped event metadata comes from the matched DB row",
         c.execute("SELECT label, generation, ref FROM owner_events WHERE kind='reaped'").fetchall()[len(ev):] == [("kb", g, obs[0]["lease_id"])])

    # --- non-destructive rollback: disable, readers, backup, restore-on-copy ---
    tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    n_events = count(c, "SELECT COUNT(*) FROM owner_events")
    ol.disable(c, T0 + 8)
    case("disabled: every mutation fails closed",
         all(raises(fn, ol.Disabled) for fn in (
             lambda: ol.acquire(c, "kb", "w2:p2", "term_2", TTL, T0 + 9),
             lambda: ol.register_owner(c, "kb2", "tntpgh/kb2", now=T0 + 9),
             lambda: ol.reap(c, ol.observe_stale(c, set(), T0 + 9), T0 + 9, dry_run=False))))
    case("disabled: tables and events preserved, readers still work",
         {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")} == tables
         and count(c, "SELECT COUNT(*) FROM owner_events") == n_events and isinstance(ol.observe_stale(c, set(), T0 + 9), list))
    bdir = tempfile.mkdtemp()
    bpath = ol.export_backup(c, os.path.join(bdir, "owner-backup.sqlite3"))
    case("backup is a new 0600 file", (os.stat(bpath).st_mode & 0o777) == 0o600)
    case("backup refuses to overwrite", raises(lambda: ol.export_backup(c, bpath), FileExistsError))
    rc = ol.connect(bpath)
    same = lambda q: c.execute(q).fetchall() == rc.execute(q).fetchall()
    case("restore-on-copy: copy has identical leases, requests, events and state",
         all(same(f"SELECT * FROM {t} ORDER BY 1") for t in ("owner_projects", "owner_leases", "owner_requests", "owner_events", "owner_state")))
    rc.close()
    c.close()

    # --- upgrade from a database created at the ORIGINAL v1 schema ---
    def v1_db(orphan=False):
        fd, path = tempfile.mkstemp(suffix=".sqlite3")
        os.close(fd)
        d = sqlite3.connect(path, isolation_level=None)
        d.execute("CREATE TABLE owner_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
        for stmt in ol.MIGRATIONS[1]:
            d.execute(stmt)
        d.execute("INSERT INTO owner_schema_version VALUES (1, '2026-10-01T00:00:00.000000Z')")
        d.execute("INSERT INTO owner_projects VALUES ('kb', 'tntpgh/knowledge-base', '2026-10-01T00:00:00.000000Z')")
        d.execute("INSERT INTO owner_leases VALUES ('L1','kb','w1:p1','term_1',1,'2026-10-01T00:00:00.000000Z','2026-10-01T00:00:00.000000Z','2026-10-01T01:00:00.000000Z','2026-10-01T00:30:00.000000Z','released')")
        d.execute("INSERT INTO owner_leases VALUES ('L2','kb','w1:p2','term_2',2,'2026-10-01T00:31:00.000000Z','2026-10-01T00:31:00.000000Z','2026-10-01T01:31:00.000000Z',NULL,NULL)")
        d.execute("INSERT INTO owner_requests VALUES ('r1','kb',1,'stale','2026-10-01T00:10:00.000000Z','2026-10-01T00:31:00.000000Z','')")
        d.execute("INSERT INTO owner_requests VALUES ('r2','kb',2,'queued','2026-10-01T00:32:00.000000Z','2026-10-01T00:32:00.000000Z','')")
        if orphan:
            d.execute("INSERT INTO owner_requests VALUES ('r9','kb',9,'queued','2026-10-01T00:33:00.000000Z','2026-10-01T00:33:00.000000Z','')")
        for kind, gen in (("acquired", 1), ("released", 1), ("acquired", 2), ("enqueued", 2)):
            d.execute("INSERT INTO owner_events (at,label,kind,ref,generation) VALUES ('2026-10-01T00:00:00.000000Z','kb',?, '', ?)", (kind, gen))
        d.close()
        return path

    path = v1_db()
    snap = lambda c_, t, cols="*": c_.execute(f"SELECT {cols} FROM {t} ORDER BY 1").fetchall()
    pre = sqlite3.connect(path)
    before = {t: snap(pre, t) for t in ("owner_leases", "owner_requests", "owner_events")}
    pre_projects = snap(pre, "owner_projects")
    pre.close()
    u = ol.connect(path)
    case("v1 -> v2 upgrade applies exactly once", ol.migrate(u) == 2 and ol.migrate(u) == 2
         and [r[0] for r in u.execute("SELECT version FROM owner_schema_version ORDER BY version")] == [1, 2])
    case("upgrade preserves leases, requests and events (incl. seq) verbatim",
         all(snap(u, t) == rows for t, rows in before.items()))
    case("upgrade preserves projects and backfills max_open default",
         snap(u, "owner_projects", "label, project, registered_at") == pre_projects
         and count(u, "SELECT COUNT(*) FROM owner_projects WHERE max_open=?", ol.DEFAULT_MAX_OPEN) == 1)
    case("upgraded FKs are real (orphan request rejected)",
         raises(lambda: u.execute("INSERT INTO owner_requests VALUES ('rx','kb',7,'queued','t','t','')"), sqlite3.IntegrityError))
    case("upgraded events stay append-only and continue the sequence",
         raises(lambda: u.execute("DELETE FROM owner_events"), sqlite3.IntegrityError)
         and raises(lambda: u.execute("UPDATE owner_events SET kind='x'"), sqlite3.IntegrityError))
    seq0 = count(u, "SELECT MAX(seq) FROM owner_events")
    after_expiry = datetime(2026, 10, 1, 1, 32, tzinfo=timezone.utc).timestamp()  # L2 expired 01:31
    g3 = ol.acquire(u, "kb", "w1:p3", "term_3", TTL, after_expiry)
    case("upgraded db is usable: new acquire fences the old generation and appends events",
         g3 == 3 and count(u, "SELECT MAX(seq) FROM owner_events") > seq0
         and u.execute("SELECT state FROM owner_requests WHERE request_id='r2'").fetchone()[0] == "stale")
    n_ev = count(u, "SELECT COUNT(*) FROM owner_events")
    ol.disable(u, after_expiry + 10)
    case("upgraded db: disable fails closed, preserves rows",
         raises(lambda: ol.acquire(u, "kb", "w1:p4", "term_4", TTL, after_expiry + 11), ol.Disabled)
         and count(u, "SELECT COUNT(*) FROM owner_events") >= n_ev)
    ub = ol.export_backup(u, os.path.join(tempfile.mkdtemp(), "upgraded-backup.sqlite3"))
    ur = ol.connect(ub)
    case("upgraded db: backup copy is identical",
         all(u.execute(f"SELECT * FROM {t} ORDER BY 1").fetchall() == ur.execute(f"SELECT * FROM {t} ORDER BY 1").fetchall()
             for t in ("owner_projects", "owner_leases", "owner_requests", "owner_events", "owner_state")))
    ur.close()
    u.close()

    bad = ol.connect(v1_db(orphan=True))
    case("upgrade with a pre-existing FK violation aborts and leaves v1 intact",
         raises(lambda: ol.migrate(bad), sqlite3.IntegrityError)
         and [r[0] for r in bad.execute("SELECT version FROM owner_schema_version")] == [1]
         and count(bad, "SELECT COUNT(*) FROM owner_requests") == 3
         and count(bad, "SELECT COUNT(*) FROM sqlite_master WHERE name='owner_state'") == 0)
    bad.close()

    print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
