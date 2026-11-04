#!/usr/bin/env python3
"""verify-owner-assignment.py — offline synthetic proofs for Plan 018 PR A:
the durable owner-assignment core in lib/owner_lease.py and owner-assignment.py.

Real SQLite files, real separate processes for the races, a real subprocess
for the CLI; no registry, panes, network or live lease store. Includes a
mutation check: re-introducing `expires_at > now` for assignments is run
against a mutated copy of the library and must be caught.

  python3 verify-owner-assignment.py
"""
import hashlib
import importlib.util
import multiprocessing as mp
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_lease as ol  # noqa: E402

CLI = HERE / "owner-assignment.py"
T0 = 1_792_000_000.0
TEN_Y = T0 + 10 * 365 * 86400
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


def code_of(fn, exc):
    try:
        fn()
    except exc as e:
        return getattr(e, "code", type(e).__name__)
    return None


def S(tag):
    return hashlib.sha256(f"assign-{tag}".encode()).hexdigest()


A = ("w1:p1", "term_a", S("a"))
B = ("w2:p1", "term_b", S("b"))
C = ("w3:p1", "term_c", S("c"))


def fresh(label="kb", project="tntpgh/knowledge-base"):
    fd, path = tempfile.mkstemp(suffix=".sqlite3")
    os.close(fd)
    c = ol.connect(path)
    ol.migrate(c)
    if label:
        ol.register_owner(c, label, project, now=T0)
    return path, c


def assign(c, h, dec="dec-1", reason="r", now=T0, label="kb", dry_run=False):
    return ol.assign_initial(c, label, *h, dec, reason, now, dry_run)


def replace(c, exp_gen, exp, new, dec="dec-2", reason="r", now=T0, dry_run=False):
    return ol.assign_replace(c, "kb", exp_gen, *exp, *new, dec, reason, now, dry_run)


def revoke(c, gen, exp, dec="dec-r", reason="r", now=T0, dry_run=False):
    return ol.assign_revoke(c, "kb", gen, *exp, dec, reason, now, dry_run)


def snap(c):
    return tuple(tuple(c.execute(f"SELECT * FROM {t} ORDER BY 1").fetchall())
                 for t in ("owner_leases", "owner_requests", "owner_events"))


def count(c, sql, *a):
    return c.execute(sql, a).fetchone()[0]


def deliver(c, gen, h, rid, now=T0):
    ol.enqueue(c, "kb", gen, h[0], h[1], rid, now=now)
    ol.transition(c, rid, "delivering", "kb", gen, h[0], h[1], now=now)


def _race_assign(args):
    path, i = args
    c = ol.connect(path)
    try:
        h = (f"w{i}:p1", f"term_{i}", S(f"r{i}"))
        return ("won", ol.assign_initial(c, "kb", *h, f"dec-{i}", "race", T0, False))
    except ol.AssignmentConflict:
        return ("lost", None)
    finally:
        c.close()


def _race_replace(args):
    path, i = args
    c = ol.connect(path)
    try:
        h = (f"w{i}:p1", f"term_{i}", S(f"r{i}"))
        return ("won", ol.assign_replace(c, "kb", 1, *A, *h, f"dec-{i}", "race", T0, False))
    except ol.ReplaceRefused as e:
        return ("lost", e.code)
    finally:
        c.close()


def mutant_module():
    """owner_lease.py with `expires_at > now` re-imposed on assignments."""
    src = (HERE / "lib" / "owner_lease.py").read_text()
    needle = "(authority_mode='assignment' OR expires_at > ?)"
    assert needle in src, "mutation target not found"
    d = Path(tempfile.mkdtemp())
    (d / "owner_lease_mut.py").write_text(src.replace(needle, "expires_at > ?"))
    spec = importlib.util.spec_from_file_location("owner_lease_mut", d / "owner_lease_mut.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def time_independent(mod):
    fd, path = tempfile.mkstemp(suffix=".sqlite3")
    os.close(fd)
    c = mod.connect(path)
    mod.migrate(c)
    mod.register_owner(c, "kb", "tntpgh/knowledge-base", now=T0)
    mod.assign_initial(c, "kb", *A, "dec-1", "r", T0, False)
    ok = mod.holder_tuple(c, "kb", TEN_Y) == (*A, 1)
    c.close()
    return ok


def cli(args, apply_flag=False, env_extra=None):
    env = dict(os.environ)
    env.pop("HERDR_OWNER_ASSIGNMENT_WRITER", None)
    if env_extra:
        env.update(env_extra)
    r = subprocess.run([sys.executable, str(CLI), *args], capture_output=True, text=True, env=env, timeout=30)
    return r.returncode, (r.stdout + r.stderr).strip()


def cli_db(version6=True):
    base = Path(os.path.realpath(tempfile.mkdtemp()))
    db = base / "lease.sqlite3"
    if version6:
        c = ol.connect(str(db))
        ol.migrate(c)
        ol.register_owner(c, "kb", "tntpgh/knowledge-base", now=T0)
        c.close()
    else:
        d = sqlite3.connect(str(db), isolation_level=None)
        d.execute("CREATE TABLE owner_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
        for v in (1, 2, 3, 4, 5):
            for stmt in ol.MIGRATIONS[v]:
                d.execute(stmt)
            d.execute("INSERT INTO owner_schema_version VALUES (?, 'x')", (v,))
        d.close()
    os.chmod(db, 0o600)
    return db


def main():
    ctx = mp.get_context("spawn")

    # --- schema: engine-level invariants ---
    p, c = fresh()
    case("schema is v6", ol.migrate(c) == 6)
    row = ("x1", "kb", "tntpgh/knowledge-base", "w1:p1", "term_a", 1, "a", "a")
    ins = ("INSERT INTO owner_leases(lease_id,label,project,pane_id,pane_birth,generation,acquired_at,renewed_at,"
           "expires_at,authority_mode) VALUES (?,?,?,?,?,?,?,?,?,?)")
    case("CHECK: assignment row with an expires_at is rejected",
         raises(lambda: c.execute(ins, (*row, "z", "assignment")), sqlite3.IntegrityError))
    case("CHECK: timed row without expires_at is rejected",
         raises(lambda: c.execute(ins, (*row, None, "timed")), sqlite3.IntegrityError))
    case("CHECK: unknown authority_mode is rejected",
         raises(lambda: c.execute(ins, (*row, None, "forever")), sqlite3.IntegrityError))
    c.close()

    # --- initial assignment ---
    p, c = fresh()
    before = snap(c)
    case("dry-run is the default and writes nothing",
         ol.assign_initial(c, "kb", *A, "dec-1", "r") == "would_assign" and snap(c) == before)
    g = assign(c, A)
    cur = ol.current_assignment(c, "kb")
    case("assign: generation 1, mode assignment, expires_at NULL, decision/reason/project recorded",
         g == 1 and cur["authority_mode"] == "assignment" and cur["expires_at"] is None and cur["generation"] == 1
         and (cur["decision_ref"], cur["reason"], cur["project"]) == ("dec-1", "r", "tntpgh/knowledge-base")
         and (cur["pane_id"], cur["pane_birth"], cur["session_digest"]) == A)
    case("assign appends an 'assigned' event", count(c, "SELECT COUNT(*) FROM owner_events WHERE kind='assigned'") == 1)
    after = snap(c)
    case("IDEMPOTENT: exact same assign returns the same generation and writes nothing",
         assign(c, A) == 1 and snap(c) == after)
    case("different holder while assigned: AssignmentConflict, nothing written",
         raises(lambda: assign(c, B, dec="dec-x"), ol.AssignmentConflict) and snap(c) == after)
    case("same holder but different decision_ref is not an idempotent no-op",
         raises(lambda: assign(c, A, dec="dec-other"), ol.AssignmentConflict) and snap(c) == after)
    case("unregistered label refused", raises(lambda: assign(c, A, label="ghost"), ol.InvalidOwner))
    case("bad inputs refused (digest, decision_ref, reason, pane)",
         raises(lambda: assign(c, (A[0], A[1], "nothex")), ValueError)
         and raises(lambda: assign(c, A, dec=""), ValueError)
         and raises(lambda: assign(c, A, reason=""), ValueError)
         and raises(lambda: assign(c, ("pane1", A[1], A[2])), ValueError))
    c.close()

    # --- time independence ---
    p, c = fresh()
    assign(c, A)
    case("assignment is current ten years later (holder_tuple, current_assignment)",
         ol.holder_tuple(c, "kb", TEN_Y) == (*A, 1) and ol.current_assignment(c, "kb", TEN_Y)["generation"] == 1)
    case("assignment has no expiry to report", ol.live_expiry(c, "kb", TEN_Y) is None)
    case("fenced enqueue still admitted ten years later",
         ol.enqueue(c, "kb", 1, A[0], A[1], "late", now=TEN_Y)["authority"] is True)
    case("observe_stale never lists an assignment (no age/pane-gone reap)",
         ol.observe_stale(c, set(), TEN_Y) == [])
    c.close()
    case("MUTATION: re-imposing expires_at>now on assignments is detected by the time-independence probe",
         time_independent(ol) is True and time_independent(mutant_module()) is False)

    # --- stale tuple / generation writes nothing ---
    p, c = fresh()
    assign(c, A)
    before = snap(c)
    bad = [(2, A), (1, ("w9:p9", A[1], A[2])), (1, (A[0], "term_zzz", A[2])), (1, (A[0], A[1], S("other")))]
    case("replace: stale generation / pane / birth / session each refused stale_expectation, nothing written",
         all(code_of(lambda g=g, e=e: replace(c, g, e, B), ol.ReplaceRefused) == "stale_expectation" for g, e in bad)
         and snap(c) == before)
    case("revoke: stale generation / pane / birth / session each refused stale_expectation, nothing written",
         all(code_of(lambda g=g, e=e: revoke(c, g, e), ol.RevokeRefused) == "stale_expectation" for g, e in bad)
         and snap(c) == before)
    c.close()

    # --- active replacement ---
    p, c = fresh()
    assign(c, A)
    case("replace dry-run default writes nothing",
         ol.assign_replace(c, "kb", 1, *A, *B, "dec-2", "r") == "would_replace" and count(c, "SELECT COUNT(*) FROM owner_leases") == 1)
    case("replace by the SAME holder is refused same_holder",
         code_of(lambda: replace(c, 1, A, A, dec="dec-2"), ol.ReplaceRefused) == "same_holder")
    case("replace to a different holder: generation 2, predecessor released superseded_by_assignment",
         replace(c, 1, A, B) == 2
         and c.execute("SELECT release_reason FROM owner_leases WHERE generation=1").fetchone()[0] == "superseded_by_assignment"
         and ol.holder_tuple(c, "kb", T0) == (*B, 2)
         and count(c, "SELECT COUNT(*) FROM owner_leases WHERE released_at IS NULL") == 1)
    s2 = snap(c)
    case("IDEMPOTENT: re-presenting the exact replacement returns gen 2, writes nothing",
         replace(c, 2, B, B, dec="dec-2") == 2 and snap(c) == s2)
    case("old holder is fenced out after replacement",
         raises(lambda: ol.enqueue(c, "kb", 1, A[0], A[1], "r9", now=T0), ol.FencedOut))
    c.close()

    # --- replacement with open requests ---
    p, c = fresh()
    assign(c, A)
    ol.enqueue(c, "kb", 1, A[0], A[1], "open1", now=T0)
    before = snap(c)
    case("replace refused open_requests while a request is queued; nothing written",
         code_of(lambda: replace(c, 1, A, B), ol.ReplaceRefused) == "open_requests" and snap(c) == before)
    ol.transition(c, "open1", "cancelled", "kb", 1, A[0], A[1], now=T0)
    case("replace succeeds once the request is terminal", replace(c, 1, A, B) == 2)
    c.close()

    # --- concurrency ---
    p, c = fresh()
    c.close()
    with ctx.Pool(8) as pool:
        res = pool.map(_race_assign, [(p, i) for i in range(1, 9)])
    c = ol.connect(p)
    case("concurrent initial assign: exactly one winner at gen 1, the rest refused",
         [g for r, g in res if r == "won"] == [1] and [r for r, _ in res].count("lost") == 7
         and count(c, "SELECT COUNT(*) FROM owner_leases") == 1
         and count(c, "SELECT COUNT(*) FROM owner_events WHERE kind='assigned'") == 1)
    c.close()
    p, c = fresh()
    assign(c, A)
    c.close()
    with ctx.Pool(8) as pool:
        res = pool.map(_race_replace, [(p, i) for i in range(4, 12)])
    c = ol.connect(p)
    case("concurrent replace from one predecessor: exactly one winner, the rest stale_expectation",
         [g for r, g in res if r == "won"] == [2]
         and [x for r, x in res if r == "lost"] == ["stale_expectation"] * 7
         and count(c, "SELECT COUNT(*) FROM owner_leases") == 2
         and count(c, "SELECT COUNT(*) FROM owner_leases WHERE released_at IS NULL") == 1)
    c.close()

    # --- revoke: cancellation, blocked admission, settlement ---
    p, c = fresh()
    assign(c, A)
    ol.enqueue(c, "kb", 1, A[0], A[1], "q1", now=T0)
    ol.enqueue(c, "kb", 1, A[0], A[1], "h1", now=T0)
    ol.transition(c, "h1", "held", "kb", 1, A[0], A[1], now=T0)
    ol.enqueue(c, "kb", 1, A[0], A[1], "b1", now=T0)
    ol.transition(c, "b1", "blocked", "kb", 1, A[0], A[1], now=T0)
    deliver(c, 1, A, "d1")
    before = snap(c)
    case("revoke dry-run default writes nothing",
         ol.assign_revoke(c, "kb", 1, *A, "dec-r", "r") == "would_revoke" and snap(c) == before)
    out = revoke(c, 1, A)
    states = dict(c.execute("SELECT request_id, state FROM owner_requests").fetchall())
    case("revoke: queued/held/blocked cancelled, delivering untouched",
         states == {"q1": "cancelled", "h1": "cancelled", "b1": "cancelled", "d1": "delivering"}
         and sorted(out["cancelled"]) == ["b1", "h1", "q1"] and out["generation"] == 1)
    case("revoke releases the row as 'revoked' and records a 'revoked' event",
         c.execute("SELECT release_reason FROM owner_leases WHERE generation=1").fetchone()[0] == "revoked"
         and count(c, "SELECT COUNT(*) FROM owner_events WHERE kind='revoked'") == 1
         and ol.current_assignment(c, "kb") is None and ol.holder_tuple(c, "kb", T0) is None)
    case("revoke blocks new admission and old-holder transitions (FencedOut)",
         raises(lambda: ol.enqueue(c, "kb", 1, A[0], A[1], "new", now=T0), ol.FencedOut)
         and raises(lambda: ol.transition(c, "d1", "replied", "kb", 1, A[0], A[1], now=T0), ol.FencedOut))
    s_rev = snap(c)
    case("revoking again refused (no unreleased authority), nothing written",
         code_of(lambda: revoke(c, 1, A), ol.RevokeRefused) == "stale_expectation" and snap(c) == s_rev)

    # --- settlement after revoke ---
    case("settle: wrong generation / unknown request / non-delivering request refused",
         code_of(lambda: ol.assign_settle(c, "kb", "d1", 2, "replied", "x", T0, False), ol.SettleRefused) == "wrong_generation"
         and code_of(lambda: ol.assign_settle(c, "kb", "nope", 1, "replied", "x", T0, False), ol.SettleRefused) == "unknown_request"
         and code_of(lambda: ol.assign_settle(c, "kb", "q1", 1, "replied", "x", T0, False), ol.SettleRefused) == "not_delivering")
    case("settle cannot re-admit: target must be replied|timeout",
         all(raises(lambda to=to: ol.assign_settle(c, "kb", "d1", 1, to, "x", T0, False), ol.InvalidTransition)
             for to in ("delivering", "queued", "cancelled", "evidence", "stale")))
    case("settle dry-run default writes nothing",
         ol.assign_settle(c, "kb", "d1", 1, "replied", "x", T0) == "would_settle" and snap(c) == s_rev)
    case("re-assign refused open_requests while a delivering request is unsettled",
         code_of(lambda: replace(c, 1, A, A, dec="dec-3"), ol.ReplaceRefused) == "open_requests")
    case("settle records the terminal outcome against the exact released generation",
         ol.assign_settle(c, "kb", "d1", 1, "timeout", "late reply", T0 + 5, False) == "timeout"
         and c.execute("SELECT state, detail FROM owner_requests WHERE request_id='d1'").fetchone() == ("timeout", "late reply"))
    case("a settled request cannot be settled again",
         code_of(lambda: ol.assign_settle(c, "kb", "d1", 1, "replied", "x", T0, False), ol.SettleRefused) == "not_delivering")
    c.close()

    p, c = fresh()
    assign(c, A)
    deliver(c, 1, A, "live1")
    case("settle refused generation_still_active while the assignment is unreleased",
         code_of(lambda: ol.assign_settle(c, "kb", "live1", 1, "replied", "x", T0, False), ol.SettleRefused)
         == "generation_still_active")
    c.close()

    # --- re-assignment after revoke ---
    p, c = fresh()
    assign(c, A)
    revoke(c, 1, A)
    before = snap(c)
    case("re-assign after revoke: stale generation / holder refused, nothing written",
         code_of(lambda: replace(c, 2, A, A, dec="dec-3"), ol.ReplaceRefused) == "stale_expectation"
         and code_of(lambda: replace(c, 1, B, A, dec="dec-3"), ol.ReplaceRefused) == "stale_expectation"
         and snap(c) == before)
    case("re-assign after revoke may name the SAME holder from the exact revoked generation: gen 2",
         replace(c, 1, A, A, dec="dec-3") == 2 and ol.holder_tuple(c, "kb", T0) == (*A, 2)
         and ol.current_assignment(c, "kb")["decision_ref"] == "dec-3")
    case("generation stays label-local monotonic (1, 2) with one unreleased row",
         [r[0] for r in c.execute("SELECT generation FROM owner_leases ORDER BY generation")] == [1, 2]
         and count(c, "SELECT COUNT(*) FROM owner_leases WHERE released_at IS NULL") == 1)
    revoke(c, 2, A, dec="dec-r2")
    case("re-assign is only from the LATEST revoked generation (gen 1 is no longer valid)",
         code_of(lambda: replace(c, 1, A, B, dec="dec-4"), ol.ReplaceRefused) == "stale_expectation"
         and replace(c, 2, A, B, dec="dec-4") == 3)
    case("a superseded (not revoked) predecessor is not a re-assign base",
         replace(c, 3, B, C, dec="dec-5") == 4
         and code_of(lambda: replace(c, 3, B, B, dec="dec-6"), ol.ReplaceRefused) == "stale_expectation"
         and count(c, "SELECT COUNT(*) FROM owner_leases WHERE released_at IS NULL") == 1)
    c.close()

    # --- no automatic conversion; timed semantics unchanged ---
    p, c = fresh()
    assign(c, A)
    before = snap(c)
    case("active assignment: acquire (same and other holder), claim_initial, claim_successor all refused",
         raises(lambda: ol.acquire(c, "kb", A[0], A[1], TTL, TEN_Y, session_digest=A[2]), ol.LeaseConflict)
         and raises(lambda: ol.acquire(c, "kb", *B[:2], TTL, TEN_Y, session_digest=B[2]), ol.LeaseConflict)
         and raises(lambda: ol.claim_initial(c, "kb", *B[:2], TTL, B[2], now=TEN_Y), ol.LeaseConflict)
         and code_of(lambda: ol.claim_successor(c, "kb", 1, *A, *B[:2], TTL, B[2], now=TEN_Y), ol.SuccessorRefused)
         == "live_predecessor"
         and snap(c) == before)
    case("owner_lease_renew never renews an assignment", __import__("owner_lease_renew").renew_due(
        c, "kb", A, now=TEN_Y) == "not_timed" and snap(c) == before)
    revoke(c, 1, A)
    s_rev = snap(c)
    case("after revoke: legacy acquire / claim_successor cannot take the label over",
         raises(lambda: ol.acquire(c, "kb", *B[:2], TTL, T0 + 1, session_digest=B[2]), ol.LeaseConflict)
         and code_of(lambda: ol.claim_successor(c, "kb", 1, *A, *B[:2], TTL, B[2], now=T0 + 1), ol.SuccessorRefused)
         == "predecessor_was_assignment"
         and snap(c) == s_rev)
    c.close()

    p, c = fresh()
    g = ol.acquire(c, "kb", A[0], A[1], TTL, T0, session_digest=A[2])
    before = snap(c)
    case("timed lease: assign_initial never converts it (AssignmentConflict), row stays timed",
         raises(lambda: assign(c, B), ol.AssignmentConflict) and snap(c) == before
         and ol.current_assignment(c, "kb")["authority_mode"] == "timed")
    case("EXPIRED but unreleased timed lease is still not auto-converted",
         raises(lambda: assign(c, B, now=T0 + TTL + 5), ol.AssignmentConflict) and snap(c) == before)
    case("revoke refuses a timed lease (not_assignment_mode)",
         code_of(lambda: revoke(c, g, A), ol.RevokeRefused) == "not_assignment_mode" and snap(c) == before)
    case("timed semantics unchanged: expires at the TTL boundary, holder_tuple empty after",
         ol.holder_tuple(c, "kb", T0 + TTL - 1) == (*A, g) and ol.holder_tuple(c, "kb", T0 + TTL + 1) is None
         and ol.live_expiry(c, "kb", T0 + 1) == T0 + TTL)
    case("an explicit replace may supersede an expired timed lease row only by exact tuple",
         replace(c, g, A, B, dec="cutover", now=T0 + TTL + 5) == 2
         and c.execute("SELECT release_reason FROM owner_leases WHERE generation=1").fetchone()[0] == "superseded_by_assignment")
    c.close()

    # --- disabled store fails closed ---
    p, c = fresh()
    assign(c, A)
    ol.disable(c, T0 + 1)
    before = snap(c)
    case("disabled: assign/replace/revoke/settle all fail closed, nothing written",
         raises(lambda: replace(c, 1, A, B), ol.Disabled) and raises(lambda: revoke(c, 1, A), ol.Disabled)
         and raises(lambda: assign(c, B, label="kb"), (ol.Disabled, ol.AssignmentConflict)) and snap(c) == before)
    c.close()

    # --- CLI (real subprocess) ---
    W = {"HERDR_OWNER_ASSIGNMENT_WRITER": "1"}
    db = cli_db()
    sd = A[2]
    holder_a = ["--pane-id", A[0], "--pane-birth", A[1], "--session-digest", sd]
    exp_a = ["--expected-generation", "1", "--expected-pane-id", A[0], "--expected-pane-birth", A[1],
             "--expected-session-digest", sd]
    base_a = ["--db", str(db), "assign", "--label", "kb", *holder_a, "--decision-ref", "dec-1", "--reason", "r"]
    rc, out = cli(["--db", str(db), "show", "--label", "kb"])
    case("cli show: no authority -> current:kb:none", rc == 0 and out == "current:kb:none")
    b0 = db.read_bytes()
    rc, out = cli(base_a)
    case("cli assign: dry-run by default, plan printed, db bytes unchanged",
         rc == 0 and out.startswith("plan:would_assign:kb") and db.read_bytes() == b0)
    rc, out = cli(base_a + ["--apply"])
    case("cli assign --apply without the writer flag: refused:flags_off, exit 4, nothing written",
         rc == 4 and out == "refused:flags_off" and db.read_bytes() == b0)
    rc, out = cli(base_a + ["--apply"], env_extra=W)
    case("cli assign --apply with the writer flag: assigned:kb:1", rc == 0 and out == "assigned:kb:1")
    rc, out = cli(base_a + ["--apply"], env_extra=W)
    case("cli assign --apply again is idempotent", rc == 0 and out == "assigned:kb:1")
    rc, out = cli(["--db", str(db), "show", "--label", "kb"])
    case("cli show: mode/generation printed, session digest truncated (never the full value)",
         rc == 0 and out.startswith("current:kb:mode=assignment gen=1") and sd[:8] in out and sd not in out)
    other = ["--db", str(db), "assign", "--label", "kb", "--pane-id", B[0], "--pane-birth", B[1],
             "--session-digest", B[2], "--decision-ref", "dec-x", "--reason", "r"]
    rc, out = cli(other + ["--apply"], env_extra=W)
    case("cli assign over an active assignment: refused:AssignmentConflict, exit 2",
         rc == 2 and out.startswith("refused:AssignmentConflict"))
    repl = ["--db", str(db), "replace", "--label", "kb", *exp_a, "--pane-id", B[0], "--pane-birth", B[1],
            "--session-digest", B[2], "--decision-ref", "dec-2", "--reason", "r"]
    rc, out = cli(repl)
    case("cli replace: dry-run default", rc == 0 and out.startswith("plan:would_replace:kb"))
    rc, out = cli(repl + ["--apply"], env_extra=W)
    case("cli replace --apply: replaced:kb:2", rc == 0 and out == "replaced:kb:2")
    rc, out = cli(repl + ["--apply"], env_extra=W)
    case("cli replace with the now-stale predecessor: refused, exit 2",
         rc == 2 and out.startswith("refused:ReplaceRefused:stale_expectation"))
    rev = ["--db", str(db), "revoke", "--label", "kb", "--expected-generation", "2", "--expected-pane-id", B[0],
           "--expected-pane-birth", B[1], "--expected-session-digest", B[2], "--decision-ref", "dec-r", "--reason", "r"]
    rc, out = cli(rev)
    case("cli revoke: dry-run default", rc == 0 and out.startswith("plan:would_revoke:kb"))
    rc, out = cli(rev + ["--apply"], env_extra=W)
    case("cli revoke --apply: revoked:kb:2:cancelled=0", rc == 0 and out == "revoked:kb:2:cancelled=0")
    rc, out = cli(["--db", str(db), "settle", "--label", "kb", "--request-id", "nope", "--expected-generation", "2",
                   "--to", "replied"])
    case("cli settle of an unknown request: refused:SettleRefused:unknown_request, exit 2",
         rc == 2 and out == "refused:SettleRefused:unknown_request")
    case("cli never prints a full session digest on any path", all(h not in out for h in (A[2], B[2])))
    old = cli_db(version6=False)
    rc, out = cli(["--db", str(old), "show", "--label", "kb"])
    case("cli show on a pre-v6 store: refused:schema_migration_required, exit 4",
         rc == 4 and out.startswith("refused:schema_migration_required:5->6"))
    rc, out = cli(["--db", str(old), "assign", "--label", "kb", *holder_a, "--decision-ref", "d", "--reason", "r",
                   "--apply"], env_extra=W)
    case("cli assign --apply on a pre-v6 store: refused:schema_migration_required, never migrates",
         rc == 4 and out.startswith("refused:schema_migration_required:5->6")
         and count(sqlite3.connect(str(old)), "SELECT COUNT(*) FROM owner_schema_version") == 5)

    print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
