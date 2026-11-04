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


Durable assignments (Plan 018 PR A, inert)
  v6 adds a SECOND authority_mode ('assignment') to owner_leases, sharing
  the same table, the same one-unreleased-row-per-label partial unique
  index, and the same label-local-monotonic generation as 'timed' leases.
  An assignment's expires_at is always NULL and is NEVER read by any TTL
  check: _live()'s own query treats it as live regardless of `now`. Only
  assign_initial(), assign_replace(), assign_revoke() and assign_settle()
  ever create, replace, release or settle one -- acquire()/claim_initial()/
  claim_successor() (the timed-only legacy path) refuse outright rather
  than implicitly converting or taking over an active assignment. Nothing
  outside this module reads authority_mode yet (PR B is the runtime gate).

Policy
  An owner's queue bound is its registered max_open (1..MAX_OPEN_LIMIT); a
  caller can never pass a larger one. Pane ids, births, request ids and TTLs
  are validated. SQLite foreign keys are ON for every connection: requests
  reference a registered owner and an existing (label, generation) lease.

ceiling: pane birth is identity, not liveness proof — the caller supplies the
live pane set (herdr pane list). Clock is the caller's `now` (UTC seconds).
"""
from __future__ import annotations

import hmac
import re
import sqlite3
import time
import uuid
from datetime import datetime, timezone

import private_sqlite

SCHEMA_VERSION = 6
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


class OpenRequests(Exception):
    """unregister_owner() refused: open (non-terminal) owner_requests exist
    for the label, in any generation."""


class Unauthorized(Exception):
    """unregister_owner() refused: missing/mismatched unregister_token, or
    the caller's (generation, pane_id, pane_birth) does not match the
    label's current live lease (R13-BOUNDS.md)."""


class AlreadyUnregistered(Exception):
    """register_owner() refused: the (label, project) row already exists
    and is unregistered (unregistered_at set) -- r15/F2: a plain
    re-registration must never silently clear that and resume as if
    nothing had happened, discarding whatever token/bound the caller
    supplied. reregister_owner() (lib/owner_lease.py) / owner-lease-
    reregister.py is the deliberate, explicit, authorized recovery path."""


class SchemaMigrationRequired(Exception):
    """R17b: a WRITE-capable open (open_rw_checked()) refused because the
    store's schema is behind SCHEMA_VERSION. No writer CLI migrates
    implicitly anymore (R17's own open_and_migrate() did, and the review
    that uncovered it (--dry-run silently migrating a live store) is why
    this exists) -- owner-lease-migrate.py is the one explicit, auditable
    path a schema actually advances through now. `cur`/`target` let the
    caller print the exact owner-lease-migrate.py invocation."""
    def __init__(self, cur: int, target: int):
        self.cur, self.target = cur, target
        super().__init__(f"schema at v{cur}, need v{target}")


class AssignmentConflict(Exception):
    """assign_initial() refused: the label already has an unreleased
    authority row (timed or assignment); initial assignment only applies
    to a managed label with no current holder."""


class ReplaceRefused(Exception):
    """assign_replace() precondition failed. args[0] is a short machine
    code (stale_expectation | open_requests | same_holder); args[1] is a
    human-readable detail."""

    def __init__(self, code: str, detail: str):
        super().__init__(f"{code}: {detail}")
        self.code = code


class RevokeRefused(Exception):
    """assign_revoke() precondition failed. args[0] is a short machine
    code (stale_expectation | not_assignment_mode); args[1] is a
    human-readable detail."""

    def __init__(self, code: str, detail: str):
        super().__init__(f"{code}: {detail}")
        self.code = code


class SettleRefused(Exception):
    """assign_settle() precondition failed. args[0] is a short machine code
    (unknown_request | wrong_generation | not_delivering |
    generation_still_active); args[1] is a human-readable detail."""

    def __init__(self, code: str, detail: str):
        super().__init__(f"{code}: {detail}")
        self.code = code


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)  # explicit BEGINs only
    conn.execute("PRAGMA busy_timeout=10000")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def connect_ro(path: str) -> sqlite3.Connection:
    """R17b: the read-only connector for dry-run/refused/validation-failure
    CLI paths and owner-lease-migrate.py's default plan mode -- sqlite
    mode=ro URI, same pattern owner-lease-reap.py already used. Any write
    attempt fails at SQLite itself, not by caller discipline."""
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=3, isolation_level=None)


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
    # v4: per-label rollback (R12-RENEWAL.md). unregistered_at is nullable
    # and defaults NULL for every existing row -- a plain ADD COLUMN, no
    # table rebuild, no FK involved. NULL = registered (unchanged meaning
    # for every pre-v4 row); non-NULL = unregister_owner() has run and the
    # per-label gate's registered() (lib/owner_lease_delivery.py) must
    # treat the label as never-registered again. The row itself is still
    # never deleted: FK-protected the moment a lease or request exists, and
    # unregister_owner() never attempts a DELETE.
    4: [
        "ALTER TABLE owner_projects ADD COLUMN unregistered_at TEXT",
    ],
    # v5: bounded renewal + authorized unregister (R13-BOUNDS.md). Both
    # nullable, both recorded ONLY at register_owner() time ("at approval"),
    # never updated afterward by this file -- extending a label's lifecycle
    # or rotating its token is a deliberate separate decision, not built
    # here because R13 did not ask for it.
    #   lifecycle_end_at  ABSOLUTE bound (owner_lease_renew.py: renew_due()
    #     refuses -- "no_lifecycle_bound" -- for any label where this is
    #     NULL; once set, a renewal's effective TTL is clamped so
    #     expires_at never crosses it, and once now >= it renewal stops
    #     entirely ("lifecycle_ended") -- the label then fails closed on
    #     its own existing TTL, exactly like any other unrenewed lease.
    #   unregister_token  the "approval/token argument bound to the label"
    #     unregister_owner() requires verbatim (hmac.compare_digest) before
    #     doing anything else, including before the idempotent
    #     already-unregistered check -- a wrong token learns nothing.
    5: [
        "ALTER TABLE owner_projects ADD COLUMN lifecycle_end_at TEXT",
        "ALTER TABLE owner_projects ADD COLUMN unregister_token TEXT",
    ],
    # v6 (Plan 018 PR A, inert): durable owner ASSIGNMENTS alongside existing
    # TIMED leases in the SAME table (plan 4.1: "The first compatibility
    # release may retain the physical table name owner_leases"). Rebuilt by
    # copy (SQLite cannot relax expires_at's NOT NULL in place, nor ADD a
    # column with a CHECK that references another column):
    #   authority_mode  'timed' (unchanged semantics) | 'assignment'
    #     (durable; expires_at NULL, never read by any TTL/expiry check).
    #   project         backfilled from owner_projects for every historical
    #     row -- assignment ops need it without a second join on every call.
    #   expires_at      now nullable; the CHECK enforces the exact pairing
    #     (timed -> NOT NULL, assignment -> NULL) at the engine level, not
    #     by caller discipline.
    #   decision_ref/reason  '' for every historical (timed) row; required
    #     non-empty by assign_initial()/assign_replace()/assign_revoke().
    # Every historical row copies authority_mode='timed' byte-for-byte
    # otherwise -- nothing becomes durable automatically (SPEC: "Keep
    # compatibility bounded"). The one-live-row partial unique index is
    # recreated unchanged: it already enforces "one unreleased authority
    # per label" for BOTH modes, since it only keys on released_at.
    6: [
        """CREATE TABLE owner_leases_v6 (
             lease_id TEXT PRIMARY KEY, label TEXT NOT NULL REFERENCES owner_projects(label),
             project TEXT NOT NULL, pane_id TEXT NOT NULL, pane_birth TEXT NOT NULL, generation INTEGER NOT NULL,
             acquired_at TEXT NOT NULL, renewed_at TEXT NOT NULL, expires_at TEXT,
             released_at TEXT, release_reason TEXT, session_digest TEXT NOT NULL DEFAULT '',
             authority_mode TEXT NOT NULL CHECK (authority_mode IN ('timed','assignment')),
             decision_ref TEXT NOT NULL DEFAULT '', reason TEXT NOT NULL DEFAULT '',
             UNIQUE(label, generation),
             CHECK ((authority_mode='timed' AND expires_at IS NOT NULL) OR (authority_mode='assignment' AND expires_at IS NULL)))""",
        """INSERT INTO owner_leases_v6
           (lease_id,label,project,pane_id,pane_birth,generation,acquired_at,renewed_at,expires_at,
            released_at,release_reason,session_digest,authority_mode,decision_ref,reason)
           SELECT l.lease_id,l.label,p.project,l.pane_id,l.pane_birth,l.generation,l.acquired_at,l.renewed_at,
                  l.expires_at,l.released_at,l.release_reason,l.session_digest,'timed','',''
           FROM owner_leases l JOIN owner_projects p ON p.label=l.label""",
        "DROP TABLE owner_leases",
        "ALTER TABLE owner_leases_v6 RENAME TO owner_leases",
        "CREATE UNIQUE INDEX owner_leases_one_live ON owner_leases(label) WHERE released_at IS NULL",
    ],
}


def _infer_pre_tracking_version(conn: sqlite3.Connection) -> int:
    """R17: the live store already had tables shaped like v1-v3 (owner_projects
    with max_open, owner_leases with session_digest) WITHOUT owner_schema_version
    ever existing -- that table, and the whole incremental MIGRATIONS scheme,
    did not exist yet when this store's tables were first created; nobody ever
    called migrate() against it even once. COALESCE(MAX(version),0) therefore
    reads 0 on a store that is NOT actually empty, and blindly running v1's
    bare `CREATE TABLE owner_projects (...)` (no IF NOT EXISTS; none of these
    statements have one, by design -- a silent no-op on mismatch would be
    worse than a loud crash) raises 'table owner_projects already exists'.

    Infers the real starting version by introspecting the columns/tables each
    version's own migration would have created, instead of trusting a version
    counter that may simply never have been written. A genuinely fresh,
    empty database (no owner_projects table at all) returns 0, unchanged from
    before -- this only changes behavior for a store that already has tables
    migrate() itself did not create. Not persisted: re-run every time migrate()
    sees cur==0, which is correct and idempotent by construction (same inputs,
    same answer) rather than fabricating an applied_at timestamp for history
    this process never observed."""
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
    if "owner_projects" not in tables:
        return 0
    proj_cols = {r[1] for r in conn.execute("PRAGMA table_info(owner_projects)").fetchall()}
    if "unregister_token" in proj_cols and "lifecycle_end_at" in proj_cols:
        return 5
    if "unregistered_at" in proj_cols:
        return 4
    lease_cols = {r[1] for r in conn.execute("PRAGMA table_info(owner_leases)").fetchall()} if "owner_leases" in tables else set()
    if "session_digest" in lease_cols:
        return 3
    if "max_open" in proj_cols:
        return 2
    return 1


def migrate(conn: sqlite3.Connection) -> int:
    """Apply pending versioned migrations atomically. Returns the schema version.
    The ONLY caller now is owner-lease-migrate.py --apply (R17b): no CLI
    open path calls this implicitly anymore -- see open_rw_checked()/open_ro().

    FKs are off for the duration (table rebuilds need it; the pragma is a no-op
    inside a transaction) and every FK is checked before COMMIT -- but ONLY
    when a migration actually ran this call (checking FKs on an already-
    current store that merely has a transient, migration-unrelated FK
    violation -- e.g. a test fixture built with PRAGMA foreign_keys=OFF --
    would reject something that isn't this call's problem; a future version
    bump still gets checked, since 'cur != start' stays true for that)."""
    conn.execute("PRAGMA foreign_keys=OFF")
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS owner_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
        cur = conn.execute("SELECT COALESCE(MAX(version),0) FROM owner_schema_version").fetchone()[0]
        if cur == 0:
            cur = _infer_pre_tracking_version(conn)
        start = cur
        for v in sorted(MIGRATIONS):
            if v > cur:
                for stmt in MIGRATIONS[v]:
                    conn.execute(stmt)
                conn.execute("INSERT INTO owner_schema_version VALUES (?,?)", (v, _iso(time.time())))
                cur = v
        if cur != start:
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


def current_version(conn: sqlite3.Connection) -> int:
    """R17b: read-only-safe version probe -- works on a mode=ro connection
    (no CREATE TABLE, unlike migrate()'s own tracking-table bootstrap).
    Checks owner_schema_version's existence via sqlite_master first (SELECT
    against a table that doesn't exist would raise OperationalError, which
    a read-only caller has no transaction to roll back from); falls back to
    _infer_pre_tracking_version() exactly like migrate() does when cur==0,
    or when the table itself is simply absent."""
    has_tracking = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='owner_schema_version'").fetchone()
    if has_tracking:
        cur = conn.execute("SELECT COALESCE(MAX(version),0) FROM owner_schema_version").fetchone()[0]
        if cur > 0:
            return cur
    return _infer_pre_tracking_version(conn)


def schema_status(conn: sqlite3.Connection) -> tuple[int, int]:
    """(current_version, SCHEMA_VERSION) -- read-only safe."""
    return current_version(conn), SCHEMA_VERSION


def open_ro(path: str, require_table: str = "") -> sqlite3.Connection:
    """R17b: the read-only open for dry-run / refused / validation-failure
    CLI paths. Never migrates (can't -- sqlite mode=ro rejects any write at
    the engine level, not by caller discipline), so schema_status() is the
    only way these paths learn whether a migration is pending, to report
    it rather than silently (or crashingly) acting on a stale schema."""
    return private_sqlite.open_private(path, connect_ro, require_table=require_table)


def open_rw_checked(path: str, require_table: str = "") -> sqlite3.Connection:
    """R17b: the ONE shared WRITE-capable open path every owner_lease writer
    CLI (owner-register.py, owner-dispatch-issue.py, owner-dispatch.py,
    owner-lease-claim.py, owner-lease-reregister.py, owner-lease-resume.py,
    owner-lease-unregister.py, queue-supervisor.py) uses instead of calling
    private_sqlite.open_private(path, ol.connect, ...) directly. Replaces
    R17's open_and_migrate(), which migrated on EVERY open including a
    --dry-run call -- rejected on review (REVIEW-r17): "zero business-row
    writes" is not the same promise as read-only, and a dry-run silently
    advancing schema_version was a real, unwanted write. This function
    NEVER migrates, and checks the schema version via a READ-ONLY probe
    FIRST (sqlite mode=ro -- same discipline as open_ro()/owner-lease-
    reap.py): a read-write connection is only ever opened once the schema
    is confirmed current. If the store is behind SCHEMA_VERSION it raises
    SchemaMigrationRequired(cur, SCHEMA_VERSION) without ever opening
    read-write -- the caller prints refused:schema_migration_required and
    names owner-lease-migrate.py, the one explicit, auditable, backed-up
    path a schema now advances through. Not used by owner-lease-reap.py
    (read-only by design); not pushed into private_sqlite.open_private()
    itself, which is generic (also used by lib/owner_dispatch_auth.py's
    own, unrelated migration scheme)."""
    probe = private_sqlite.open_private(path, connect_ro, require_table=require_table)
    try:
        cur = current_version(probe)
    finally:
        probe.close()
    if cur < SCHEMA_VERSION:
        raise SchemaMigrationRequired(cur, SCHEMA_VERSION)
    return private_sqlite.open_private(path, connect, require_table=require_table)


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


def register_owner(conn, label: str, project: str, max_open: int = DEFAULT_MAX_OPEN, now: float | None = None,
                   lifecycle_end_at: float | None = None, unregister_token: str | None = None) -> str:
    """Map label <-> canonical project with its queue policy. Idempotent for the
    same pair; any other overlap (label to another project, project to another
    label) is refused.

    lifecycle_end_at (R13-BOUNDS.md): an ABSOLUTE epoch-seconds bound
    recorded ONLY on first insert -- owner_lease_renew.py's renew_due()
    refuses to renew a label with no bound set at all, and clamps/stops at
    this one once it is. unregister_token: the authorization
    unregister_owner() requires verbatim. Neither is touched by an
    idempotent re-registration of the SAME (label, project) pair -- set
    once at approval, not silently replaced by a later call.

    r15/F2: if the (label, project) row already exists and is unregistered
    (unregistered_at set), this function REFUSES (AlreadyUnregistered)
    rather than silently clearing that and resuming as if nothing had
    happened -- a plain re-run of owner-register.py after an unregister
    must never discard whatever token/bound the caller just supplied by
    pretending to succeed. reregister_owner() is the deliberate, explicit,
    authorized recovery path."""
    now = time.time() if now is None else now
    if not isinstance(label, str) or not LABEL_RE.match(label):
        raise InvalidOwner(f"invalid owner label {label!r}")
    if not isinstance(max_open, int) or isinstance(max_open, bool) or not 1 <= max_open <= MAX_OPEN_LIMIT:
        raise InvalidOwner(f"max_open must be an int in 1..{MAX_OPEN_LIMIT}")
    proj = canonical_project(project)

    def body():
        rows = conn.execute("SELECT label, project, unregistered_at FROM owner_projects WHERE label=? OR project=?",
                            (label, proj)).fetchall()
        exact = [r for r in rows if (r[0], r[1]) == (label, proj)]
        if exact:
            if exact[0][2] is not None:
                raise AlreadyUnregistered(f"{label} -> {proj} was unregistered at {exact[0][2]}; "
                                          "use owner-lease-reregister.py to restore it explicitly")
            return proj
        if rows:
            raise InvalidOwner(f"{label} -> {proj} conflicts with existing {[(r[0], r[1]) for r in rows]}")
        conn.execute("INSERT INTO owner_projects(label,project,registered_at,max_open,lifecycle_end_at,unregister_token) "
                     "VALUES (?,?,?,?,?,?)",
                     (label, proj, _iso(now), max_open, _iso(lifecycle_end_at) if lifecycle_end_at is not None else None,
                      unregister_token))
        _event(conn, now, label, "registered", proj)
        return proj

    return _tx(conn, body)


def unregister_owner(conn, label: str, token: str, generation: int = 0, pane_id: str = "", pane_birth: str = "",
                     now: float | None = None, dry_run: bool = True) -> str:
    """Per-label rollback (R12/R13-BOUNDS.md): voluntarily release any live
    lease, then mark the owner_projects row unregistered (unregistered_at
    set) -- DeliveryGate.registered() (lib/owner_lease_delivery.py) then
    sees the label as never-registered again, returning it to the
    per-label gate's legacy delivery path. The row itself is still never
    deleted (FK-protected the moment a lease or request exists; this
    function never attempts a DELETE) -- this is a soft per-label disable.

    Authorization (R13-BOUNDS.md), checked FIRST, before even the
    idempotent already-unregistered short-circuit (a wrong token learns
    nothing): `token` must exactly match (hmac.compare_digest)
    owner_projects.unregister_token, recorded only at register_owner() time
    -- a label registered with no token can NEVER be unregistered through
    this function (fail closed, no fallback). If the label currently has a
    LIVE lease, (generation, pane_id, pane_birth) must additionally match
    it exactly (same fence shape as release()) -- unregistering an
    ACTIVELY-held label without the caller proving it knows that exact
    live state is refused. No live lease -> nothing to fence against, the
    token check alone is the authorization for that case.

    Dry-run by default (reap()'s own convention): every check below still
    runs and can still refuse (InvalidOwner/Unauthorized/OpenRequests),
    only the final mutation is skipped, so a dry-run of a refused call
    reports the SAME refusal a real run would. Idempotent:
    already-unregistered is a silent no-op ('already_unregistered') in
    both modes. Refuses (OpenRequests) while any OPEN owner_requests exist
    for the label, in ANY generation -- those are still-unresolved
    deliveries/replies that unregistering must never make silently
    unreachable.

    r14/TOCTOU fix: the checks below run ONCE as a cheap pre-check (fast
    refusal, and the only check that runs at all for dry_run, which must
    report a refusal without ever taking the write lock) -- but for a real
    --apply they are NOT the authorization. body() below re-reads the
    token, unregistered_at, live-lease identity fence, and OpenRequests
    count a SECOND time, from scratch, under _tx()'s BEGIN IMMEDIATE
    (SQLite's single-writer lock), exactly the pattern release()/
    enqueue()/transition() already use via _fence(). This closes the gap
    REVIEW-r14.md found: a concurrent legitimate claim or a newly-enqueued
    request landing in the window between the pre-check and the old
    unconditional body() could make unregister_owner() report success
    while tearing down a DIFFERENT holder's lease than the one the caller
    fenced against, or strand a brand-new open request. Now any such
    interleaving is caught by the re-check inside the lock and raises the
    same typed exception the pre-check would have, rolling back the
    transaction -- unregister_owner() never trusts a read taken before it
    held the write lock."""
    now = time.time() if now is None else now
    row = conn.execute("SELECT unregistered_at, unregister_token FROM owner_projects WHERE label=?",
                       (label,)).fetchone()
    if not row:
        raise InvalidOwner(f"{label} is not a registered owner")
    stored_token = row[1]
    if not stored_token or not hmac.compare_digest(stored_token, token or ""):
        raise Unauthorized(f"{label}: token mismatch")
    if row[0] is not None:
        return "already_unregistered"
    cur = _live(conn, label, now)
    if cur and (cur[3], cur[1], cur[2]) != (generation, pane_id, pane_birth):
        raise Unauthorized(f"{label}: generation/pane/birth does not match the live lease")
    open_n = conn.execute(f"SELECT COUNT(*) FROM owner_requests WHERE label=? AND state IN ({_q(OPEN)})",
                          (label, *OPEN)).fetchone()[0]
    if open_n:
        raise OpenRequests(f"{label}: {open_n} open owner_requests")
    if dry_run:
        return "would_unregister"

    def body():
        row2 = conn.execute("SELECT unregistered_at, unregister_token FROM owner_projects WHERE label=?",
                            (label,)).fetchone()
        if not row2:
            raise InvalidOwner(f"{label} is not a registered owner")
        stored_token2 = row2[1]
        if not stored_token2 or not hmac.compare_digest(stored_token2, token or ""):
            raise Unauthorized(f"{label}: token mismatch")
        if row2[0] is not None:
            return "already_unregistered"
        cur2 = _live(conn, label, now)
        if cur2 and (cur2[3], cur2[1], cur2[2]) != (generation, pane_id, pane_birth):
            raise Unauthorized(f"{label}: generation/pane/birth does not match the live lease")
        open_n2 = conn.execute(f"SELECT COUNT(*) FROM owner_requests WHERE label=? AND state IN ({_q(OPEN)})",
                               (label, *OPEN)).fetchone()[0]
        if open_n2:
            raise OpenRequests(f"{label}: {open_n2} open owner_requests")
        if cur2:
            lease_id, _pane, _birth, gen, _renewed, _expires, _sess, _mode = cur2
            conn.execute("UPDATE owner_leases SET released_at=?, release_reason='unregistered' WHERE lease_id=?",
                         (_iso(now), lease_id))
            _event(conn, now, label, "released", lease_id, gen, "unregistered")
        conn.execute("UPDATE owner_projects SET unregistered_at=? WHERE label=?", (_iso(now), label))
        _event(conn, now, label, "unregistered")
        return "unregistered"

    return _tx(conn, body)


def reregister_owner(conn, label: str, project: str, old_token: str, new_token: str, lifecycle_end_at: float,
                     now: float | None = None, dry_run: bool = True) -> str:
    """r15/F2's explicit, authorized recovery path for a label unregister_owner()
    has already turned off: clears unregistered_at, replacing BOTH
    unregister_token and lifecycle_end_at with freshly-supplied values --
    NEVER inherits the old ones (a stale token or an already-elapsed bound
    would make the restored label either unrecoverable again or already
    renewal-dead). Authorization is the SAME model as unregister_owner():
    `old_token` must match (hmac.compare_digest) the row's CURRENT
    unregister_token (unregister_owner() never clears it, only
    unregistered_at, so the original approval credential is exactly what
    proves the caller may restore it). `project` must match the row's
    canonical project exactly -- this is a restore, never a silent
    re-pointing of the label to a different project.

    r16/F3: the advisory read above is OUTSIDE any transaction (same as
    every other check in this function), but the actual write is a
    CONDITIONAL UPDATE re-keyed on the EXACT `(unregistered_at IS NOT
    NULL, unregister_token == <the stored_token this call just read>)`
    pair -- not a fresh re-read. A concurrent reregister_owner() call
    that already committed a DIFFERENT token in the window between this
    call's advisory read and its own `_tx()` makes the WHERE clause match
    nothing (`rowcount == 0`) -> `"race_lost"`, nothing written, never
    silently overwriting the other caller's already-reported success.
    Only one of two racing callers can ever see `"reregistered"`.

    Never creates or revives a lease: this is a owner_projects-row-only
    update; leases still come only from the normal acquire()/claim_*()
    path, same as every other registration here. Dry-run by default
    (every other writer in this module's own convention); every refusal
    check below still runs in both modes."""
    now = time.time() if now is None else now
    proj = canonical_project(project)
    row = conn.execute("SELECT project, unregistered_at, unregister_token FROM owner_projects WHERE label=?",
                       (label,)).fetchone()
    if not row:
        raise InvalidOwner(f"{label} is not a registered owner")
    if row[0] != proj:
        raise InvalidOwner(f"{label} is registered to {row[0]!r}, not {proj!r}")
    stored_token = row[2]
    if not stored_token or not hmac.compare_digest(stored_token, old_token or ""):
        raise Unauthorized(f"{label}: token mismatch")
    if row[1] is None:
        return "not_unregistered"
    if not isinstance(lifecycle_end_at, (int, float)) or isinstance(lifecycle_end_at, bool) or lifecycle_end_at <= now:
        raise ValueError("lifecycle_end_at must be a future epoch-seconds value")
    if not new_token:
        raise ValueError("new_token must be non-empty")
    if dry_run:
        return "would_reregister"

    def body():
        cur2 = conn.execute(
            "UPDATE owner_projects SET unregistered_at=NULL, unregister_token=?, lifecycle_end_at=? "
            "WHERE label=? AND unregistered_at IS NOT NULL AND unregister_token=?",
            (new_token, _iso(lifecycle_end_at), label, stored_token))
        if cur2.rowcount == 0:
            return "race_lost"
        _event(conn, now, label, "reregistered", proj)
        return "reregistered"

    return _tx(conn, body)


SESSION_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")


def _live(conn, label, now):
    """Current live lease (unreleased) for label. A `timed` row is live
    only while unexpired; a durable `assignment` row (Plan 018 §1.1 #1) is
    live regardless of `now` -- wall-clock time never ends it."""
    return conn.execute(
        "SELECT lease_id, pane_id, pane_birth, generation, renewed_at, expires_at, session_digest, authority_mode "
        "FROM owner_leases WHERE label=? AND released_at IS NULL AND (authority_mode='assignment' OR expires_at > ?)",
        (label, _iso(now))).fetchone()


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
    project = conn.execute("SELECT project FROM owner_projects WHERE label=?", (label,)).fetchone()[0]
    lease_id = f"ol_{uuid.uuid4().hex}"
    conn.execute("INSERT INTO owner_leases(lease_id,label,project,pane_id,pane_birth,generation,acquired_at,renewed_at,"
                 "expires_at,session_digest,authority_mode) VALUES (?,?,?,?,?,?,?,?,?,?,'timed')",
                 (lease_id, label, project, pane_id, pane_birth, gen, _iso(now), _iso(now), _iso(now + ttl_s), session_digest))
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
            lease_id, pane, birth, gen, _r, _e, sess, mode = cur
            if (pane, birth, sess) != (pane_id, pane_birth, session_digest):
                raise LeaseConflict(f"{label} held by {pane}@{birth} gen {gen}")
            if mode == "assignment":
                raise LeaseConflict(f"{label}: active authority is a durable assignment; "
                                    "acquire() is a timed-only renewal, never an implicit conversion")
            conn.execute("UPDATE owner_leases SET renewed_at=?, expires_at=? WHERE lease_id=?",
                         (_iso(now), _iso(now + ttl_s), lease_id))
            _event(conn, now, label, "renewed", lease_id, gen)
            return gen
        last = conn.execute("SELECT authority_mode, generation FROM owner_leases WHERE label=? "
                            "ORDER BY generation DESC LIMIT 1", (label,)).fetchone()
        if last and last[0] == "assignment":
            raise LeaseConflict(f"{label}: generation {last[1]} is a released durable assignment; acquire() is a "
                                "timed-only path, re-assignment goes through assign_replace()")
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
        project = conn.execute("SELECT project FROM owner_projects WHERE label=?", (label,)).fetchone()[0]
        lease_id = f"ol_{uuid.uuid4().hex}"
        conn.execute("INSERT INTO owner_leases(lease_id,label,project,pane_id,pane_birth,generation,acquired_at,renewed_at,"
                     "expires_at,session_digest,authority_mode) VALUES (?,?,?,?,?,1,?,?,?,?,'timed')",
                     (lease_id, label, project, pane_id, pane_birth, _iso(now), _iso(now), _iso(now + ttl_s), session_digest))
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
            "SELECT pane_id, pane_birth, session_digest, generation, authority_mode FROM owner_leases WHERE label=? "
            "ORDER BY generation DESC LIMIT 1", (label,)).fetchone()
        prev_pane, prev_birth, prev_sess, prev_gen, prev_mode = row if row else (None, None, None, 0, None)
        if prev_mode == "assignment":
            raise SuccessorRefused("predecessor_was_assignment",
                                   f"{label}: generation {prev_gen}'s predecessor is a durable assignment; "
                                   "claim_successor() is a timed-only legacy path, never a cross-mode takeover")
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


def live_expiry(conn, label, now=None) -> float | None:
    """Epoch-seconds expires_at of the label's live lease, or None when
    there is none. Read-only. R12/owner-dispatch-issue.py's bind-live-
    generation mode uses this to refuse issuing a grant whose own window
    would outlive the lease it is bound to (ANSWER-r12.md: "expiry <=
    lease expiry") -- the module's own ISO strings are always produced by
    _iso() (fixed %Y-%m-%dT%H:%M:%S.%fZ, UTC), so parsing with the exact
    inverse of that format is safe for every row this module itself wrote."""
    cur = _live(conn, label, time.time() if now is None else now)
    if not cur or cur[5] is None:
        return None
    return datetime.strptime(cur[5], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc).timestamp()


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
    """Unreleased TIMED leases whose holder is gone from the live pane set or expired,
    with the exact identity reap() must CAS on. Durable assignments are never observed
    here: no age/pane-gone reap of an assignment exists (Plan 018 §1.1 #3)."""
    now = time.time() if now is None else now
    out = []
    for lease_id, label, pane, birth, gen, renewed, expires in conn.execute(
            "SELECT lease_id,label,pane_id,pane_birth,generation,renewed_at,expires_at FROM owner_leases "
            "WHERE released_at IS NULL AND authority_mode='timed'"):
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


# --- Durable owner ASSIGNMENTS (Plan 018 PR A, inert) -----------------------
#
# An assignment is authoritative until an explicit revoke or exact-generation
# replacement; wall-clock time never ends it (authority_mode='assignment',
# expires_at NULL -- see MIGRATIONS[6] and _live()'s mode-aware query). The
# existing partial unique index (owner_leases(label) WHERE released_at IS
# NULL) is the SAME "one unreleased authority per label" enforcement both
# modes share; generation is label-local-monotonic the same way timed
# generations already are (MAX(generation)+1 over the label's WHOLE
# history). Nothing here is called by any delivery/dispatch path yet (PR B).


def _unreleased(conn, label):
    """The label's current unreleased authority row (any mode), or None.
    Unlike _live(), this is never filtered by now/expiry -- it is the exact
    "An active assignment is an unreleased assignment row" read (Plan 018
    §1.1 #1), and also the row a TIMED label currently holds whether or not
    it has expired (reap()/the TTL path decide what to do with THAT; this
    helper only answers "is there a row nobody has released yet")."""
    return conn.execute(
        "SELECT lease_id,label,project,pane_id,pane_birth,generation,acquired_at,renewed_at,expires_at,"
        "session_digest,authority_mode,decision_ref,reason FROM owner_leases WHERE label=? AND released_at IS NULL",
        (label,)).fetchone()


_ASSIGNMENT_KEYS = ("lease_id", "label", "project", "pane_id", "pane_birth", "generation", "acquired_at",
                   "renewed_at", "expires_at", "session_digest", "authority_mode", "decision_ref", "reason")


def current_assignment(conn, label, now=None) -> dict | None:
    """show/current (Plan 018 §4.4): the label's current unreleased
    authority row (any mode) as a dict, or None. Read-only, time-
    independent -- works on a mode=ro connection and never filters by
    expiry (a durable assignment has none; a timed lease that has expired
    but not yet been reaped/released is still THE row until something
    explicit releases it)."""
    row = _unreleased(conn, label)
    return dict(zip(_ASSIGNMENT_KEYS, row)) if row else None


def assign_initial(conn, label: str, pane_id: str, pane_birth: str, session_digest: str, decision_ref: str,
                   reason: str, now: float | None = None, dry_run: bool = True):
    """Initial durable assignment (Plan 018 §4.4 `assign`): generation
    MAX(all historical generations for label)+1, authority_mode='assignment',
    expires_at=NULL. Refuses (AssignmentConflict) while the label has ANY
    unreleased authority row, timed or assignment -- this is the bare
    "managed but unassigned" -> "assigned" transition (§4.2); replacing an
    ACTIVE row is assign_replace()'s job, never this one's (no implicit
    takeover of a live timed lease).

    Idempotent: re-presenting the EXACT same (pane_id, pane_birth,
    session_digest, decision_ref, reason) against the label's own just-
    created active assignment returns its generation again without a
    second write (Plan 018 §4.4: "Re-presenting the exact active assignment
    is idempotent"). Any other mismatch while active is AssignmentConflict,
    never a silent overwrite.

    Dry-run by default (this module's convention: a cheap pre-check runs
    OUTSIDE the transaction and can already refuse; only the write is
    skipped). Re-checks everything a second time inside _tx()'s BEGIN
    IMMEDIATE so a concurrent winner's write is never silently clobbered
    (same TOCTOU-safe shape as unregister_owner())."""
    now = time.time() if now is None else now
    _check_holder(pane_id, pane_birth)
    if not SESSION_DIGEST_RE.match(session_digest or ""):
        raise ValueError("session_digest must be 64 lowercase hex")
    if not decision_ref:
        raise ValueError("decision_ref must be non-empty")
    if not reason:
        raise ValueError("reason must be non-empty")

    def check():
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (label,)).fetchone():
            raise InvalidOwner(f"{label} is not a registered owner")
        active = _unreleased(conn, label)
        if active:
            same = (active[10], active[3], active[4], active[9], active[11], active[12]) == \
                   ("assignment", pane_id, pane_birth, session_digest, decision_ref, reason)
            if same:
                return active
            raise AssignmentConflict(f"{label}: an unreleased {active[10]} authority row already exists (gen {active[5]})")
        return None

    active = check()
    if active:
        return active[5]
    if dry_run:
        return "would_assign"

    def body():
        active2 = check()
        if active2:
            return active2[5]
        gen = conn.execute("SELECT COALESCE(MAX(generation),0)+1 FROM owner_leases WHERE label=?", (label,)).fetchone()[0]
        project = conn.execute("SELECT project FROM owner_projects WHERE label=?", (label,)).fetchone()[0]
        lease_id = f"ol_{uuid.uuid4().hex}"
        conn.execute(
            "INSERT INTO owner_leases(lease_id,label,project,pane_id,pane_birth,generation,acquired_at,renewed_at,"
            "expires_at,session_digest,authority_mode,decision_ref,reason) VALUES (?,?,?,?,?,?,?,?,NULL,?,'assignment',?,?)",
            (lease_id, label, project, pane_id, pane_birth, gen, _iso(now), _iso(now), session_digest, decision_ref, reason))
        _event(conn, now, label, "assigned", lease_id, gen, f"{pane_id}@{pane_birth} {decision_ref}: {reason}")
        return gen

    return _tx(conn, body)


def assign_replace(conn, label: str, expected_generation: int, expected_pane_id: str, expected_pane_birth: str,
                   expected_session_digest: str, pane_id: str, pane_birth: str, session_digest: str,
                   decision_ref: str, reason: str, now: float | None = None, dry_run: bool = True):
    """Exact replacement (Plan 018 §4.4 `replace`), covering BOTH named
    cases from the same transaction shape:
      * active replacement: expected_* names the CURRENT unreleased
        authority row exactly (any mode); the new holder must DIFFER from
        it (ReplaceRefused('same_holder') otherwise -- a same-holder
        "replace" is never implicit renewal of a durable assignment).
        The predecessor is released 'superseded_by_assignment'.
      * re-assignment after revoke: expected_* names the label's LATEST
        row exactly, which must already be released 'revoked'. The new
        holder MAY equal the revoked holder (Plan 018 §4.4), but only from
        that EXACT revoked generation and with a fresh decision_ref.
    Either way: any mismatch writes nothing (ReplaceRefused('stale_
    expectation')); zero open owner_requests required (ReplaceRefused
    ('open_requests') -- replacing a label with unresolved deliveries in
    flight is refused, never silently staled); new generation =
    MAX(all historical generations for label)+1.

    Idempotent re-presentation of the label's OWN just-created active
    assignment (same shape as assign_initial()) returns its generation
    without a second write."""
    now = time.time() if now is None else now
    _check_holder(pane_id, pane_birth)
    _check_holder(expected_pane_id, expected_pane_birth)
    for sd in (session_digest, expected_session_digest):
        if not SESSION_DIGEST_RE.match(sd or ""):
            raise ValueError("session_digest must be 64 lowercase hex")
    if not isinstance(expected_generation, int) or isinstance(expected_generation, bool) or expected_generation < 1:
        raise ValueError("expected_generation must be an int >= 1")
    if not decision_ref:
        raise ValueError("decision_ref must be non-empty")
    if not reason:
        raise ValueError("reason must be non-empty")

    def check():
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (label,)).fetchone():
            raise InvalidOwner(f"{label} is not a registered owner")
        active = _unreleased(conn, label)
        if active and (active[5], active[3], active[4], active[9]) == \
                (expected_generation, expected_pane_id, expected_pane_birth, expected_session_digest):
            if (active[10], pane_id, pane_birth, session_digest, decision_ref, reason) == \
                    ("assignment", expected_pane_id, expected_pane_birth, expected_session_digest,
                     active[11], active[12]):
                return "idempotent", active
            if (pane_id, pane_birth, session_digest) == (expected_pane_id, expected_pane_birth, expected_session_digest):
                raise ReplaceRefused("same_holder", f"{label}: new holder equals the active predecessor; "
                                     "replace requires a different live holder")
            n_open = conn.execute(f"SELECT COUNT(*) FROM owner_requests WHERE label=? AND state IN ({_q(OPEN)})",
                                  (label, *OPEN)).fetchone()[0]
            if n_open:
                raise ReplaceRefused("open_requests", f"{label}: {n_open} open owner_requests")
            return "active", active
        latest = conn.execute(
            "SELECT lease_id,label,project,pane_id,pane_birth,generation,acquired_at,renewed_at,expires_at,"
            "session_digest,authority_mode,decision_ref,reason,released_at,release_reason FROM owner_leases "
            "WHERE label=? ORDER BY generation DESC LIMIT 1", (label,)).fetchone()
        if latest and latest[5] == expected_generation and (latest[3], latest[4], latest[9]) == \
                (expected_pane_id, expected_pane_birth, expected_session_digest) and latest[14] == "revoked":
            n_open = conn.execute(f"SELECT COUNT(*) FROM owner_requests WHERE label=? AND state IN ({_q(OPEN)})",
                                  (label, *OPEN)).fetchone()[0]
            if n_open:
                raise ReplaceRefused("open_requests", f"{label}: {n_open} open owner_requests")
            return "after_revoke", latest
        raise ReplaceRefused("stale_expectation", f"{label}: expected gen {expected_generation} "
                             f"{expected_pane_id}@{expected_pane_birth} does not match current state")

    branch, row = check()
    if branch == "idempotent":
        return row[5]
    if dry_run:
        return "would_replace"

    def body():
        branch2, row2 = check()
        if branch2 == "idempotent":
            return row2[5]
        if branch2 == "active":
            conn.execute("UPDATE owner_leases SET released_at=?, release_reason='superseded_by_assignment' "
                        "WHERE lease_id=?", (_iso(now), row2[0]))
            _event(conn, now, label, "released", row2[0], row2[5], "superseded_by_assignment")
        gen = conn.execute("SELECT COALESCE(MAX(generation),0)+1 FROM owner_leases WHERE label=?", (label,)).fetchone()[0]
        project = conn.execute("SELECT project FROM owner_projects WHERE label=?", (label,)).fetchone()[0]
        new_id = f"ol_{uuid.uuid4().hex}"
        conn.execute(
            "INSERT INTO owner_leases(lease_id,label,project,pane_id,pane_birth,generation,acquired_at,renewed_at,"
            "expires_at,session_digest,authority_mode,decision_ref,reason) VALUES (?,?,?,?,?,?,?,?,NULL,?,'assignment',?,?)",
            (new_id, label, project, pane_id, pane_birth, gen, _iso(now), _iso(now), session_digest, decision_ref, reason))
        _event(conn, now, label, "assigned", new_id, gen, f"{pane_id}@{pane_birth} {decision_ref}: {reason} ({branch2})")
        return gen

    return _tx(conn, body)


def assign_revoke(conn, label: str, expected_generation: int, expected_pane_id: str, expected_pane_birth: str,
                  expected_session_digest: str, decision_ref: str, reason: str, now: float | None = None,
                  dry_run: bool = True):
    """Revoke (Plan 018 §4.4): fences on the EXACT active assignment tuple,
    then immediately releases it (release_reason='revoked') -- this alone
    blocks new admission: _live()/_fence() (so enqueue()/transition()/
    release()) only ever see an UNRELEASED row, and after this commits
    there is none, so every normal fenced call refuses FencedOut exactly
    as it would for any other released label. Queued/held/blocked
    owner_requests for the revoked generation become 'cancelled' in the
    SAME transaction; a 'delivering' request is deliberately left alone --
    it may not start a second send, but its terminal outcome against this
    EXACT released generation is assign_settle()'s job, not this one's
    (Plan 018 §4.4: "an already-delivering request may record its
    terminal outcome ... but may not start a second send").

    Refuses (RevokeRefused('not_assignment_mode')) against a TIMED active
    lease -- revoke is a durable-assignment-only operation; the timed
    label's own release()/unregister_owner() are unchanged by this PR."""
    now = time.time() if now is None else now
    _check_holder(expected_pane_id, expected_pane_birth)
    if not SESSION_DIGEST_RE.match(expected_session_digest or ""):
        raise ValueError("expected_session_digest must be 64 lowercase hex")
    if not isinstance(expected_generation, int) or isinstance(expected_generation, bool) or expected_generation < 1:
        raise ValueError("expected_generation must be an int >= 1")
    if not decision_ref:
        raise ValueError("decision_ref must be non-empty")
    if not reason:
        raise ValueError("reason must be non-empty")

    def check():
        if not conn.execute("SELECT 1 FROM owner_projects WHERE label=?", (label,)).fetchone():
            raise InvalidOwner(f"{label} is not a registered owner")
        active = _unreleased(conn, label)
        if not active:
            raise RevokeRefused("stale_expectation", f"{label}: no unreleased authority row")
        if active[10] != "assignment":
            raise RevokeRefused("not_assignment_mode", f"{label}: active authority is {active[10]}, not a durable assignment")
        if (active[5], active[3], active[4], active[9]) != (expected_generation, expected_pane_id, expected_pane_birth, expected_session_digest):
            raise RevokeRefused("stale_expectation", f"{label}: expected gen {expected_generation} "
                                f"{expected_pane_id}@{expected_pane_birth} does not match live gen {active[5]} "
                                f"{active[3]}@{active[4]}")
        return active

    check()
    if dry_run:
        return "would_revoke"

    def body():
        active = check()
        lease_id, gen = active[0], active[5]
        conn.execute("UPDATE owner_leases SET released_at=?, release_reason='revoked' WHERE lease_id=?", (_iso(now), lease_id))
        _event(conn, now, label, "revoked", lease_id, gen, f"{decision_ref}: {reason}")
        cancelled = [r[0] for r in conn.execute(
            "SELECT request_id FROM owner_requests WHERE label=? AND generation=? AND state IN ('queued','held','blocked')",
            (label, gen)).fetchall()]
        for rid in cancelled:
            conn.execute("UPDATE owner_requests SET state='cancelled', updated_at=? WHERE request_id=?", (_iso(now), rid))
            _event(conn, now, label, "request:cancelled", rid, gen, "revoked")
        return {"generation": gen, "cancelled": cancelled}

    return _tx(conn, body)


def assign_settle(conn, label: str, request_id: str, expected_generation: int, to: str, detail: str = "",
                  now: float | None = None, dry_run: bool = True):
    """Terminal settlement of an already-'delivering' request after its
    generation's authority has been released (Plan 018 §4.4's revoke note):
    the request must currently be 'delivering', belong to EXACTLY (label,
    expected_generation), and that generation's owner_leases row must
    already be released (any reason -- revoked, superseded, or expired) --
    SettleRefused('generation_still_active') otherwise, directing the
    caller to the normal fenced transition() instead (this function never
    authenticates a live holder; it exists ONLY for the generation that no
    longer has one). `to` is restricted to the two real terminal outcomes
    (replied, timeout) -- it can never re-admit to 'delivering' or any
    other state, so this can never start a second send."""
    now = time.time() if now is None else now
    _check(REQUEST_RE, request_id, "request id")
    if to not in ("replied", "timeout"):
        raise InvalidTransition(f"settlement target must be 'replied' or 'timeout', got {to!r}")
    if not isinstance(expected_generation, int) or isinstance(expected_generation, bool) or expected_generation < 1:
        raise ValueError("expected_generation must be an int >= 1")

    def check():
        row = conn.execute("SELECT label, generation, state FROM owner_requests WHERE request_id=?", (request_id,)).fetchone()
        if not row:
            raise SettleRefused("unknown_request", f"unknown request {request_id}")
        if row[:2] != (label, expected_generation):
            raise SettleRefused("wrong_generation", f"{request_id} belongs to {row[0]} gen {row[1]}, "
                                f"expected {label} gen {expected_generation}")
        if row[2] != "delivering":
            raise SettleRefused("not_delivering", f"{request_id} is {row[2]!r}, not delivering")
        lease_row = conn.execute("SELECT released_at FROM owner_leases WHERE label=? AND generation=?",
                                 (label, expected_generation)).fetchone()
        if not lease_row or lease_row[0] is None:
            raise SettleRefused("generation_still_active", f"{label} generation {expected_generation} is not "
                                "released; use transition(), not settlement")
        return row

    check()
    if dry_run:
        return "would_settle"

    def body():
        check()
        conn.execute("UPDATE owner_requests SET state=?, updated_at=?, detail=? WHERE request_id=? AND state='delivering'",
                    (to, _iso(now), detail, request_id))
        _event(conn, now, label, f"request:{to}", request_id, expected_generation, f"settled-after-revoke: {detail}")
        return to

    return _tx(conn, body)
