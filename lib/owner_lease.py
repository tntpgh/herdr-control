"""owner_lease.py — INERT contract for project owners: canonical project
mapping, lease CAS, generation/pane/birth fencing, a bounded per-owner request
queue with explicit dispositions, stale-request disposition, CAS reap, and an
append-only event log.

Nothing calls this. It is reviewable source with offline proofs ahead of any
activation decision. It never closes, spawns or touches a pane, never grants a
worker anything (that is spawn-task.sh / lib/worker-grant.py, frozen #348) and
does not drain queues or create conductors.

Invariants
  * One owner label per canonical project, one project per label
    (owner_projects: label PK, project UNIQUE).
  * At most one LIVE lease per label, enforced by the DB itself
    (partial UNIQUE index on owner_leases(label) WHERE released_at IS NULL).
    acquire() releases an expired holder and inserts the successor in ONE
    IMMEDIATE transaction, so expiry never blocks the index and two
    contenders can never both win.
  * Generation = MAX(generation)+1 over the label's whole history; renewal by
    the same (pane, birth) keeps it.
  * Every queue mutation is fenced: the caller's (generation, pane, birth)
    must be the current live lease, and the request must belong to that
    generation.
  * When a new generation takes the lease, every OPEN request of older
    generations is disposed `stale` in the same transaction: it no longer
    counts toward the successor's bound (no starvation) and can never be
    delivered or replied to (no replay).
  * enqueue() of an existing request_id never grants delivery authority again:
    it returns the durable prior outcome with authority=False.
  * reap() releases a lease only by CAS on the observed
    (lease_id, renewed_at, expires_at): a holder that renewed after the
    observation keeps its lease.
  * owner_events is append-only (UPDATE/DELETE rejected by triggers).

Request dispositions
  open:      queued, held, blocked, delivering
  terminal:  replied, evidence, timeout, stale, cancelled
  queued -> held | blocked | delivering | cancelled
  held -> queued | cancelled            blocked -> queued | cancelled
  delivering -> replied | timeout | blocked
  replied -> evidence
  (any open) -> stale   — only by acquire() on generation change

Migration / rollback (design; NOT applied to the live registry by this file)
  migrate(conn) is versioned (owner_schema_version) and idempotent; v1 only
  CREATEs owner_* tables/indexes/triggers and alters no existing table.
  Rollback is NON-destructive: disable(conn) flips owner_state.enabled=0 so
  every mutation fails closed while tables and the event log are preserved
  and readers (observe_stale, check_fence, export_backup) keep working.
  export_backup() writes a 0600 SQLite copy (new file only, never overwrite);
  restore is "open the copy", proven by the restore-on-copy test. Nothing
  here ever drops a table. Applying v1 live is a separate approval with a
  registry backup first.

Policy
  An owner's queue bound is its registered max_open (1..MAX_OPEN_LIMIT); a
  caller can never pass a larger one. Pane ids, births, request ids and TTLs
  are validated. SQLite foreign keys are ON for every connection: requests
  reference a registered owner and an existing (label, generation) lease.

ceiling: pane birth is identity, not liveness proof — the caller supplies the
live pane set (herdr pane list). Clock is the caller's `now` (UTC seconds).
"""
from __future__ import annotations

import re
import sqlite3
import time
import uuid
from datetime import datetime, timezone

SCHEMA_VERSION = 3
DEFAULT_MAX_OPEN = 5
MAX_OPEN_LIMIT = 50
MAX_TTL_S = 86_400
PANE_RE = re.compile(r"^w[0-9A-Za-z]{1,16}:p[0-9A-Za-z]{1,16}$")
BIRTH_RE = re.compile(r"^term_[0-9a-z]{1,40}$")
REQUEST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")
_PROJECT_RE = re.compile(
    r"^(?:(?:https://|ssh://git\x40)?github\.com[/:]|git\x40github\.com:)?(tntpgh)/([A-Za-z0-9._-]+?)(?:\.git)?/?$"
)

OPEN = ("queued", "held", "blocked", "delivering")
TERMINAL = ("replied", "evidence", "timeout", "stale", "cancelled")
TRANSITIONS = {
    "queued": {"held", "blocked", "delivering", "cancelled"},
    "held": {"queued", "cancelled"},
    "blocked": {"queued", "cancelled"},
    "delivering": {"replied", "timeout", "blocked"},
    "replied": {"evidence"},
}


class LeaseConflict(Exception):
    """Another live holder owns this label."""


class SuccessorRefused(Exception):
    """claim_successor() precondition failed. args[0] is a short machine
    code (live_predecessor | wrong_prev_generation | open_requests |
    same_holder); args[1] is a human-readable detail."""

    def __init__(self, code: str, detail: str):
        super().__init__(f"{code}: {detail}")
        self.code = code


class FencedOut(Exception):
    """Caller is not the current live holder (generation/pane/birth), or the
    request belongs to another generation."""


class QueueFull(Exception):
    """The owner already has `bound` open requests."""


class InvalidOwner(ValueError):
    """Bad label/project, or a mapping that would give a project two owners."""


class InvalidTransition(ValueError):
    pass


class Disabled(Exception):
    """Owner leasing is disabled (rolled back); mutations fail closed."""


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)  # explicit BEGINs only
    conn.execute("PRAGMA busy_timeout=10000")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


MIGRATIONS = {
    # v1 is the ORIGINAL schema exactly as first shipped (031641b). Never edit
    # it: databases created at v1 exist. Changes go in a new version.
    1: [
        "CREATE TABLE owner_projects (label TEXT PRIMARY KEY, project TEXT NOT NULL UNIQUE, registered_at TEXT NOT NULL)",
        """CREATE TABLE owner_leases (
             lease_id TEXT PRIMARY KEY, label TEXT NOT NULL REFERENCES owner_projects(label),
             pane_id TEXT NOT NULL, pane_birth TEXT NOT NULL, generation INTEGER NOT NULL,
             acquired_at TEXT NOT NULL, renewed_at TEXT NOT NULL, expires_at TEXT NOT NULL,
             released_at TEXT, release_reason TEXT, UNIQUE(label, generation))""",
        "CREATE UNIQUE INDEX owner_leases_one_live ON owner_leases(label) WHERE released_at IS NULL",
        """CREATE TABLE owner_requests (
             request_id TEXT PRIMARY KEY, label TEXT NOT NULL, generation INTEGER NOT NULL,
             state TEXT NOT NULL CHECK (state IN ('queued','held','blocked','delivering','replied','evidence','timeout','stale','cancelled')),
             created_at TEXT NOT NULL, updated_at TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '')""",
        "CREATE INDEX owner_requests_label_state ON owner_requests(label, state)",
        "CREATE INDEX owner_requests_label_gen ON owner_requests(label, generation)",
        """CREATE TABLE owner_events (
             seq INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, label TEXT NOT NULL,
             kind TEXT NOT NULL, ref TEXT NOT NULL DEFAULT '', generation INTEGER, detail TEXT NOT NULL DEFAULT '')""",
        "CREATE INDEX owner_events_label_seq ON owner_events(label, seq)",
        "CREATE TRIGGER owner_events_no_update BEFORE UPDATE ON owner_events BEGIN SELECT RAISE(ABORT, 'owner_events is append-only'); END",
        "CREATE TRIGGER owner_events_no_delete BEFORE DELETE ON owner_events BEGIN SELECT RAISE(ABORT, 'owner_events is append-only'); END",
    ],
    # v2: owner_state (enable/disable), owner_projects.max_open, and real FKs on
    # requests/events. SQLite cannot add FKs in place, so tables are rebuilt by
    # copy (rows, seq numbers and append-only triggers preserved). migrate()
    # runs this with foreign_keys OFF and fails the upgrade on any FK violation.
    2: [
        "CREATE TABLE owner_state (id INTEGER PRIMARY KEY CHECK (id = 1), enabled INTEGER NOT NULL CHECK (enabled IN (0,1)), changed_at TEXT NOT NULL)",
        "INSERT INTO owner_state VALUES (1, 1, '1970-01-01T00:00:00.000000Z')",
        f"""CREATE TABLE owner_projects_v2 (label TEXT PRIMARY KEY, project TEXT NOT NULL UNIQUE, registered_at TEXT NOT NULL,
             max_open INTEGER NOT NULL CHECK (max_open BETWEEN 1 AND {MAX_OPEN_LIMIT}))""",
        f"INSERT INTO owner_projects_v2 SELECT label, project, registered_at, {DEFAULT_MAX_OPEN} FROM owner_projects",
        "DROP TABLE owner_projects",
        "ALTER TABLE owner_projects_v2 RENAME TO owner_projects",
        """CREATE TABLE owner_requests_v2 (
             request_id TEXT PRIMARY KEY, label TEXT NOT NULL REFERENCES owner_projects(label), generation INTEGER NOT NULL,
             state TEXT NOT NULL CHECK (state IN ('queued','held','blocked','delivering','replied','evidence','timeout','stale','cancelled')),
             created_at TEXT NOT NULL, updated_at TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
             FOREIGN KEY (label, generation) REFERENCES owner_leases(label, generation))""",
        "INSERT INTO owner_requests_v2 SELECT request_id, label, generation, state, created_at, updated_at, detail FROM owner_requests",
        "DROP TABLE owner_requests",
        "ALTER TABLE owner_requests_v2 RENAME TO owner_requests",
        "CREATE INDEX owner_requests_label_state ON owner_requests(label, state)",
        "CREATE INDEX owner_requests_label_gen ON owner_requests(label, generation)",
        """CREATE TABLE owner_events_v2 (
             seq INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, label TEXT NOT NULL REFERENCES owner_projects(label),
             kind TEXT NOT NULL, ref TEXT NOT NULL DEFAULT '', generation INTEGER, detail TEXT NOT NULL DEFAULT '')""",
        "INSERT INTO owner_events_v2 (seq, at, label, kind, ref, generation, detail) SELECT seq, at, label, kind, ref, generation, detail FROM owner_events",
        "DROP TABLE owner_events",  # DROP fires no DELETE trigger; rows were copied above
        "ALTER TABLE owner_events_v2 RENAME TO owner_events",
        "CREATE INDEX owner_events_label_seq ON owner_events(label, seq)",
        "CREATE TRIGGER owner_events_no_update BEFORE UPDATE ON owner_events BEGIN SELECT RAISE(ABORT, 'owner_events is append-only'); END",
        "CREATE TRIGGER owner_events_no_delete BEFORE DELETE ON owner_events BEGIN SELECT RAISE(ABORT, 'owner_events is append-only'); END",
    ],
    # v3: the holder's agent-session digest (full sha256 hex) is part of lease
    # authority: (label, pane_id, pane_birth, session_digest, generation).
    # Pre-v3 leases carry '' and therefore never satisfy holder_tuple().
    3: [
        "ALTER TABLE owner_leases ADD COLUMN session_digest TEXT NOT NULL DEFAULT ''",
    ],
}


def migrate(conn: sqlite3.Connection) -> int:
    """Apply pending versioned migrations atomically. Returns the schema version.

    FKs are off for the duration (table rebuilds need it; the pragma is a no-op
    inside a transaction) and every FK is checked before COMMIT."""
    conn.execute("PRAGMA foreign_keys=OFF")
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS owner_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
        cur = conn.execute("SELECT COALESCE(MAX(version),0) FROM owner_schema_version").fetchone()[0]
        for v in sorted(MIGRATIONS):
            if v > cur:
                for stmt in MIGRATIONS[v]:
                    conn.execute(stmt)
                conn.execute("INSERT INTO owner_schema_version VALUES (?,?)", (v, _iso(time.time())))
                cur = v
        bad = conn.execute("PRAGMA foreign_key_check").fetchall()
        if bad:
            raise sqlite3.IntegrityError(f"migration left {len(bad)} foreign-key violation(s): {bad[:3]}")
        conn.execute("COMMIT")
        return cur
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    finally:
        conn.execute("PRAGMA foreign_keys=ON")


def _event(conn, now, label, kind, ref="", generation=None, detail=""):
    conn.execute("INSERT INTO owner_events(at,label,kind,ref,generation,detail) VALUES (?,?,?,?,?,?)",
                 (_iso(now), label, kind, ref, generation, detail))


def _tx(conn, fn, mutation=True):
    conn.execute("BEGIN IMMEDIATE")
    try:
        if mutation and conn.execute("SELECT enabled FROM owner_state WHERE id=1").fetchone() != (1,):
            raise Disabled("owner leasing is disabled")
        out = fn()
        conn.execute("COMMIT")
        return out
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def canonical_project(value: str) -> str:
    """'tntpgh/X', github https/ssh URLs, with or without .git -> 'tntpgh/x'."""
    m = _PROJECT_RE.match((value or "").strip())
    if not m:
        raise InvalidOwner(f"not a canonical tntpgh project: {value!r}")
    return f"{m.group(1)}/{m.group(2).lower()}"


def _check(regex, value, what):
    if not isinstance(value, str) or not regex.match(value):
        raise ValueError(f"invalid {what}: {value!r}")


def _check_holder(pane_id, pane_birth):
    _check(PANE_RE, pane_id, "pane id")
    _check(BIRTH_RE, pane_birth, "pane birth")


def register_owner(conn, label: str, project: str, max_open: int = DEFAULT_MAX_OPEN, now: float | None = None) -> str:
    """Map label <-> canonical project with its queue policy. Idempotent for the
    same pair; any other overlap (label to another project, project to another
    label) is refused."""
    now = time.time() if now is None else now
    if not isinstance(label, str) or not LABEL_RE.match(label):
        raise InvalidOwner(f"invalid owner label {label!r}")
    if not isinstance(max_open, int) or isinstance(max_open, bool) or not 1 <= max_open <= MAX_OPEN_LIMIT:
        raise InvalidOwner(f"max_open must be an int in 1..{MAX_OPEN_LIMIT}")
    proj = canonical_project(project)

    def body():
        row = conn.execute("SELECT label, project FROM owner_projects WHERE label=? OR project=?", (label, proj)).fetchall()
        if row == [(label, proj)]:
            return proj
        if row:
            raise InvalidOwner(f"{label} -> {proj} conflicts with existing {row}")
        conn.execute("INSERT INTO owner_projects VALUES (?,?,?,?)", (label, proj, _iso(now), max_open))
        _event(conn, now, label, "registered", proj)
        return proj

    return _tx(conn, body)


SESSION_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")


def _live(conn, label, now):
    """Current live lease (unreleased, unexpired) or None."""
    return conn.execute(
        "SELECT lease_id, pane_id, pane_birth, generation, renewed_at, expires_at, session_digest FROM owner_leases "
        "WHERE label=? AND released_at IS NULL AND expires_at > ?", (label, _iso(now))).fetchone()


def _successor_insert(conn, label, pane_id, pane_birth, ttl_s, now, session_digest) -> int:
    """Release every unreleased lease row for `label` as expired and insert
    the successor at MAX(generation)+1, staling any still-open requests of
    older generations, all within the caller's transaction. Shared by
    acquire()'s generation-change branch and claim_successor()."""
    for (old_id, old_gen) in conn.execute(
            "SELECT lease_id, generation FROM owner_leases WHERE label=? AND released_at IS NULL", (label,)).fetchall():
        conn.execute("UPDATE owner_leases SET released_at=?, release_reason='expired' WHERE lease_id=?", (_iso(now), old_id))
        _event(conn, now, label, "released", old_id, old_gen, "expired")
    gen = conn.execute("SELECT COALESCE(MAX(generation),0)+1 FROM owner_leases WHERE label=?", (label,)).fetchone()[0]
    lease_id = f"ol_{uuid.uuid4().hex}"
    conn.execute("INSERT INTO owner_leases(lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,expires_at,"
                 "session_digest) VALUES (?,?,?,?,?,?,?,?,?)",
                 (lease_id, label, pane_id, pane_birth, gen, _iso(now), _iso(now), _iso(now + ttl_s), session_digest))
    _event(conn, now, label, "acquired", lease_id, gen, f"{pane_id}@{pane_birth}")
    stale = conn.execute(
        f"SELECT request_id, generation FROM owner_requests WHERE label=? AND generation<? AND state IN ({_q(OPEN)})",
        (label, gen, *OPEN)).fetchall()
    for rid, rgen in stale:
        conn.execute("UPDATE owner_requests SET state='stale', updated_at=? WHERE request_id=?", (_iso(now), rid))
        _event(conn, now, label, "request:stale", rid, rgen, f"superseded by gen {gen}")
    return gen


def acquire(conn, label: str, pane_id: str, pane_birth: str, ttl_s: int, now: float | None = None,
            session_digest: str = "") -> int:
    """Acquire or renew. Returns the holder's generation. On a generation change,
    the expired predecessor is released and its open requests disposed `stale`,
    all in the same transaction as the successor's insert. session_digest is ''
    or a full sha256 hex; a renewal must present the SAME digest (a session
    change is a different holder and waits for expiry)."""
    now = time.time() if now is None else now
    _check_holder(pane_id, pane_birth)
    if session_digest and not SESSION_DIGEST_RE.match(session_digest):
        raise ValueError("session_digest must be '' or 64 lowercase hex")
    if not isinstance(ttl_s, int) or isinstance(ttl_s, bool) or not 1 <= ttl_s <= MAX_TTL_S:
        raise ValueError(f"ttl_s must be an int in 1..{MAX_TTL_S}")

    def body():
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (label,)).fetchone():
            raise InvalidOwner(f"{label} is not a registered owner")
        cur = _live(conn, label, now)
        if cur:
            lease_id, pane, birth, gen, _r, _e, sess = cur
            if (pane, birth, sess) != (pane_id, pane_birth, session_digest):
                raise LeaseConflict(f"{label} held by {pane}@{birth} gen {gen}")
            conn.execute("UPDATE owner_leases SET renewed_at=?, expires_at=? WHERE lease_id=?",
                         (_iso(now), _iso(now + ttl_s), lease_id))
            _event(conn, now, label, "renewed", lease_id, gen)
            return gen
        return _successor_insert(conn, label, pane_id, pane_birth, ttl_s, now, session_digest)

    return _tx(conn, body)


def claim_initial(conn, label: str, pane_id: str, pane_birth: str, ttl_s: int, session_digest: str,
                  now: float | None = None) -> int:
    """INITIAL-ONLY claim: generation 1 for a label that has NEVER had a lease
    and has no owner_requests at all. Refuses (LeaseConflict) on any prior
    lease row, released or not, expired or not, and on any request row. It
    never releases, reaps, stales or renews anything, and never takes a later
    generation: those are acquire()'s successor branch, not reachable here."""
    now = time.time() if now is None else now
    _check_holder(pane_id, pane_birth)
    if not SESSION_DIGEST_RE.match(session_digest or ""):
        raise ValueError("session_digest must be 64 lowercase hex")
    if not isinstance(ttl_s, int) or isinstance(ttl_s, bool) or not 1 <= ttl_s <= MAX_TTL_S:
        raise ValueError(f"ttl_s must be an int in 1..{MAX_TTL_S}")

    def body():
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (label,)).fetchone():
            raise InvalidOwner(f"{label} is not a registered owner")
        if conn.execute("SELECT 1 FROM owner_leases WHERE label=? LIMIT 1", (label,)).fetchone():
            raise LeaseConflict(f"{label} has prior lease history; initial claim only")
        if conn.execute("SELECT 1 FROM owner_requests WHERE label=? LIMIT 1", (label,)).fetchone():
            raise LeaseConflict(f"{label} has request/recovery history; initial claim only")
        lease_id = f"ol_{uuid.uuid4().hex}"
        conn.execute("INSERT INTO owner_leases(lease_id,label,pane_id,pane_birth,generation,acquired_at,renewed_at,expires_at,"
                     "session_digest) VALUES (?,?,?,?,1,?,?,?,?)",
                     (lease_id, label, pane_id, pane_birth, _iso(now), _iso(now), _iso(now + ttl_s), session_digest))
        _event(conn, now, label, "acquired", lease_id, 1, f"{pane_id}@{pane_birth} initial")
        return 1

    return _tx(conn, body)


def claim_successor(conn, label: str, expected_prev_gen: int, expected_prev_pane_id: str, expected_prev_pane_birth: str,
                    expected_prev_session_digest: str, pane_id: str, pane_birth: str, ttl_s: int, session_digest: str,
                    now: float | None = None) -> int:
    """SUCCESSOR-ONLY claim: the next generation after an EXPIRED predecessor
    bound by its FULL tuple (pane_id, pane_birth, session_digest,
    generation) -- not the generation number alone. Reuses acquire()'s
    successor transition (_successor_insert: release every unreleased row as
    expired, gen = MAX+1, stale older-generation open requests) in the SAME
    IMMEDIATE transaction, but first ADDITIONALLY refuses (SuccessorRefused)
    unless: the predecessor is NOT live (no renewal or takeover of an
    unexpired lease -- that is acquire()'s job, not this one's); the
    predecessor's generation is exactly expected_prev_gen; the predecessor's
    (pane_id, pane_birth, session_digest) is exactly
    (expected_prev_pane_id, expected_prev_pane_birth,
    expected_prev_session_digest) -- a same-generation but replaced/
    different holder, INCLUDING a holder that renewed under the same
    pane_id/pane_birth with a new session, is refused even though the
    generation number alone would have matched; the label has ZERO open
    owner_requests (so the reused stale-loop is a verified no-op, never a
    silent disposal); and the new holder differs from the predecessor
    holder (a same-holder "successor" is a renewal in disguise). All of the
    above is checked inside the one IMMEDIATE transaction before any write.
    Never renews, retries or takes over a live lease; never DELETEs; writes
    nothing outside that transaction, and a refusal writes nothing at all."""
    now = time.time() if now is None else now
    _check_holder(pane_id, pane_birth)
    _check_holder(expected_prev_pane_id, expected_prev_pane_birth)
    if not SESSION_DIGEST_RE.match(session_digest or ""):
        raise ValueError("session_digest must be 64 lowercase hex")
    if not SESSION_DIGEST_RE.match(expected_prev_session_digest or ""):
        raise ValueError("expected_prev_session_digest must be 64 lowercase hex")
    if not isinstance(ttl_s, int) or isinstance(ttl_s, bool) or not 1 <= ttl_s <= MAX_TTL_S:
        raise ValueError(f"ttl_s must be an int in 1..{MAX_TTL_S}")
    if not isinstance(expected_prev_gen, int) or isinstance(expected_prev_gen, bool) or expected_prev_gen < 1:
        raise ValueError("expected_prev_gen must be an int >= 1")

    def body():
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (label,)).fetchone():
            raise InvalidOwner(f"{label} is not a registered owner")
        if _live(conn, label, now):
            raise SuccessorRefused("live_predecessor",
                                   f"{label}: predecessor lease is live (unexpired); successor claims are expired-only")
        row = conn.execute(
            "SELECT pane_id, pane_birth, session_digest, generation FROM owner_leases WHERE label=? "
            "ORDER BY generation DESC LIMIT 1", (label,)).fetchone()
        prev_pane, prev_birth, prev_sess, prev_gen = row if row else (None, None, None, 0)
        if prev_gen != expected_prev_gen:
            raise SuccessorRefused("wrong_prev_generation",
                                   f"{label}: predecessor generation {prev_gen} != expected_prev_gen {expected_prev_gen}")
        if (prev_pane, prev_birth, prev_sess) != (expected_prev_pane_id, expected_prev_pane_birth, expected_prev_session_digest):
            raise SuccessorRefused("prev_holder_mismatch",
                                   f"{label}: generation {prev_gen} is held by {prev_pane}@{prev_birth} (session "
                                   f"{(prev_sess or '')[:8]}), expected {expected_prev_pane_id}@{expected_prev_pane_birth} "
                                   f"(session {expected_prev_session_digest[:8]})")
        n_open = conn.execute(
            f"SELECT COUNT(*) FROM owner_requests WHERE label=? AND state IN ({_q(OPEN)})", (label, *OPEN)).fetchone()[0]
        if n_open:
            raise SuccessorRefused("open_requests", f"{label}: {n_open} open owner_requests; refused rather than silently staled")
        if (pane_id, pane_birth, session_digest) == (prev_pane, prev_birth, prev_sess):
            raise SuccessorRefused("same_holder", f"{label}: new holder {pane_id}@{pane_birth} equals predecessor holder")
        return _successor_insert(conn, label, pane_id, pane_birth, ttl_s, now, session_digest)

    return _tx(conn, body)


def holder_tuple(conn, label, now=None):
    """(pane_id, pane_birth, session_digest, generation) of the live lease, or
    None when there is none or it carries no session digest. Read-only."""
    cur = _live(conn, label, time.time() if now is None else now)
    if not cur or not SESSION_DIGEST_RE.match(cur[6] or ""):
        return None
    return (cur[1], cur[2], cur[6], cur[3])


def _q(items):
    return ",".join("?" * len(items))


def _fence(conn, label, generation, pane_id, pane_birth, now):
    cur = _live(conn, label, now)
    if not cur or (cur[3], cur[1], cur[2]) != (generation, pane_id, pane_birth):
        raise FencedOut(f"{label}: caller gen {generation} {pane_id}@{pane_birth}, live {cur[1:4] if cur else None}")


def check_fence(conn, label, generation, pane_id, pane_birth, now=None) -> None:
    """Read-only: works while disabled too."""
    _fence(conn, label, generation, pane_id, pane_birth, time.time() if now is None else now)


def release(conn, label, generation, pane_id, pane_birth, now=None) -> bool:
    """Voluntary release by the current holder only (fenced)."""
    now = time.time() if now is None else now

    def body():
        _fence(conn, label, generation, pane_id, pane_birth, now)
        conn.execute("UPDATE owner_leases SET released_at=?, release_reason='released' "
                     "WHERE label=? AND generation=? AND released_at IS NULL", (_iso(now), label, generation))
        _event(conn, now, label, "released", "", generation, "voluntary")
        return True

    return _tx(conn, body)


def enqueue(conn, label, generation, pane_id, pane_birth, request_id, now=None) -> dict:
    """Fenced, bounded by the owner's registered max_open, atomic.
    The caller is authenticated as the current holder FIRST, then:
    a new id -> {'state':'queued','authority':True}; an existing id -> its
    durable prior outcome with authority False (never a fresh delivery grant)."""
    now = time.time() if now is None else now
    _check_holder(pane_id, pane_birth)
    _check(REQUEST_RE, request_id, "request id")

    def body():
        _fence(conn, label, generation, pane_id, pane_birth, now)
        row = conn.execute("SELECT label, generation, state FROM owner_requests WHERE request_id=?", (request_id,)).fetchone()
        if row:
            return {"request_id": request_id, "label": row[0], "generation": row[1], "state": row[2], "authority": False}
        bound = conn.execute("SELECT max_open FROM owner_projects WHERE label=?", (label,)).fetchone()[0]
        n = conn.execute(f"SELECT COUNT(*) FROM owner_requests WHERE label=? AND state IN ({_q(OPEN)})", (label, *OPEN)).fetchone()[0]
        if n >= bound:
            raise QueueFull(f"{label}: {n} open >= max_open {bound}")
        conn.execute("INSERT INTO owner_requests(request_id,label,generation,state,created_at,updated_at) VALUES (?,?,?,?,?,?)",
                     (request_id, label, generation, "queued", _iso(now), _iso(now)))
        _event(conn, now, label, "request:queued", request_id, generation)
        return {"request_id": request_id, "label": label, "generation": generation, "state": "queued", "authority": True}

    return _tx(conn, body)


def transition(conn, request_id, to, label, generation, pane_id, pane_birth, detail="", now=None) -> str:
    """Fenced state change. The request must belong to the caller's label AND
    current generation; `stale` is never a caller transition."""
    now = time.time() if now is None else now
    _check_holder(pane_id, pane_birth)
    _check(REQUEST_RE, request_id, "request id")

    def body():
        _fence(conn, label, generation, pane_id, pane_birth, now)
        row = conn.execute("SELECT label, generation, state FROM owner_requests WHERE request_id=?", (request_id,)).fetchone()
        if not row:
            raise InvalidTransition(f"unknown request {request_id}")
        if row[:2] != (label, generation):
            raise FencedOut(f"{request_id} belongs to {row[0]} gen {row[1]}, caller {label} gen {generation}")
        if to not in TRANSITIONS.get(row[2], set()):
            raise InvalidTransition(f"{request_id}: {row[2]} -> {to} not allowed")
        conn.execute("UPDATE owner_requests SET state=?, updated_at=?, detail=? WHERE request_id=? AND state=?",
                     (to, _iso(now), detail, request_id, row[2]))
        _event(conn, now, label, f"request:{to}", request_id, generation, detail)
        return to

    return _tx(conn, body)


def observe_stale(conn, live_panes: set, now=None) -> list[dict]:
    """Unreleased leases whose holder is gone from the live pane set or expired,
    with the exact identity reap() must CAS on."""
    now = time.time() if now is None else now
    out = []
    for lease_id, label, pane, birth, gen, renewed, expires in conn.execute(
            "SELECT lease_id,label,pane_id,pane_birth,generation,renewed_at,expires_at FROM owner_leases WHERE released_at IS NULL"):
        reason = "expired" if expires <= _iso(now) else ("pane-gone" if (pane, birth) not in live_panes else None)
        if reason:
            out.append({"lease_id": lease_id, "label": label, "pane": pane, "birth": birth, "generation": gen,
                        "renewed_at": renewed, "expires_at": expires, "reason": reason})
    return out


_OBS_KEYS = ("lease_id", "label", "generation", "pane", "birth", "renewed_at", "expires_at", "reason")


def reap(conn, observed: list[dict], now=None, dry_run=True) -> list[dict]:
    """Release observed stale leases (registry rows only; never a pane). The
    release is a CAS on the COMPLETE observed identity: lease_id, label,
    generation, pane, birth, renewed_at and expires_at must all still match.
    Event metadata comes from the matched DB row, never from the caller.
    Dry-run by default."""
    now = time.time() if now is None else now
    for o in observed:
        if not isinstance(o, dict) or any(k not in o for k in _OBS_KEYS):
            raise ValueError(f"observation missing {[k for k in _OBS_KEYS if k not in (o or {})]}")
    if dry_run:
        return [dict(o, released=False, dry_run=True) for o in observed]

    def body():
        res = []
        for o in observed:
            row = conn.execute(
                "SELECT lease_id, label, generation FROM owner_leases WHERE lease_id=? AND label=? AND generation=? "
                "AND pane_id=? AND pane_birth=? AND renewed_at=? AND expires_at=? AND released_at IS NULL",
                (o["lease_id"], o["label"], o["generation"], o["pane"], o["birth"], o["renewed_at"], o["expires_at"])).fetchone()
            if row:
                conn.execute("UPDATE owner_leases SET released_at=?, release_reason=? WHERE lease_id=? AND released_at IS NULL",
                             (_iso(now), f"reaped:{o['reason']}", row[0]))
                _event(conn, now, row[1], "reaped", row[0], row[2], o["reason"])
            else:
                known = conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (o["label"],)).fetchone()
                if known:
                    _event(conn, now, o["label"], "reap-skipped", str(o["lease_id"])[:64], None, "observation no longer matches")
            res.append(dict(o, released=bool(row)))
        return res

    return _tx(conn, body)


def disable(conn, now=None) -> None:
    """Non-destructive rollback: every mutation fails closed afterwards; all
    tables and events are preserved and readers keep working."""
    now = time.time() if now is None else now
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("UPDATE owner_state SET enabled=0, changed_at=? WHERE id=1", (_iso(now),))
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise


def export_backup(conn, dest_path: str) -> str:
    """Consistent SQLite copy to a NEW file created 0600 (refuses to overwrite)."""
    import os
    fd = os.open(dest_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    dst = sqlite3.connect(dest_path)
    try:
        conn.backup(dst)
    finally:
        dst.close()
    return dest_path
