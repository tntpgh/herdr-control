#!/usr/bin/env python3
"""Protected task-source receipts. The caller authenticates the source first.

This is the registry storage adapter, not a public authorization endpoint or a
same-user sandbox. Remote callers must have verified the signed envelope;
local callers must have verified process ancestry and the live actor birth.
Nothing in a task's worktree or assigned supervisor establishes that authority.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import sqlite3
import sys
import time
import uuid

TTL_MS = 15 * 60 * 1000
CLAIM_FIELDS = {"version", "source", "command_id", "op", "remote_task_id",
                "requester_actor", "requester_client", "scope", "repo", "mode",
                "effective_scope", "payload_sha256", "issued_at", "expires_at"}
BIND_FIELDS = ("task_id", "run_id", "worker_id", "repo", "worktree", "branch", "trunk", "approval", "pane_id", "pane_birth")
NON_TERMINAL_STATES = ("starting", "running", "blocked")
# Bound-orchestrator-mode pilot cap (brief-bound-orchestrator-mode.md req 3):
# how many non-terminal children a live orchestrator@<p> pane may hold at
# once. A CONSTANT, deliberately not env-overridable: register() runs in the
# spawning caller's process, which for an orchestrator child IS the
# orchestrator, so an env knob would let the capped party raise its own cap.
# Changing it is a reviewed code change plus a new launcher release.
ORCH_CHILD_CAP = 2


class Refused(ValueError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise Refused("duplicate JSON field")
        value[key] = item
    return value


def parse(raw):
    if len(raw.encode("utf-8")) > 262144:
        raise Refused("authorization record exceeds size limit")
    value = json.loads(raw, object_pairs_hook=_pairs,
                       parse_constant=lambda _: (_ for _ in ()).throw(Refused("non-finite JSON value")))
    if not isinstance(value, dict):
        raise Refused("expected JSON object")
    return value


def manifest(raw):
    return canonical(parse(raw or "{}"))


def now_ms():
    return int(time.time() * 1000)


def now_iso():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def connect(path, readonly=False):
    if readonly:
        from urllib.parse import quote
        db = sqlite3.connect("file:" + quote(os.path.abspath(path)) + "?mode=ro", uri=True, timeout=5)
    else:
        db = sqlite3.connect(path, timeout=5)
        db.execute("PRAGMA synchronous=FULL")
    db.row_factory = sqlite3.Row
    return db


def schema(db):
    # Additive v10 migration: no legacy task receives an authorization row.
    # Additive v12 (slice 3, receipt-to-ack recovery): `revision` is a
    # durable, exact monotonic stage counter (accepted=1, bound=2,
    # launch_claimed=3, launched=4) set by the SAME transaction that
    # advances `status`; `acked_revision`/`acked_at` record the last
    # revision a Worker sync round explicitly, correlatedly confirmed.
    # Deliberately NOT derived from `status` at read time: a durable
    # integer the publisher can enumerate ("revision > acked_revision")
    # and CAS-confirm by exact value is immune to a lost local JSON ack
    # cache (publisher.py's `pending_command_acks`) -- the registry row
    # itself is the retained task evidence an unconfirmed revision needs.
    with db:
        db.execute("""CREATE TABLE IF NOT EXISTS task_authorizations (
            command_id TEXT PRIMARY KEY,
            remote_task_id TEXT UNIQUE,
            source TEXT NOT NULL,
            claims TEXT NOT NULL,
            source_sha256 TEXT NOT NULL,
            payload_sha256 TEXT NOT NULL,
            effective_scope TEXT NOT NULL,
            source_repo TEXT NOT NULL,
            expected_manifest TEXT NOT NULL,
            issued_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            deadline_at TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL CHECK(status IN ('accepted','bound','launch_claimed','launched')),
            revision INTEGER NOT NULL DEFAULT 0,
            acked_revision INTEGER NOT NULL DEFAULT 0,
            acked_at TEXT NOT NULL DEFAULT '',
            task_id TEXT UNIQUE,
            run_id TEXT NOT NULL DEFAULT '',
            worker_id TEXT NOT NULL DEFAULT '',
            repo TEXT NOT NULL DEFAULT '',
            worktree TEXT NOT NULL DEFAULT '',
            branch TEXT NOT NULL DEFAULT '',
            trunk TEXT NOT NULL DEFAULT '',
            approval TEXT NOT NULL DEFAULT '',
            pane_id TEXT NOT NULL DEFAULT '',
            pane_birth TEXT NOT NULL DEFAULT '',
            manifest_sha256 TEXT NOT NULL DEFAULT '',
            accepted_at TEXT NOT NULL,
            bound_at TEXT NOT NULL DEFAULT '',
            launch_claimed_at TEXT NOT NULL DEFAULT '',
            launched_at TEXT NOT NULL DEFAULT ''
        )""")
        cols = {r[1] for r in db.execute("PRAGMA table_info(task_authorizations)").fetchall()}
        for col in ("revision", "acked_revision"):
            if col not in cols:
                db.execute(f"ALTER TABLE task_authorizations ADD COLUMN {col} INTEGER NOT NULL DEFAULT 0")
        if "acked_at" not in cols:
            db.execute("ALTER TABLE task_authorizations ADD COLUMN acked_at TEXT NOT NULL DEFAULT ''")
        if "revision" not in cols:
            # A pre-v12 database has rows whose status already advanced
            # past 'accepted' with no revision recorded -- backfill the
            # exact stage number so pending_acks() does not wrongly treat
            # every historical row as newly unconfirmed.
            db.execute("""UPDATE task_authorizations SET revision = CASE status
                WHEN 'accepted' THEN 1 WHEN 'bound' THEN 2
                WHEN 'launch_claimed' THEN 3 WHEN 'launched' THEN 4 ELSE 0 END
                WHERE revision = 0""")
        db.execute("""INSERT INTO schema_meta(key,value) VALUES ('schema_version','12')
            ON CONFLICT(key) DO UPDATE SET value='12'
            WHERE CAST(schema_meta.value AS INTEGER)<12""")


def read(db, command_id):
    return db.execute("SELECT * FROM task_authorizations WHERE command_id=?", (command_id,)).fetchone()


def public(row, newly=False):
    if row is None:
        return {}
    value = dict(row)
    value["newly_accepted"] = newly
    value["effective_scope"] = parse(value["effective_scope"])
    value["claims"] = parse(value["claims"])
    value["repo"] = value["repo"] or value["source_repo"]
    value["task_id"] = value["task_id"] or ""
    value["remote_task_id"] = value["remote_task_id"] or ""
    return value


def verify_receipt(db, row):
    if row is None:
        return
    _check_source(row)
    if row["status"] == "accepted":
        if row["task_id"] is not None:
            raise Refused("unbound receipt contains a task mapping")
    else:
        # A terminal task may still be acknowledged after transport ack loss;
        # historical completion must not permit another launch or action.
        _binding(db, row, require_active=False)


def valid_window(claims):
    issued, expires = claims["issued_at"], claims["expires_at"]
    if (type(issued) is not int or type(expires) is not int or not 0 < issued < expires
            or expires - issued > TTL_MS or issued > now_ms() + 30000 or expires <= now_ms()):
        raise Refused("expired or invalid authorization validity window")


def identifier(value, name):
    if not isinstance(value, str) or not value or len(value) > 256 or any(ord(c) < 32 for c in value):
        raise Refused("invalid authorization " + name)


def expected_remote_manifest(scope):
    if not isinstance(scope, dict) or set(scope) != {"job_class", "secrets", "git", "writes", "net_read"}:
        raise Refused("invalid effective scope fields")
    if scope["git"] not in ("none", "commit-only", "push-own-branch") or scope["secrets"] not in ("grant", "default"):
        raise Refused("unsupported effective scope")
    for field in ("job_class",):
        identifier(scope[field], field)
    for field in ("writes", "net_read"):
        if not isinstance(scope[field], list) or not all(isinstance(v, str) for v in scope[field]):
            raise Refused("invalid effective scope list")
    result = {key: sorted(set(scope[key])) for key in ("writes", "net_read")}
    result.update(git=scope["git"], net_write="none")
    if scope["job_class"] in ("research", "explore"):
        result["handoffs_write"] = "ANSWER.md"
    return canonical(result)


def accept(db, raw_command, raw_claims, deadline=""):
    cmd, claims = parse(raw_command), parse(raw_claims)
    if (set(claims) != CLAIM_FIELDS or canonical(claims) != raw_claims
            or type(claims["version"]) is not int or claims["version"] != 1
            or claims["source"] != "oauth_task_delegation"):
        raise Refused("unsupported authorization schema/source")
    for key in ("command_id", "remote_task_id", "requester_actor", "requester_client", "repo"):
        identifier(claims[key], key)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", claims["command_id"]):
        raise Refused("invalid command id")
    if not re.fullmatch(r"rtask_\d{8}T\d{6}Z_[0-9a-f]{8}", claims["remote_task_id"]):
        raise Refused("invalid remote task id")
    if claims["repo"] in (".", "..") or "/" in claims["repo"] or "\\" in claims["repo"]:
        raise Refused("invalid repository name")
    if claims["op"] not in ("start", "resume") or any(cmd.get(k) != claims[k] for k in ("command_id", "op", "remote_task_id")):
        raise Refused("command/task source binding mismatch")
    payload = cmd.get("payload")
    if not isinstance(payload, dict) or digest(canonical(payload)) != claims["payload_sha256"]:
        raise Refused("changed command payload")
    if payload.get("repo") != claims["repo"] or claims["mode"] not in ("research", "implement"):
        raise Refused("repository/mode binding mismatch")
    if payload.get("mode") != claims["mode"]:
        raise Refused("payload mode mismatch")
    if claims["scope"] != ("herdr:task.start" if claims["mode"] == "research" else "herdr:task.implement"):
        raise Refused("entitlement/mode mismatch")
    valid_window(claims)
    if deadline:
        try:
            stamp = dt.datetime.strptime(deadline, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
        except ValueError as exc:
            raise Refused("invalid task deadline") from exc
        if stamp.timestamp() <= time.time():
            raise Refused("task deadline expired")
    expected = expected_remote_manifest(claims["effective_scope"])
    return _insert(db, claims, raw_claims, expected, deadline)


def _insert(db, claims, raw_claims, expected, deadline=""):
    if not db.in_transaction:
        db.execute("BEGIN IMMEDIATE")
    previous = read(db, claims["command_id"])
    if previous:
        if previous["claims"] != raw_claims or previous["source_sha256"] != digest(raw_claims):
            raise Refused("command id already has a different immutable source receipt")
        verify_receipt(db, previous)
        db.commit()
        return public(previous)
    db.execute("""INSERT INTO task_authorizations
        (command_id,remote_task_id,source,claims,source_sha256,payload_sha256,
         effective_scope,source_repo,expected_manifest,issued_at,expires_at,deadline_at,status,revision,accepted_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?, 'accepted',1,?)""",
        (claims["command_id"], claims.get("remote_task_id") or None, claims["source"], raw_claims,
         digest(raw_claims), claims["payload_sha256"], canonical(claims["effective_scope"]),
         claims["repo"], expected, claims["issued_at"], claims["expires_at"], deadline, now_iso()))
    db.commit()
    return public(read(db, claims["command_id"]), True)


def accept_local(db, command_id, actor_pane, actor_birth, repo, raw_manifest):
    for key, value in (("command id", command_id), ("actor pane", actor_pane), ("actor birth", actor_birth)):
        identifier(value, key)
    if not os.path.isabs(repo) or os.path.normpath(repo) != repo:
        raise Refused("local repository must be an absolute normalized path")
    expected = manifest(raw_manifest)
    payload = {"actor_pane": actor_pane, "actor_birth": actor_birth, "repo": repo, "manifest": parse(expected)}
    payload_hash = digest(canonical(payload))
    # A retry keeps the original validity window; it must never extend a grant.
    db.execute("BEGIN IMMEDIATE")
    previous = read(db, command_id)
    if previous:
        if previous["source"] != "local_conductor" or previous["payload_sha256"] != payload_hash:
            raise Refused("local command id already has a different source")
        verify_receipt(db, previous)
        valid_window(_check_source(previous))
        db.commit()
        return public(previous)
    issued = now_ms()
    claims = {"version": 1, "source": "local_conductor", "command_id": command_id,
              "op": "local_spawn", "remote_task_id": "", "requester_actor": actor_pane,
              "actor_pane_birth": actor_birth, "requester_client": "local_process_ancestry",
              "scope": "local_conductor_task", "repo": repo, "mode": "",
              "effective_scope": parse(expected), "payload_sha256": payload_hash,
              "issued_at": issued, "expires_at": issued + TTL_MS}
    # Keep selection and insertion in a single transaction for concurrent local
    # retry callers; _insert also refuses a collision rather than widening it.
    return _insert(db, claims, canonical(claims), expected)


# ---- resident escalation launch grant (docs/design/resident-launch-grant.md) --
# INERT until a human runs the mint command from a real, live, conductor-
# eligible pane -- that is the ONLY place live ancestry is ever proven for
# this feature, moved to mint time instead of spawn time. A grant is a
# STANDING, read-only policy check, never bound to a task_id and never
# consumed -- the existing `task_id UNIQUE` / claim_task_worktree_mutation
# machinery is architected for a single-use receipt (one row, one eventual
# task), which cannot represent "stay authorized across many no-progress
# escalations for up to 24h". A grant therefore never flows into
# register_task's own authorization_command_id directly. Each actual spawn
# instead self-mints its OWN one-time, task-bindable record
# (accept_resident_spawn, source=resident_escalation_spawn) that links back
# to the standing grant for audit purposes -- the same shape accept_local
# already uses for a live-ancestry spawn, just gated by a grant lookup
# instead of caller_pane_from_ancestry.
RESIDENT_JOB_CLASSES = {"explore", "implement", "plan", "deep-review"}
RESIDENT_TIERS = ("fast", "standard", "deep", "frontier")
RESIDENT_TTL_MS_MAX = 24 * 60 * 60 * 1000  # hard cap: 24h, never longer; re-mint required after


def expected_resident_manifest(scope):
    if not isinstance(scope, dict) or set(scope) != {"job_classes", "max_tier", "secrets"}:
        raise Refused("invalid resident effective scope fields")
    if scope["max_tier"] not in RESIDENT_TIERS:
        raise Refused("unsupported resident max_tier")
    if scope["secrets"] != "default":
        raise Refused("a resident grant may never carry a credential grant")
    if (not isinstance(scope["job_classes"], list) or not scope["job_classes"]
            or not all(v in RESIDENT_JOB_CLASSES for v in scope["job_classes"])):
        raise Refused("invalid resident job_classes")
    return canonical({"job_classes": sorted(set(scope["job_classes"])),
                       "max_tier": scope["max_tier"], "secrets": "default"})


def accept_resident(db, command_id, minting_pane, minting_pane_birth, repo, job_classes_csv, max_tier, ttl_ms):
    for key, value in (("command id", command_id), ("minting pane", minting_pane),
                        ("minting pane birth", minting_pane_birth)):
        identifier(value, key)
    if not os.path.isabs(repo) or os.path.normpath(repo) != repo:
        raise Refused("resident grant repository must be an absolute normalized path")
    job_classes = [j for j in job_classes_csv.split(",") if j]
    expected = expected_resident_manifest({"job_classes": job_classes, "max_tier": max_tier, "secrets": "default"})
    try:
        ttl = int(ttl_ms)
    except (TypeError, ValueError):
        raise Refused("invalid resident grant ttl") from None
    if ttl <= 0 or ttl > RESIDENT_TTL_MS_MAX:
        raise Refused("resident grant ttl exceeds the hard cap")
    payload = {"minting_pane": minting_pane, "minting_pane_birth": minting_pane_birth,
               "repo": repo, "effective_scope": parse(expected)}
    payload_hash = digest(canonical(payload))
    # A retry keeps the original validity window; it must never extend a grant.
    db.execute("BEGIN IMMEDIATE")
    previous = read(db, command_id)
    if previous:
        if previous["source"] != "resident_escalation_grant" or previous["payload_sha256"] != payload_hash:
            raise Refused("resident grant command id already has a different source")
        _check_source(previous)
        db.commit()
        return public(previous)
    issued = now_ms()
    claims = {"version": 1, "source": "resident_escalation_grant", "command_id": command_id,
              "op": "resident_grant", "remote_task_id": "", "requester_actor": minting_pane,
              "actor_pane_birth": minting_pane_birth, "requester_client": "local_process_ancestry",
              "scope": "resident_escalation_grant", "repo": repo, "mode": "",
              "effective_scope": parse(expected), "payload_sha256": payload_hash,
              "issued_at": issued, "expires_at": issued + ttl}
    return _insert(db, claims, canonical(claims), expected)


def read_resident_for_repo(db, repo):
    """The standing-grant lookup escalation's pre-flight check uses: most
    recent accepted, unexpired resident_escalation_grant row for <repo>.
    READ-ONLY -- never calls verify_receipt/_binding (those assume the
    single-task-bound model this grant deliberately does not use), never
    mutates. An expired or absent grant returns {} exactly alike -- the
    caller falls through to today's live-ancestry check either way."""
    row = db.execute(
        """SELECT * FROM task_authorizations
           WHERE source='resident_escalation_grant' AND source_repo=? AND status='accepted' AND expires_at>?
           ORDER BY issued_at DESC LIMIT 1""",
        (repo, now_ms())).fetchone()
    if row is None:
        return {}
    _check_source(row)  # integrity only
    return public(row)


def accept_resident_spawn(db, command_id, grant_command_id, repo, raw_manifest):
    """The one-time, task-bindable record a resident-grant-admitted spawn
    self-mints for ITSELF, mirroring accept_local's shape exactly so
    register_task/mark_authorization_launch need no changes at all -- the
    only difference is what gated minting it (a standing grant lookup
    instead of live caller_pane_from_ancestry) and that its claims carry
    grant_command_id, the durable audit link back to the standing grant
    that authorized it. The standing grant row itself is never touched."""
    for key, value in (("command id", command_id), ("grant command id", grant_command_id)):
        identifier(value, key)
    if not os.path.isabs(repo) or os.path.normpath(repo) != repo:
        raise Refused("resident spawn repository must be an absolute normalized path")
    expected = manifest(raw_manifest)
    payload = {"grant_command_id": grant_command_id, "repo": repo, "manifest": parse(expected)}
    payload_hash = digest(canonical(payload))
    db.execute("BEGIN IMMEDIATE")
    previous = read(db, command_id)
    if previous:
        if previous["source"] != "resident_escalation_spawn" or previous["payload_sha256"] != payload_hash:
            raise Refused("resident spawn command id already has a different source")
        verify_receipt(db, previous)
        valid_window(_check_source(previous))
        db.commit()
        return public(previous)
    issued = now_ms()
    claims = {"version": 1, "source": "resident_escalation_spawn", "command_id": command_id,
              "op": "resident_spawn", "remote_task_id": "", "requester_actor": "resident:" + grant_command_id,
              "actor_pane_birth": "resident-grant", "requester_client": "resident_escalation_grant",
              "scope": "resident_escalation_spawn", "repo": repo, "mode": "",
              "grant_command_id": grant_command_id, "effective_scope": parse(expected),
              "payload_sha256": payload_hash, "issued_at": issued, "expires_at": issued + TTL_MS}
    return _insert(db, claims, canonical(claims), expected)


def event(db, run_id, task_id, kind, payload):
    db.execute("INSERT INTO events(event_id,run_id,task_id,type,occurred_at,payload) VALUES (?,?,?,?,?,?)",
               ("ev_" + uuid.uuid4().hex, run_id, task_id, kind, now_iso(), canonical(payload)))


def _check_source(row):
    claims = parse(row["claims"])
    if (canonical(claims) != row["claims"] or digest(row["claims"]) != row["source_sha256"]
            or claims["command_id"] != row["command_id"] or claims["source"] != row["source"]
            or claims["payload_sha256"] != row["payload_sha256"]
            or canonical(claims["effective_scope"]) != row["effective_scope"]
            or claims["repo"] != row["source_repo"]
            or claims["issued_at"] != row["issued_at"] or claims["expires_at"] != row["expires_at"]
            or (claims.get("remote_task_id") or "") != (row["remote_task_id"] or "")):
        raise Refused("stored source receipt integrity mismatch")
    if row["source"] == "oauth_task_delegation":
        expected = expected_remote_manifest(claims["effective_scope"])
    elif row["source"] == "local_conductor":
        expected = canonical(claims["effective_scope"])
        identifier(claims.get("requester_actor"), "local actor")
        identifier(claims.get("actor_pane_birth"), "local actor birth")
    elif row["source"] == "resident_escalation_grant":
        expected = canonical(claims["effective_scope"])
        identifier(claims.get("requester_actor"), "resident minting pane")
        identifier(claims.get("actor_pane_birth"), "resident minting pane birth")
    elif row["source"] == "resident_escalation_spawn":
        expected = canonical(claims["effective_scope"])
        identifier(claims.get("grant_command_id"), "resident spawn grant command id")
    else:
        raise Refused("unknown authorization source")
    if expected != row["expected_manifest"]:
        raise Refused("stored source manifest mismatch")
    return claims


def _reservation(db, receipt, task):
    if receipt["source"] != "oauth_task_delegation":
        return
    # Reuse the protected reservation validator on this caller's transaction;
    # a separate process/connection here would reopen a check-to-use race.
    import importlib.util
    from pathlib import Path
    spec = importlib.util.spec_from_file_location("task_reservation_storage", Path(__file__).with_name("task-reservation.py"))
    reservation = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reservation)
    reservation.validate_reservation(db, receipt, task)


def schema_v13(db):
    # Additive v13 (review r1 finding 2, orch-p2-r2): the `claims` table used
    # to be created by two ad hoc, hand-duplicated helpers outside any
    # numbered migration (lib/run-registry.sh's _registry_ensure_claims_table,
    # this file's old _ensure_claims_table), so schema_version could not tell
    # you whether a given registry actually had it, and the DDL had to be
    # kept byte-identical across three copies by inspection. lib/claims.sh's
    # own claims_init (the table's canonical DDL/comment) is the authority
    # this mirrors exactly -- same table, same additive generation column.
    # Run through the same backup-verify-stamp pattern as v11->v12
    # (_migrate_schema_v13 in lib/run-registry.sh), not inline here: a fresh
    # bash `claim_acquire` is a separate connection/transaction from this
    # one, so set_task_conductor/_acquire_pane_lease now rely entirely on
    # registry_init (which always runs before either) having applied this.
    with db:
        db.execute("""CREATE TABLE IF NOT EXISTS claims (
            claim_id    TEXT PRIMARY KEY,
            scope       TEXT NOT NULL,
            pane_id     TEXT NOT NULL DEFAULT '',
            pane_birth  TEXT NOT NULL DEFAULT '',
            purpose     TEXT NOT NULL DEFAULT '',
            parent      TEXT NOT NULL DEFAULT '',
            claimed_at  TEXT NOT NULL,
            renewed_at  TEXT NOT NULL,
            expires_at  TEXT NOT NULL,
            released_at TEXT
        )""")
        db.execute("CREATE INDEX IF NOT EXISTS claims_live ON claims(scope, expires_at) WHERE released_at IS NULL")
        has_gen = db.execute("SELECT 1 FROM pragma_table_info('claims') WHERE name='generation'").fetchone()
        if has_gen is None:
            db.execute("ALTER TABLE claims ADD COLUMN generation INTEGER NOT NULL DEFAULT 1")
        db.execute("""INSERT INTO schema_meta(key,value) VALUES ('schema_version','13')
            ON CONFLICT(key) DO UPDATE SET value='13'
            WHERE CAST(schema_meta.value AS INTEGER)<13""")


def _acquire_pane_lease(db, task):
    """Write the `pane:<worker pane>@<birth>` lease (plan v2 §4.1): who may
    answer this worker's pane. Holder is the CONDUCTOR, not the worker --
    the scope names the pane being protected, the holder names who may act
    on it. No TTL (expires_at is a sentinel far future): the lease lives
    until the task goes terminal or reconcile marks it lost, never on a
    clock. Skipped when either side is unknown (an older call shape, or a
    conductorless registration) -- nothing to fence yet.
    """
    pane_id, pane_birth = task.get("pane_id", ""), task.get("pane_birth", "")
    cpane, cbirth = task.get("conductor_pane_id", ""), task.get("conductor_pane_birth", "")
    if not (pane_id and pane_birth and cpane and cbirth):
        return
    scope = "pane:%s@%s" % (pane_id, pane_birth)
    at = now_iso()
    db.execute(
        """INSERT INTO claims(claim_id, scope, pane_id, pane_birth, purpose, parent,
                               claimed_at, renewed_at, expires_at, generation)
           SELECT ?, ?, ?, ?, ?, '', ?, ?, '9999-12-31T23:59:59Z',
                  (SELECT COALESCE(MAX(generation),0)+1 FROM claims WHERE scope = ?)
           WHERE NOT EXISTS (SELECT 1 FROM claims WHERE scope = ? AND released_at IS NULL)""",
        ("claim_" + uuid.uuid4().hex, scope, cpane, cbirth, task["task_id"], at, at, scope, scope),
    )


def register(db, raw_task, command_id=""):
    task = parse(raw_task)
    if task.get("approval") not in ("menu", "hook"):
        raise Refused("unsupported task approval posture")
    db.execute("BEGIN IMMEDIATE")
    # ---- bound-orchestrator-mode worker cap (brief req 3) -------------------
    # Checked INSIDE the write-locked transaction, never before it: BEGIN
    # IMMEDIATE already holds SQLite's single writer lock for this connection,
    # so a second concurrent register() for the same orchestrator blocks here
    # until this one commits or rolls back -- count-then-insert is atomic by
    # construction, no separate fencing token needed. Only applies when the
    # conductor being assigned is itself a LIVE orchestrator@* pane (a plain
    # Main-conducted spawn is never capped); a non-orchestrator conductor
    # short-circuits the roles lookup and costs one extra read.
    cpane, cbirth = task.get("conductor_pane_id", ""), task.get("conductor_pane_birth", "")
    # Requires the registry's `roles` table (schema v10). It is deliberately
    # NOT optional: a registry without it raises here and the spawn is refused
    # (fail closed) rather than silently skipping the orchestrator cap.
    if cpane and cbirth:
        is_orch = db.execute(
            "SELECT 1 FROM roles WHERE pane_id=? AND pane_birth=? AND label LIKE 'orchestrator@%' LIMIT 1;",
            (cpane, cbirth)).fetchone()
        if is_orch is not None:
            children = db.execute(
                "SELECT COUNT(*) FROM tasks WHERE conductor_pane_id=? AND conductor_pane_birth=? AND state IN (%s);"
                % ",".join("?" for _ in NON_TERMINAL_STATES),
                (cpane, cbirth) + NON_TERMINAL_STATES).fetchone()[0]
            if children >= ORCH_CHILD_CAP:
                raise Refused("orchestrator worker cap reached (%d non-terminal children, cap %d)"
                               % (children, ORCH_CHILD_CAP))
    receipt = None
    if command_id:
        receipt = read(db, command_id)
        if receipt is None or receipt["status"] != "accepted" or receipt["task_id"]:
            raise Refused("authorization receipt missing or already bound")
        claims = _check_source(receipt)
        valid_window(claims)
        for field in BIND_FIELDS:
            # A local managed checkout can lack a known remote trunk. Preserve
            # that absence as an exact binding; it does not grant trunk access.
            if field != "trunk" or task.get(field) != "":
                identifier(task.get(field), "task " + field)
        if not all(os.path.isabs(task[field]) and os.path.normpath(task[field]) == task[field]
                   for field in ("repo", "worktree")):
            raise Refused("task paths must be absolute normalized paths")
        matches_repo = (os.path.basename(task["repo"]) == receipt["source_repo"]
                        if receipt["source"] == "oauth_task_delegation" else task["repo"] == receipt["source_repo"])
        if not matches_repo or manifest(task.get("manifest", "")) != receipt["expected_manifest"]:
            raise Refused("task repository/manifest differs from source authorization")
        _reservation(db, receipt, task)
        task["remote_task_id"] = receipt["remote_task_id"] or ""
        task["deadline_at"] = receipt["deadline_at"]
    task.update(state="starting", created_at=now_iso(), updated_at=now_iso())
    columns = tuple(task)
    # Column names originate only in register_task's fixed adapter below.
    allowed = {"task_id", "run_id", "worker_id", "conductor_id", "conductor_pane_id", "conductor_pane_birth",
               "pane_id", "pane_birth", "repo", "worktree", "branch", "trunk", "project", "manifest",
               "approval", "label", "state", "created_at", "updated_at", "remote_task_id", "deadline_at"}
    if not set(columns) <= allowed:
        raise Refused("unsupported task registration fields")
    db.execute("INSERT INTO tasks (" + ",".join(columns) + ") VALUES (" + ",".join("?" for _ in columns) + ")",
               tuple(task[k] for k in columns))
    event(db, task["run_id"], task["task_id"], "registered", {"pane_id": task["pane_id"], "label": task["label"]})
    _acquire_pane_lease(db, task)
    if task["approval"] == "hook":
        event(db, task["run_id"], task["task_id"], "approval_posture",
              {"approval": "hook", "assigned_supervisor": task["conductor_id"], "conductor_pane": task["conductor_pane_id"]})
    if receipt:
        fields = BIND_FIELDS + ("manifest_sha256", "bound_at")
        values = tuple(task[f] for f in BIND_FIELDS) + (digest(manifest(task.get("manifest", ""))), now_iso())
        db.execute("UPDATE task_authorizations SET status='bound',revision=2," + ",".join(f + "=?" for f in fields) + " WHERE command_id=?",
                   values + (command_id,))
        event(db, task["run_id"], task["task_id"], "task_authorization_bound",
              {"command_id": command_id, "source": receipt["source"], "source_sha256": receipt["source_sha256"],
               "requester_actor": claims["requester_actor"], "requester_client": claims["requester_client"],
               "assigned_supervisor": task["conductor_id"], "manifest_sha256": values[-2]})
    if task.get("manifest"):
        event(db, task["run_id"], task["task_id"], "manifest_recorded",
              {"authorization_command_id": command_id, "assigned_supervisor": task["conductor_id"],
               "manifest_sha256": digest(manifest(task["manifest"])), "manifest": parse(task["manifest"])})
    db.commit()


def _binding(db, row, task=None, require_active=True):
    _check_source(row)
    current = db.execute("SELECT * FROM tasks WHERE task_id=?", (row["task_id"],)).fetchone()
    if current is None or (require_active and current["state"] not in ("starting", "running", "blocked")):
        raise Refused("task is absent or no longer active")
    for field in BIND_FIELDS:
        if current[field] != row[field] or (task is not None and task.get(field) != current[field]):
            raise Refused("task " + field + " binding mismatch")
    expected = row["expected_manifest"]
    if (manifest(current["manifest"]) != expected or digest(expected) != row["manifest_sha256"]
            or (task is not None and manifest(task.get("manifest", "")) != expected)):
        raise Refused("task manifest binding mismatch")
    if current["remote_task_id"] != (row["remote_task_id"] or ""):
        raise Refused("task remote identity binding mismatch")
    if task is not None:
        expected_fields = {"authorization_command_id": row["command_id"], "authorization_source": row["source"],
                           "authorization_status": row["status"], "remote_task_id": row["remote_task_id"] or ""}
        for field, value in expected_fields.items():
            if field in task and task[field] != value:
                raise Refused("task " + field + " binding mismatch")
    return current


def launch(db, command_id, task_id, run_id, status):
    if status not in ("launch_claimed", "launched"):
        raise Refused("unsupported launch state")
    before = "bound" if status == "launch_claimed" else "launch_claimed"
    db.execute("BEGIN IMMEDIATE")
    row = read(db, command_id)
    if row is None or row["task_id"] != task_id or row["run_id"] != run_id or row["status"] != before:
        raise Refused("launch claim already consumed or task binding mismatch")
    task = _binding(db, row)
    _reservation(db, row, task)
    if status == "launch_claimed":
        valid_window(parse(row["claims"]))
        if row["deadline_at"] and row["deadline_at"] <= now_iso():
            raise Refused("task deadline expired before launch")
    revision = 3 if status == "launch_claimed" else 4
    db.execute("UPDATE task_authorizations SET status=?,revision=?," + status + "_at=? WHERE command_id=?",
               (status, revision, now_iso(), command_id))
    event(db, run_id, task_id, "task_authorization_" + status,
          {"command_id": command_id, "source_sha256": row["source_sha256"]})
    db.commit()


def check(db, raw_task):
    task = parse(raw_task)
    db.execute("BEGIN")
    row = db.execute("SELECT * FROM task_authorizations WHERE task_id=?", (task.get("task_id"),)).fetchone()
    if row is None:
        raise Refused("missing verified task source")
    if row["status"] not in ("launch_claimed", "launched"):
        raise Refused("task launch has no protected claim")
    _binding(db, row, task)


def pending_acks(db, limit=200):
    """Enumerate receipts whose durable `revision` has advanced past the
    last confirmed `acked_revision` -- independent of the Worker's own
    lease and of publisher.py's local JSON `pending_command_acks` cache,
    which a crash between a registry commit and `save_state()` can lose.
    The registry row itself (not a side cache) is the retained evidence."""
    if not isinstance(limit, int) or not 0 < limit <= 1000:
        raise Refused("invalid pending-ack enumeration limit")
    rows = db.execute(
        "SELECT * FROM task_authorizations WHERE revision > acked_revision "
        "ORDER BY revision ASC, command_id ASC LIMIT ?", (limit,)).fetchall()
    return [public(row) for row in rows]


def confirm_ack(db, command_id, revision):
    """CAS-confirm the EXACT revision a sync round reported sending. An
    older held response can never confirm a newer launched revision: the
    match is on the row's CURRENT `revision`, not merely `>=`, so a stale
    ack for revision 2 (bound) cannot silently confirm revision 4
    (launched) once the receipt has moved on."""
    try:
        revision = int(revision)
    except (TypeError, ValueError):
        raise Refused("invalid acknowledgement revision")
    if revision < 1:
        raise Refused("invalid acknowledgement revision")
    db.execute("BEGIN IMMEDIATE")
    row = read(db, command_id)
    if row is None:
        db.rollback()
        return {"command_id": command_id, "result": "unknown"}
    if row["revision"] != revision:
        db.rollback()
        return {"command_id": command_id, "result": "conflict", "current_revision": row["revision"]}
    if row["acked_revision"] >= revision:
        db.rollback()
        return {"command_id": command_id, "result": "already_recorded", "acked_revision": row["acked_revision"]}
    db.execute("UPDATE task_authorizations SET acked_revision=?,acked_at=? WHERE command_id=? AND revision=?",
               (revision, now_iso(), command_id, revision))
    db.commit()
    return {"command_id": command_id, "result": "recorded", "acked_revision": revision}


def _action_task(db, request):
    """Validate current protected source on the caller's locked connection."""
    receipt = db.execute("SELECT * FROM task_authorizations WHERE task_id=?", (request["task_id"],)).fetchone()
    if receipt is None:
        raise Refused("missing verified task source")
    if receipt["status"] not in ("launch_claimed", "launched"):
        raise Refused("task launch has no protected claim")
    task = _binding(db, receipt)
    if request["run_id"] != task["run_id"]:
        raise Refused("action request run/task binding mismatch")
    return task


def _action_result(changed, reason="", hold=False):
    return {"changed": changed, "reason": reason, "hold": hold}


def action_consume(db, request_id, expected_run, expected_task, expected_tool, expected_sha, current_route):
    """Linearize receipt validation and approved-once consumption together."""
    try:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT * FROM action_requests WHERE request_id=?", (request_id,)).fetchone()
        if row is None:
            raise Refused("action request is absent")
        expected = {"run_id": expected_run, "task_id": expected_task, "tool": expected_tool, "action_sha256": expected_sha}
        if any(not value or row[field] != value for field, value in expected.items()):
            raise Refused("action request snapshot binding mismatch")
        _action_task(db, row)
        if row["status"] != "approved" or row["grant_kind"] != "once":
            db.rollback()
            return _action_result(False, "request has no approved one-shot grant")
        if current_route not in ("conductor", "human") or row["route"] not in ("conductor", "human"):
            raise Refused("unsupported action authority route")
        if row["authority"] != "human" and not (
                row["authority"] == "conductor" and row["route"] == current_route == "conductor"
                and row["verdict"] not in ("reserved", "deny")):
            raise Refused("action decision authority does not satisfy current route")
        changed = db.execute("""UPDATE action_requests SET status='consumed',consumed_at=?
            WHERE request_id=? AND status='approved' AND grant_kind='once'""", (now_iso(), request_id)).rowcount
        if changed != 1:
            db.rollback()
            return _action_result(False, "request changed before consumption")
        db.commit()
        return _action_result(True)
    except (Refused, ValueError, TypeError, KeyError, sqlite3.Error, OSError) as exc:
        db.rollback()
        return _action_result(False, "authorization hold: " + str(exc), True)


def action_decide(db, request_id, status, authority, decided_by, category, reason, expected_request, expected_conductor_birth):
    """Record an action decision against the same transaction's live source."""
    try:
        db.execute("BEGIN IMMEDIATE")
        if status not in ("approved", "declined", "superseded") or authority not in ("conductor", "human"):
            raise Refused("unsupported action decision or authority")
        row = db.execute("SELECT * FROM action_requests WHERE request_id=?", (request_id,)).fetchone()
        snapshot = parse(expected_request)
        fields = ("request_id", "run_id", "task_id", "tool", "action_sha256", "command", "verdict",
                  "route", "grant_kind", "code_path", "code_sha256")
        if (row is None or not snapshot.get("action_sha256")
                or any(field not in snapshot or snapshot[field] != row[field] for field in fields)):
            raise Refused("action request snapshot binding mismatch")
        if row["status"] != "pending":
            db.rollback()
            return _action_result(False, "request is no longer pending")
        if status == "approved":
            task = _action_task(db, row)
            if authority == "conductor":
                if row["route"] != "conductor" or row["verdict"] in ("reserved", "deny"):
                    raise Refused("action requires a human decision")
                if (not decided_by or not expected_conductor_birth
                        or decided_by != task["conductor_pane_id"]
                        or expected_conductor_birth != task["conductor_pane_birth"]):
                    raise Refused("conductor pane/birth changed during review")
            if row["grant_kind"] not in ("once", "file"):
                raise Refused("unsupported action grant kind")
            if row["grant_kind"] == "file":
                if not row["code_path"] or not row["code_sha256"]:
                    raise Refused("file grant has no bound path/content hash")
                # The file grant is part of this same permission mutation. A
                # second shell connection after approval would reopen the race.
                db.execute("""INSERT OR IGNORE INTO file_approvals(task_id,path,sha256,approved_by,approved_at)
                    VALUES (?,?,?,?,?)""", (row["task_id"], row["code_path"], row["code_sha256"],
                                            authority + ":" + decided_by, now_iso()))
        changed = db.execute("""UPDATE action_requests SET status=?,decided_at=?,authority=?,decided_by=?,
            review_category=?,decision_reason=? WHERE request_id=? AND status='pending'""",
            (status, now_iso(), authority, decided_by, category, reason, request_id)).rowcount
        if changed != 1:
            db.rollback()
            return _action_result(False, "request changed before decision")
        db.commit()
        return _action_result(True)
    except (Refused, ValueError, TypeError, KeyError, sqlite3.Error, OSError) as exc:
        db.rollback()
        return _action_result(False, "authorization hold: " + str(exc), True)


def main():
    path, op, *args = sys.argv[1:]
    with connect(path, readonly=op in ("read", "check", "pending-acks", "read-resident")) as db:
        if op == "schema":
            schema(db)
        elif op == "accept":
            print(canonical(accept(db, *args)))
        elif op == "accept-local":
            print(canonical(accept_local(db, *args)))
        elif op == "accept-resident":
            print(canonical(accept_resident(db, *args)))
        elif op == "read-resident":
            print(canonical(read_resident_for_repo(db, *args)))
        elif op == "accept-resident-spawn":
            print(canonical(accept_resident_spawn(db, *args)))
        elif op == "read":
            db.execute("BEGIN")
            row = read(db, *args)
            verify_receipt(db, row)
            print(canonical(public(row)))
        elif op == "register":
            register(db, *args)
        elif op == "launch":
            launch(db, *args)
        elif op == "check":
            check(db, *args)
        elif op == "pending-acks":
            print(canonical(pending_acks(db, int(args[0])) if args else pending_acks(db)))
        elif op == "confirm-ack":
            result = confirm_ack(db, *args)
            print(canonical(result))
            if result["result"] not in ("recorded", "already_recorded"):
                sys.exit(1)
        elif op in ("action-consume", "action-decide"):
            result = (action_consume if op == "action-consume" else action_decide)(db, *args)
            print(canonical(result))
            if not result["changed"]:
                sys.exit(1)
        else:
            raise Refused("unknown registry adapter operation")


if __name__ == "__main__":
    try:
        main()
    except (Refused, ValueError, TypeError, KeyError, sqlite3.Error, OSError) as exc:
        print("authorization hold: " + str(exc), file=sys.stderr)
        sys.exit(1)
