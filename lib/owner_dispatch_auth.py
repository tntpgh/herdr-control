"""Owner-dispatch authorization contract (INERT: no issuer, no live store).

Why a new contract: the existing approval records do not authorize "send
request R to owner L".
  - `approvals` (lib/run-registry.sh) records pane approval-prompt decisions
    (prompt_id, choice, policy_verdict, free-form command): no owner, request
    or body digest.
  - `action_requests` (lib/action-request.sh, task-authorization.py
    action_consume) is a one-shot grant bound to a worker TASK's tool call
    (run_id, task_id, tool, action_sha256), so it cannot name an owner
    request.
A free-form command string is never hashed or re-parsed into authority.

Contract `owner-dispatch-auth/2`: one row is one grant, bound to protocol,
owner label AND canonical project, the exact owner holder (pane_id,
pane_birth, full session digest, lease generation), request id, exact body
sha256, sorted manifest, the prompt/approval identity that decided it, a
one-time auth id and an explicit expiry. A grant therefore cannot follow a
replacement owner or a later lease generation, and an unused grant dies at
expires_at. consume() is one BEGIN IMMEDIATE check-and-set: exactly one caller
turns `granted` into `consumed`. Everything else is a typed hold:
  missing | denied | consumed | expired | mismatch | ambiguous (store error).

Consumed-but-unsent: consumption happens before admission and before any
journal write, so a crash or a queue refusal after it burns the grant with no
journal entry. consume() returns the complete consumed ENVELOPE (auth_id,
binding, consumed_at); the Dispatcher writes it into the immutable
intent.json. unsent() accepts a consumed grant as accounted for ONLY when
<journal>/<label>/<rid>/intent.json, read through no-follow descriptors as a
bounded regular file, parses and carries exactly that envelope. A missing,
older, symlinked, malformed or different intent leaves it unsent. Callers
hold on any such entry: never retried, never regranted.

Operator records (append-only table owner_dispatch_operator, UPDATE/DELETE
refused by triggers), keyed by auth_id + envelope_sha256 of the grant row:
  revoke():  granted & unexpired -> denied, BEFORE consumption only. A
             consumed grant cannot be revoked: cancellation never undoes a
             started action.
  resolve(): one operator outcome for a CONSUMED grant, only when the
             caller names the exact current envelope sha256. It never
             changes the grant, never regrants and never resends.
  unresolved(): unsent() minus grants with an exact-key resolution; the
             dispatch CLI holds on this. unsent() itself is unchanged, so the
             original evidence stays listed.

This module has NO function that writes a grant. A worker or caller cannot
authorize itself. Issuing a grant is a separate, unapproved surface; tests
insert fixture rows directly into a disposable store.

Standing grants (M9, default OFF): one row with kind='standing' binds a
LANE (owner_label, project), a holder FLOOR (pane_id, pane_birth,
session_digest, lease_generation), an item cap, an optional spend cap and
the sha256 of the approved queue.json -- never a single request. Each
dispatched item instead gets its own single-use CHILD row, inserted
pre-consumed (status='consumed', parent=<standing auth_id>) by
consume_standing(), which never touches consume()'s one-time-grant path.
UNIQUE(parent, request_id) makes a child impossible to insert twice for the
same item, so the UPDATE-style double-spend guard above is unnecessary
there; consume_standing uses an explicit pre-check instead for a clearer
hold reason. The parent's own status stays 'granted' for its whole life
(existing revoke() denies it exactly like any other row) -- it is never
itself marked 'consumed'. A generation above the floor is accepted only
under the §8a restart rule: same holder, the floor generation released
reason='expired' with zero open requests, and the live generation is
EXACTLY floor+1 -- verified against the lease DB, not assumed from holder
tuple equality alone.

migrate() is VERSIONED (owner_dispatch_auth_schema_version, mirroring
lib/owner_lease.py's MIGRATIONS): v1 is the schema exactly as first shipped
(0ac8ba1f); v2 (M9) ADD COLUMNs the seven standing-grant fields and adds
ONE new index, onto whatever a v1 store already holds. ALTER TABLE ADD
COLUMN never touches an existing row's data and the new UNIQUE(parent,
request_id) index is safe against any pre-existing data (every row older
than M9 has parent=NULL, and SQLite never treats NULLs as a collision) --
an EXISTING store upgrades with every row preserved, never deleted or
rewritten. A fresh store reaches the identical end schema by applying both
versions in order.

Weekly project envelopes (default OFF): owner-dispatch-approval-weekly/1, a
SEPARATE table (owner_dispatch_envelope, migration v3) because the kind CHECK
on owner_dispatch_auth cannot be widened by ALTER. An envelope binds a
POLICY (job templates, per-day / per-envelope item caps, per-item and total
spend caps, expiry), never a queue sha. consume_envelope() validates ONE item
against that policy and mints the same pre-consumed single-use CHILD row
(parent=<envelope auth_id>) consume_standing() mints, so journals, intents,
unsent()/unresolved() and receipts are unchanged. Every cap is DERIVED from
the child rows themselves (count / sum), never from a mutable counter, so a
counter can not drift from the audit trail. The envelope row is immutable
except granted -> denied (trigger); revoke_envelope() does exactly that and
records an operator row. standing/1 is not touched.

"""
from __future__ import annotations

from collections.abc import Callable
import hashlib
import json
import os
import re
import sqlite3
import stat
import time
import uuid

import private_sqlite

PROTOCOL = "owner-dispatch-auth/2"
ENVELOPE_PROTOCOL = "owner-dispatch-approval-weekly/1"
MAX_ENVELOPE_WINDOW_S = 7 * 86400
MAX_REQUEST_BYTES = 64 * 1024

SCHEMA = """CREATE TABLE IF NOT EXISTS owner_dispatch_auth (
  auth_id      TEXT PRIMARY KEY,
  protocol     TEXT NOT NULL,
  owner_label  TEXT NOT NULL,
  project      TEXT NOT NULL,
  pane_id      TEXT NOT NULL,
  pane_birth   TEXT NOT NULL,
  session_digest TEXT NOT NULL,
  lease_generation INTEGER NOT NULL,
  request_id   TEXT NOT NULL,
  body_sha256  TEXT NOT NULL,
  manifest     TEXT NOT NULL,
  prompt_id    TEXT NOT NULL,
  approval_id  TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('granted','denied','consumed')),
  decided_at   TEXT NOT NULL,
  expires_at   REAL NOT NULL,
  consumed_at  TEXT
)"""


OPERATOR_SCHEMA = (
    """CREATE TABLE IF NOT EXISTS owner_dispatch_operator (
  seq             INTEGER PRIMARY KEY AUTOINCREMENT,
  auth_id         TEXT NOT NULL,
  kind            TEXT NOT NULL CHECK (kind IN ('revoked','resolved')),
  envelope_sha256 TEXT NOT NULL,
  operator        TEXT NOT NULL CHECK (operator <> ''),
  decision_ref    TEXT NOT NULL CHECK (decision_ref <> ''),
  outcome         TEXT NOT NULL,
  note            TEXT NOT NULL,
  new_request_id  TEXT,
  recorded_at     TEXT NOT NULL,
  UNIQUE (auth_id, kind)
)""",
    "CREATE TRIGGER IF NOT EXISTS owner_dispatch_operator_no_update BEFORE UPDATE ON owner_dispatch_operator"
    " BEGIN SELECT RAISE(ABORT, 'append-only'); END",
    "CREATE TRIGGER IF NOT EXISTS owner_dispatch_operator_no_delete BEFORE DELETE ON owner_dispatch_operator"
    " BEGIN SELECT RAISE(ABORT, 'append-only'); END",
)
ISSUANCE_SCHEMA = (
    """CREATE TABLE IF NOT EXISTS owner_dispatch_issuance (
  auth_id            TEXT PRIMARY KEY,
  approval_sha256    TEXT NOT NULL CHECK (length(approval_sha256) = 64),
  approval_bytes     BLOB NOT NULL,
  form_id            TEXT NOT NULL UNIQUE,
  form_record_sha256 TEXT NOT NULL,
  form_html_sha256   TEXT NOT NULL,
  answered_at        REAL NOT NULL,
  issued_at          TEXT NOT NULL
)""",
    "CREATE TRIGGER IF NOT EXISTS owner_dispatch_issuance_no_update BEFORE UPDATE ON owner_dispatch_issuance"
    " BEGIN SELECT RAISE(ABORT, 'append-only'); END",
    "CREATE TRIGGER IF NOT EXISTS owner_dispatch_issuance_no_delete BEFORE DELETE ON owner_dispatch_issuance"
    " BEGIN SELECT RAISE(ABORT, 'append-only'); END",
)
OUTCOMES = ("confirmed_delivered", "confirmed_not_delivered", "abandoned_uncertain")


POLICY_ROW_COLS = ("auth_id", "protocol", "owner_label", "project", "pane_id", "pane_birth", "session_digest",
                 "lease_generation", "policy", "policy_sha256", "prompt_id", "approval_id", "decided_at", "expires_at")
ENVELOPE_SCHEMA = (
    """CREATE TABLE IF NOT EXISTS owner_dispatch_envelope (
  auth_id          TEXT PRIMARY KEY,
  protocol         TEXT NOT NULL,
  owner_label      TEXT NOT NULL,
  project          TEXT NOT NULL,
  pane_id          TEXT NOT NULL,
  pane_birth       TEXT NOT NULL,
  session_digest   TEXT NOT NULL,
  lease_generation INTEGER NOT NULL,
  policy           TEXT NOT NULL,
  policy_sha256    TEXT NOT NULL CHECK (length(policy_sha256) = 64),
  prompt_id        TEXT NOT NULL,
  approval_id      TEXT NOT NULL UNIQUE,
  decided_at       TEXT NOT NULL,
  expires_at       REAL NOT NULL,
  status           TEXT NOT NULL CHECK (status IN ('granted','denied'))
)""",
    "CREATE TRIGGER IF NOT EXISTS owner_dispatch_envelope_no_delete BEFORE DELETE ON owner_dispatch_envelope"
    " BEGIN SELECT RAISE(ABORT, 'append-only'); END",
    # The ONLY legal update is granted -> denied with every other column unchanged.
    "CREATE TRIGGER IF NOT EXISTS owner_dispatch_envelope_revoke_only BEFORE UPDATE ON owner_dispatch_envelope"
    " WHEN OLD.status <> 'granted' OR NEW.status <> 'denied' OR "
    + " OR ".join(f"NEW.{c} IS NOT OLD.{c}" for c in POLICY_ROW_COLS)
    + " BEGIN SELECT RAISE(ABORT, 'immutable'); END",
)


MIGRATIONS = {
    # v1 is the ORIGINAL schema exactly as first shipped (0ac8ba1f, M2).
    # Never edit this entry: a store at v1 exists with exactly these
    # columns/tables. CREATE TABLE/TRIGGER IF NOT EXISTS is idempotent, so
    # re-applying v1 to a store a pre-versioned migrate() already built is
    # always a safe no-op.
    1: (SCHEMA,) + OPERATOR_SCHEMA + ISSUANCE_SCHEMA,
    # v2 (M9, default OFF): standing-grant columns, additive only.
    2: (
        "ALTER TABLE owner_dispatch_auth ADD COLUMN kind TEXT NOT NULL DEFAULT 'single'"
        " CHECK (kind IN ('single','standing'))",
        "ALTER TABLE owner_dispatch_auth ADD COLUMN parent TEXT REFERENCES owner_dispatch_auth(auth_id)",
        "ALTER TABLE owner_dispatch_auth ADD COLUMN queue_sha256 TEXT",
        "ALTER TABLE owner_dispatch_auth ADD COLUMN item_cap INTEGER",
        "ALTER TABLE owner_dispatch_auth ADD COLUMN spend_cap_cents INTEGER",
        "ALTER TABLE owner_dispatch_auth ADD COLUMN used_count INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE owner_dispatch_auth ADD COLUMN spent_cents INTEGER NOT NULL DEFAULT 0",
        "CREATE UNIQUE INDEX owner_dispatch_auth_parent_request ON owner_dispatch_auth(parent, request_id)",
    ),
    # v3 (weekly envelopes, default OFF): ONE new table + triggers, additive only.
    3: ENVELOPE_SCHEMA,
}

LATEST = max(MIGRATIONS)


def migrate(conn: sqlite3.Connection) -> int:
    """Applies pending versioned migrations, in order, inside ONE transaction,
    preserving every existing row: v1 (CREATE TABLE/TRIGGER IF NOT EXISTS,
    a no-op on an already-v1 store) then v2 (M9, ALTER TABLE ADD COLUMN plus
    one new index -- no DELETE, no table rebuild, no row touched). Safe to
    call against a BRAND NEW store, an existing v1 (pre-M9) store with real
    rows, or an already-v2 store (re-applying is a no-op via the version
    check). Returns the resulting schema version."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS owner_dispatch_auth_schema_version"
                     " (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
        cur = conn.execute("SELECT COALESCE(MAX(version),0) FROM owner_dispatch_auth_schema_version").fetchone()[0]
        for v in sorted(MIGRATIONS):
            if v > cur:
                for stmt in MIGRATIONS[v]:
                    conn.execute(stmt)
                conn.execute("INSERT INTO owner_dispatch_auth_schema_version VALUES (?,?)", (v, _now_iso()))
                cur = v
        conn.execute("COMMIT")
        return cur
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def manifest_key(manifest) -> str:
    return json.dumps(sorted(manifest), separators=(",", ":"))


ENVELOPE_COLS = ("auth_id", "protocol", "owner_label", "project", "pane_id", "pane_birth", "session_digest",
                 "lease_generation", "request_id", "body_sha256", "manifest", "prompt_id", "approval_id", "consumed_at")


def _envelope(conn, auth_id) -> dict:
    row = conn.execute(f"SELECT {','.join(ENVELOPE_COLS)} FROM owner_dispatch_auth WHERE auth_id=?", (auth_id,)).fetchone()
    return dict(zip(ENVELOPE_COLS, row)) if row else {}


def consume(conn: sqlite3.Connection, auth_id: str, *, label: str, project: str, holder, request_id: str,
            body_sha256: str, manifest, now: float):
    """The consumed envelope (dict) when THIS call consumed the grant, else a
    hold reason (str). Never raises.
    holder = the resolved (pane_id, pane_birth, session_digest, generation)."""
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            row = conn.execute("SELECT protocol, owner_label, project, pane_id, pane_birth, session_digest,"
                               " lease_generation, request_id, body_sha256, manifest, prompt_id, approval_id,"
                               " status, expires_at FROM owner_dispatch_auth WHERE auth_id=?",
                               (auth_id,)).fetchone()
            if row is None:
                return "auth_missing"
            *bound, prompt, approval, st, exp = row
            want = (PROTOCOL, label, project, *tuple(holder), request_id, body_sha256, manifest_key(manifest))
            if tuple(bound) != want or not prompt or not approval or not project:
                return "auth_mismatch"
            if st == "denied":
                return "auth_denied"
            if st == "consumed":
                return "auth_consumed"
            if not isinstance(exp, (int, float)) or now >= exp:
                return "auth_expired"
            changed = conn.execute("UPDATE owner_dispatch_auth SET status='consumed', consumed_at=?"
                                   " WHERE auth_id=? AND status='granted'",
                                   (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), auth_id)).rowcount
            if changed != 1:
                return "auth_consumed"
            env = _envelope(conn, auth_id)
            conn.execute("COMMIT")
            return env
        finally:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
    except (sqlite3.Error, TypeError, ValueError) as exc:
        return f"auth_ambiguous:{type(exc).__name__}"


def _holder_fence_ok(lease_conn, label, live, floor) -> bool:
    """live = the CURRENT (pane, birth, session, generation); floor = the
    grant's (pane, birth, session, floor generation). True when the holder is
    the floor's, or is EXACTLY floor+1 under the §8a restart rule (same holder,
    the floor generation released reason='expired' with zero open requests,
    verified against lease_conn). Shared by consume_standing and
    consume_envelope so the two can never drift."""
    (pane, birth, sess, gen), (g_pane, g_birth, g_sess, floor_gen) = live, floor
    if (pane, birth, sess) != (g_pane, g_birth, g_sess) or gen < floor_gen:
        return False
    if gen == floor_gen:
        return True
    if gen != floor_gen + 1 or lease_conn is None:
        return False
    prev = lease_conn.execute(
        "SELECT pane_id, pane_birth, session_digest, release_reason FROM owner_leases"
        " WHERE label=? AND generation=?", (label, floor_gen)).fetchone()
    if prev is None or prev[3] != "expired" or (prev[0], prev[1], prev[2]) != (pane, birth, sess):
        return False
    n_open = lease_conn.execute(
        "SELECT COUNT(*) FROM owner_requests WHERE label=? AND generation=? AND state IN"
        " ('queued','held','blocked','delivering')", (label, floor_gen)).fetchone()[0]
    return not n_open


def consume_standing(conn: sqlite3.Connection, auth_id: str, *, label: str, project: str, holder, request_id: str,
                     body_sha256: str, manifest, now: float, queue_sha256: str,
                     lease_conn: sqlite3.Connection | None = None, cost_cents: int | None = None):
    """The consumed CHILD envelope (dict, same shape consume() returns) when
    this call inserted a new single-use child row under the standing grant
    `auth_id`; else a hold reason (str). Never raises. Inserts exactly one
    child row and bumps the parent's counters, or writes nothing.

    holder = the CURRENT live (pane_id, pane_birth, session_digest,
    generation), exactly as consume() expects. A generation above the
    grant's floor is accepted ONLY under the §8a restart rule, which needs
    `lease_conn` (the owner-lease store) to verify: the floor generation's
    own lease row was released reason='expired', had zero OPEN
    owner_requests, and the live generation is EXACTLY floor+1 with the
    identical (pane_id, pane_birth, session_digest) the grant names. Without
    `lease_conn`, or outside that exact window, any generation other than
    the floor is standing_holder_changed -- the fence is never relaxed on
    trust alone.

    queue_sha256 is the CALLER's fresh digest of the exact queue.json bytes
    at THIS moment (never a digest reused from an earlier read in the same
    tick): a mismatch refuses queue_sha_mismatch even when this item's own
    body_sha256 still looks fine -- the grant is bound to the whole signed
    queue, not to one item in isolation.

    cost_cents is the CALLER's validated per-item cost, or None when none
    was ever validated (never coerced to a free 0 by THIS function). It is
    only load-bearing when the grant has a real spend_cap_cents: an absent
    or malformed cost_cents against an active cap is standing_cost_missing,
    never silently treated as free -- a fabricated zero would let an
    unpriced item through a real cap for nothing. Without a cap, cost_cents
    is recorded for audit only (0 when not a validated non-negative int)."""
    pane, birth, sess, gen = holder
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            row = conn.execute(
                "SELECT protocol, owner_label, project, pane_id, pane_birth, session_digest, lease_generation,"
                " prompt_id, approval_id, status, expires_at, queue_sha256, item_cap, spend_cap_cents,"
                " used_count, spent_cents FROM owner_dispatch_auth WHERE auth_id=? AND kind='standing'",
                (auth_id,)).fetchone()
            if row is None:
                return "standing_missing"
            (proto, lb, pj, g_pane, g_birth, g_sess, floor_gen, prompt, approval, st, exp,
             g_qsha, item_cap, spend_cap, used, spent) = row
            if proto != PROTOCOL or lb != label or pj != project or not project:
                return "standing_mismatch"
            if st == "denied":
                return "standing_denied"
            if st != "granted":
                return "standing_mismatch"
            if not isinstance(exp, (int, float)) or now >= exp:
                return "standing_expired"
            if not _holder_fence_ok(lease_conn, label, (pane, birth, sess, gen), (g_pane, g_birth, g_sess, floor_gen)):
                return "standing_holder_changed"
            if g_qsha != queue_sha256:
                return "queue_sha_mismatch"
            if item_cap is not None and used >= item_cap:
                return "standing_cap"
            cost_valid = isinstance(cost_cents, int) and not isinstance(cost_cents, bool) and cost_cents >= 0
            if spend_cap is not None:
                if not cost_valid:
                    return "standing_cost_missing"
                if spent + cost_cents > spend_cap:
                    return "budget"
            spend_delta = cost_cents if cost_valid else 0
            if conn.execute("SELECT 1 FROM owner_dispatch_auth WHERE parent=? AND request_id=?",
                            (auth_id, request_id)).fetchone():
                return "standing_consumed"
            child_id = f"{auth_id}:{uuid.uuid4().hex}"
            decided = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
            conn.execute(
                "INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,"
                "session_digest,lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,"
                "decided_at,expires_at,consumed_at,kind,parent)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'consumed',?,?,?,'single',?)",
                (child_id, PROTOCOL, label, project, pane, birth, sess, gen, request_id, body_sha256,
                 manifest_key(manifest), prompt, approval, decided, exp, decided, auth_id))
            conn.execute("UPDATE owner_dispatch_auth SET used_count=used_count+1, spent_cents=spent_cents+?"
                        " WHERE auth_id=?", (spend_delta, auth_id))
            env = _envelope(conn, child_id)
            conn.execute("COMMIT")
            return env
        finally:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
    except (sqlite3.Error, TypeError, ValueError) as exc:
        return f"standing_ambiguous:{type(exc).__name__}"


_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]{0,63}$")
MIN_PREFIX_CHARS = 8  # a one-character prefix is a catch-all template, not a job template


def _is_int(v, lo, hi) -> bool:
    return type(v) is int and lo <= v <= hi


def validate_policy(p) -> dict:
    """The weekly envelope policy schema, strict, never coerced. Raises
    ValueError. Shared by the issuer (what a human is shown and signs) and
    consume_envelope (what is re-validated at every dispatch)."""
    if not isinstance(p, dict) or set(p) != {"templates", "max_per_day", "max_per_week", "per_item_cap_cents",
                                              "total_cap_cents"}:
        raise ValueError("policy_keys")
    if not (_is_int(p["max_per_day"], 1, 1000) and _is_int(p["max_per_week"], 1, 1000)
            and _is_int(p["per_item_cap_cents"], 0, 10**9) and _is_int(p["total_cap_cents"], 0, 10**9)):
        raise ValueError("policy_caps")
    t = p["templates"]
    if not isinstance(t, list) or not 1 <= len(t) <= 20:
        raise ValueError("policy_templates")
    seen = set()
    for x in t:
        if not isinstance(x, dict) or set(x) != {"name", "request_prefix", "manifest_allow", "max_request_bytes"}:
            raise ValueError("policy_template_keys")
        if not isinstance(x["name"], str) or not _NAME.match(x["name"]) or x["name"] in seen:
            raise ValueError("policy_template_name")
        seen.add(x["name"])
        pre = x["request_prefix"]
        if not isinstance(pre, str) or not MIN_PREFIX_CHARS <= len(pre) <= 512:
            raise ValueError("policy_template_prefix")
        ma = x["manifest_allow"]
        if (not isinstance(ma, list) or not 1 <= len(ma) <= 8 or len(set(ma)) != len(ma)
                or not all(isinstance(m, str) and _NAME.match(m) for m in ma)):
            raise ValueError("policy_template_manifest")
        if not _is_int(x["max_request_bytes"], 1, MAX_REQUEST_BYTES):
            raise ValueError("policy_template_size")
    return p


def canonical_policy(p: dict) -> str:
    return json.dumps(p, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def check_item_policy(policy: dict, request_text: bytes, manifest, cost_cents) -> str | None:
    """None when the item satisfies one template AND the per-item cap, else the
    typed policy_* refusal. An unpriced item is never treated as free."""
    try:
        text = request_text.decode("utf-8")
    except UnicodeDecodeError:
        return "policy_template"
    hits = [t for t in policy["templates"] if text.startswith(t["request_prefix"])]
    if not hits:
        return "policy_template"
    if not (isinstance(cost_cents, int) and not isinstance(cost_cents, bool) and cost_cents >= 0):
        return "policy_cost_missing"
    if cost_cents > policy["per_item_cap_cents"]:
        return "policy_item_cap"
    why = "policy_template"
    for t in hits:
        if len(request_text) > t["max_request_bytes"]:
            why = "policy_size"
        elif not set(manifest) <= set(t["manifest_allow"]):
            why = "policy_manifest"
        else:
            return None
    return why


def _utc(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def consume_envelope(conn: sqlite3.Connection, auth_id: str, *, label: str, project: str, holder, request_id: str,
                     request_text: bytes, manifest, now: float, lease_conn: sqlite3.Connection | None,
                     cost_cents: int | None, revoked: Callable[[str], bool]):
    """The consumed CHILD envelope (dict, same shape consume() returns) when
    this call minted a single-use child under the weekly envelope `auth_id`;
    else a hold reason (str). Never raises. One BEGIN IMMEDIATE: validate,
    count, insert -- two concurrent callers cannot both take the last slot.

    The ITEM is validated here, at dispatch, against the signed policy
    (never against a queue sha): template prefix + rules, per-item cost cap.
    Then the caps, all derived from the existing child rows: per rolling 24h,
    per envelope lifetime (<= 7 days, so `max_per_week`), total spend.
    revoked(auth_id) is the out-of-band kill file; it is REQUIRED (no
    default) so a caller cannot forget it, and is read inside the transaction.

    Hold reasons: envelope_missing | envelope_mismatch | envelope_revoked |
    envelope_expired | envelope_policy_invalid | envelope_holder_changed |
    policy_template | policy_cost_missing | policy_item_cap | policy_size |
    policy_manifest | envelope_consumed | envelope_day_cap | envelope_week_cap
    | envelope_budget | envelope_ambiguous:<Error>. Nothing is written on any."""
    pane, birth, sess, gen = holder
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            row = conn.execute(
                "SELECT protocol, owner_label, project, pane_id, pane_birth, session_digest, lease_generation,"
                " policy, policy_sha256, prompt_id, approval_id, status, expires_at"
                " FROM owner_dispatch_envelope WHERE auth_id=?", (auth_id,)).fetchone()
            if row is None:
                return "envelope_missing"
            (proto, lb, pj, g_pane, g_birth, g_sess, floor_gen, pol_text, pol_sha, prompt, approval, st, exp) = row
            if proto != ENVELOPE_PROTOCOL or lb != label or pj != project or not project:
                return "envelope_mismatch"
            if st == "denied" or revoked(auth_id):
                return "envelope_revoked"
            if st != "granted":
                return "envelope_mismatch"
            if not isinstance(exp, (int, float)) or now >= exp:
                return "envelope_expired"
            try:
                if hashlib.sha256(pol_text.encode()).hexdigest() != pol_sha:
                    return "envelope_policy_invalid"
                policy = validate_policy(json.loads(pol_text))
            except ValueError:
                return "envelope_policy_invalid"
            if not _holder_fence_ok(lease_conn, label, (pane, birth, sess, gen), (g_pane, g_birth, g_sess, floor_gen)):
                return "envelope_holder_changed"
            why = check_item_policy(policy, request_text, manifest, cost_cents)
            if why:
                return why
            if conn.execute("SELECT 1 FROM owner_dispatch_auth WHERE parent=? AND request_id=?",
                            (auth_id, request_id)).fetchone():
                return "envelope_consumed"
            n_day = conn.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE parent=? AND decided_at > ?",
                                 (auth_id, _utc(now - 86400))).fetchone()[0]
            n_all, spent = conn.execute("SELECT COUNT(*), COALESCE(SUM(spent_cents),0) FROM owner_dispatch_auth"
                                        " WHERE parent=?", (auth_id,)).fetchone()
            if n_day >= policy["max_per_day"]:
                return "envelope_day_cap"
            if n_all >= policy["max_per_week"]:
                return "envelope_week_cap"
            if spent + cost_cents > policy["total_cap_cents"]:
                return "envelope_budget"
            child_id = f"{auth_id}:{uuid.uuid4().hex}"
            decided = _utc(now)
            conn.execute(
                "INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,"
                "session_digest,lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,"
                "decided_at,expires_at,consumed_at,kind,parent,spent_cents)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'consumed',?,?,?,'single',?,?)",
                (child_id, PROTOCOL, label, project, pane, birth, sess, gen, request_id,
                 hashlib.sha256(request_text).hexdigest(), manifest_key(manifest), prompt, approval, decided, exp,
                 decided, auth_id, cost_cents))
            env = _envelope(conn, child_id)
            conn.execute("COMMIT")
            return env
        finally:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
    except (sqlite3.Error, TypeError, ValueError) as exc:
        return f"envelope_ambiguous:{type(exc).__name__}"


def revoke_envelope(conn: sqlite3.Connection, auth_id: str, *, operator: str, decision_ref: str, note: str = "") -> str:
    """'revoked', or why not: revoke_invalid | revoke_missing | revoke_denied |
    revoke_ambiguous:<Error>. Flips granted -> denied (the one update the
    table's trigger allows) and appends an operator row keyed by the sha256 of
    the envelope row, in ONE transaction: no revocation without its audit
    record. Works on an expired envelope too (a revocation is never refused
    for being late). Never raises."""
    if not operator or not decision_ref:
        return "revoke_invalid"
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            row = conn.execute(f"SELECT {','.join(POLICY_ROW_COLS)}, status FROM owner_dispatch_envelope WHERE auth_id=?",
                               (auth_id,)).fetchone()
            if row is None:
                return "revoke_missing"
            if row[-1] == "denied":
                return "revoke_denied"
            env_sha = envelope_sha256(dict(zip(POLICY_ROW_COLS, row[:-1])))
            if conn.execute("UPDATE owner_dispatch_envelope SET status='denied' WHERE auth_id=? AND status='granted'",
                            (auth_id,)).rowcount != 1:
                return "revoke_denied"
            _record(conn, auth_id, "revoked", env_sha, operator, decision_ref, "revoked", note, None)
            conn.execute("COMMIT")
            return "revoked"
        finally:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
    except sqlite3.Error as exc:
        return f"revoke_ambiguous:{type(exc).__name__}"


def envelope_usage(conn: sqlite3.Connection, auth_id: str, now: float) -> dict | None:
    """Read-only status of one envelope for factory-status: policy, status,
    expiry and what the caps have left. None when there is no such envelope.
    Raises sqlite3.Error on an unreadable/unmigrated store (caller reports it)."""
    row = conn.execute("SELECT policy, status, expires_at, owner_label, project FROM owner_dispatch_envelope"
                       " WHERE auth_id=?", (auth_id,)).fetchone()
    if row is None:
        return None
    try:
        pol = validate_policy(json.loads(row[0]))
    except ValueError:
        return {"auth_id": auth_id, "status": row[1], "expires_at": row[2], "policy_invalid": True}
    n_day = conn.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE parent=? AND decided_at > ?",
                         (auth_id, _utc(now - 86400))).fetchone()[0]
    n_all, spent = conn.execute("SELECT COUNT(*), COALESCE(SUM(spent_cents),0) FROM owner_dispatch_auth"
                                " WHERE parent=?", (auth_id,)).fetchone()
    return {"auth_id": auth_id, "status": row[1], "expires_at": row[2], "templates": [t["name"] for t in pol["templates"]],
            "used_day": n_day, "max_per_day": pol["max_per_day"], "used_week": n_all, "max_per_week": pol["max_per_week"],
            "spent_cents": spent, "total_cap_cents": pol["total_cap_cents"],
            "per_item_cap_cents": pol["per_item_cap_cents"], "policy": pol,
            "remaining": {"day": max(pol["max_per_day"] - n_day, 0), "week": max(pol["max_per_week"] - n_all, 0),
                          "cents": max(pol["total_cap_cents"] - spent, 0)}}


def _read_intent(journal_root: str, label: str, rid: str) -> dict | None:
    """intent.json via O_NOFOLLOW directory/file descriptors, regular file,
    bounded; None on any irregularity."""
    fds = []
    try:
        fds.append(os.open(journal_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
        for part in (label, rid):
            if not part or "/" in part or part in (".", ".."):
                return None
            fds.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
        fd = os.open("intent.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fds[-1])
        fds.append(fd)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_REQUEST_BYTES:
            return None
        data = os.read(fd, MAX_REQUEST_BYTES + 1)
        obj = json.loads(data)
        return obj if isinstance(obj, dict) else None
    except (OSError, ValueError):
        return None
    finally:
        for f in fds:
            os.close(f)


def unsent(conn: sqlite3.Connection, journal_root: str) -> list[str]:
    """auth_ids of consumed grants NOT accounted for by an intent.json that
    carries exactly their consumed envelope. Read-only."""
    out = []
    for (aid,) in conn.execute("SELECT auth_id FROM owner_dispatch_auth WHERE status='consumed' ORDER BY auth_id").fetchall():
        env = _envelope(conn, aid)
        intent = _read_intent(journal_root, env["owner_label"], env["request_id"])
        if not intent or intent.get("auth") != env or intent.get("rid") != env["request_id"] \
                or intent.get("label") != env["owner_label"]:
            out.append(aid)
    return out


def envelope_sha256(env: dict) -> str:
    return hashlib.sha256(json.dumps(env, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _record(conn, auth_id, kind, env_sha, operator, decision_ref, outcome, note, new_rid):
    conn.execute("INSERT INTO owner_dispatch_operator (auth_id, kind, envelope_sha256, operator, decision_ref,"
                 " outcome, note, new_request_id, recorded_at) VALUES (?,?,?,?,?,?,?,?,?)",
                 (auth_id, kind, env_sha, operator, decision_ref, outcome, note, new_rid, _now_iso()))


def revoke(conn: sqlite3.Connection, auth_id: str, *, operator: str, decision_ref: str, note: str = "",
           now: float) -> str:
    """'revoked', or why not: revoke_missing | revoke_denied | revoke_too_late_consumed |
    revoke_expired | revoke_invalid | revoke_ambiguous:<Error>. Never raises."""
    if not operator or not decision_ref:
        return "revoke_invalid"
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            row = conn.execute("SELECT status, expires_at FROM owner_dispatch_auth WHERE auth_id=?", (auth_id,)).fetchone()
            if row is None:
                return "revoke_missing"
            st, exp = row
            if st == "consumed":
                return "revoke_too_late_consumed"
            if st == "denied":
                return "revoke_denied"
            if not isinstance(exp, (int, float)) or now >= exp:
                return "revoke_expired"
            env_sha = envelope_sha256(_envelope(conn, auth_id))
            if conn.execute("UPDATE owner_dispatch_auth SET status='denied' WHERE auth_id=? AND status='granted'",
                            (auth_id,)).rowcount != 1:
                return "revoke_too_late_consumed"
            _record(conn, auth_id, "revoked", env_sha, operator, decision_ref, "revoked", note, None)
            conn.execute("COMMIT")
            return "revoked"
        finally:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
    except sqlite3.Error as exc:
        return f"revoke_ambiguous:{type(exc).__name__}"


def resolve(conn: sqlite3.Connection, auth_id: str, *, envelope_sha256_hex: str, operator: str, decision_ref: str,
            outcome: str, note: str = "", new_request_id: str | None = None) -> str:
    """'resolved', or why not: resolve_invalid | resolve_missing | resolve_not_consumed |
    resolve_key_mismatch | resolve_duplicate | resolve_ambiguous:<Error>. new_request_id is
    recorded only; it grants nothing. Never raises."""
    # Every outcome is an operator ASSERTION; `note` must carry its evidence
    # (e.g. the owner's handoff read-back), it is not proof by itself.
    if not operator or not decision_ref or outcome not in OUTCOMES or not (note or "").strip():
        return "resolve_invalid"
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            row = conn.execute("SELECT status FROM owner_dispatch_auth WHERE auth_id=?", (auth_id,)).fetchone()
            if row is None:
                return "resolve_missing"
            if row[0] != "consumed":
                return "resolve_not_consumed"
            if envelope_sha256(_envelope(conn, auth_id)) != envelope_sha256_hex:
                return "resolve_key_mismatch"
            try:
                _record(conn, auth_id, "resolved", envelope_sha256_hex, operator, decision_ref, outcome, note,
                        new_request_id)
            except sqlite3.IntegrityError:
                return "resolve_duplicate"
            conn.execute("COMMIT")
            return "resolved"
        finally:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
    except sqlite3.Error as exc:
        return f"resolve_ambiguous:{type(exc).__name__}"


def unresolved(conn: sqlite3.Connection, journal_root: str) -> list[str]:
    """unsent() minus grants whose resolution names their exact current envelope. Read-only."""
    out = []
    for aid in unsent(conn, journal_root):
        r = conn.execute("SELECT envelope_sha256 FROM owner_dispatch_operator WHERE auth_id=? AND kind='resolved'",
                         (aid,)).fetchone()
        if not r or r[0] != envelope_sha256(_envelope(conn, aid)):
            out.append(aid)
    return out


def open_store(path: str, uid: int | None = None) -> sqlite3.Connection:
    """The EXISTING auth store, via lib/private_sqlite.open_private (canonical
    path, private file/parents/sidecars, post-open inode check). Never creates."""
    return private_sqlite.open_private(
        path, lambda p: sqlite3.connect(f"file:{p}?mode=rw", uri=True, isolation_level=None, timeout=10),
        uid, require_table="owner_dispatch_auth")


def read_request_once(parent: str, name: str, max_bytes: int = MAX_REQUEST_BYTES) -> bytes:
    """The request bytes, read ONCE through a bounded regular-file descriptor
    opened O_NOFOLLOW under the exact canonical parent. Raises ValueError."""
    if not os.path.isabs(parent) or os.path.realpath(parent) != parent:
        raise ValueError("parent_not_canonical")
    if not name or "/" in name or name in (".", ".."):
        raise ValueError("bad_name")
    dfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    finally:
        os.close(dfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("not_regular_file")
        if st.st_size == 0 or st.st_size > max_bytes:
            raise ValueError("bad_size")
        chunks, left = [], max_bytes + 1
        while left > 0:
            b = os.read(fd, left)
            if not b:
                break
            chunks.append(b)
            left -= len(b)
        data = b"".join(chunks)
        if len(data) > max_bytes or len(data) != st.st_size:
            raise ValueError("changed_while_reading")
        return data
    finally:
        os.close(fd)


def body_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
