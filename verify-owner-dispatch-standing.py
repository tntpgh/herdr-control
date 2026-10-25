#!/usr/bin/env python3
"""Offline unit proofs for lib/owner_dispatch_auth.consume_standing (M9,
default OFF; the full-stack success/cap/queue-sha proof through
queue_supervisor.tick + the real Dispatcher lives in
verify-queue-supervisor-e2e.py). Disposable temp sqlite stores only: a real
owner_lease DB (for the restart-rule generation math) and a real
owner_dispatch_auth DB. No herdr, no pane, no network, production has no
standing-grant issuer -- fixtures insert rows directly, exactly like
verify-owner-dispatch.py's insert_grant does for one-time grants."""
from __future__ import annotations

import hashlib
import os
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import owner_dispatch_auth as oda  # noqa: E402
import owner_lease as ol  # noqa: E402

fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


base = Path(os.path.realpath(tempfile.mkdtemp()))
lc = ol.connect(str(base / "lease.db"))
ol.migrate(lc)
store = sqlite3.connect(str(base / "auth.db"), isolation_level=None, timeout=10)
oda.migrate(store)

T0 = time.time()
QSHA = hashlib.sha256(b'[{"id":"i1"}]').hexdigest()
BODY = "b" * 64


def insert_standing(aid, *, label, project, holder, item_cap, queue_sha=QSHA, spend_cap=None, expires, conn=None):
    pane, birth, sess, gen = holder
    (conn or store).execute(
        "INSERT INTO owner_dispatch_auth(auth_id,protocol,owner_label,project,pane_id,pane_birth,session_digest,"
        "lease_generation,request_id,body_sha256,manifest,prompt_id,approval_id,status,decided_at,expires_at,"
        "kind,queue_sha256,item_cap,spend_cap_cents) VALUES (?,?,?,?,?,?,?,?,'','','[]','fixture-prompt',"
        "'fixture-approval','granted','2026-10-23T00:00:00Z',?,'standing',?,?,?)",
        (aid, oda.PROTOCOL, label, project, pane, birth, sess, gen, expires, queue_sha, item_cap, spend_cap))


def consume(aid, label, project, holder, rid, *, now=None, queue_sha=QSHA, lease_conn=None, cost_cents=None):
    return oda.consume_standing(store, aid, label=label, project=project, holder=holder, request_id=rid,
                                body_sha256=BODY, manifest=["m"], now=T0 + 1 if now is None else now,
                                queue_sha256=queue_sha, lease_conn=lease_conn, cost_cents=cost_cents)


# ---- lane 1: expiry, revocation, item cap, spend cap, duplicate, queue sha ----
LB, PJ = "proj-std", "tntpgh/proj-std"
PANE, BIRTH, SESS = "wS:p1", "term_stda", hashlib.sha256(b"sess-a").hexdigest()
ol.register_owner(lc, LB, PJ, now=T0)
ol.acquire(lc, LB, PANE, BIRTH, 3600, T0, session_digest=SESS)
H1 = ol.holder_tuple(lc, LB, T0)

insert_standing("a_exp", label=LB, project=PJ, holder=H1, item_cap=5, expires=T0 + 10)
check("EXPIRY: now >= expires_at -> standing_expired",
      consume("a_exp", LB, PJ, H1, "r1", now=T0 + 20) == "standing_expired")

insert_standing("a_rev", label=LB, project=PJ, holder=H1, item_cap=5, expires=T0 + 3600)
check("REVOKE: existing revoke() denies a standing row like any other",
      oda.revoke(store, "a_rev", operator="terrence", decision_ref="form-x", now=T0) == "revoked")
check("REVOKED: denied -> standing_denied", consume("a_rev", LB, PJ, H1, "r1") == "standing_denied")

insert_standing("a_cap", label=LB, project=PJ, holder=H1, item_cap=2, expires=T0 + 3600)
r1 = consume("a_cap", LB, PJ, H1, "r1")
r2 = consume("a_cap", LB, PJ, H1, "r2")
r3 = consume("a_cap", LB, PJ, H1, "r3")
check("CAP: first two items each consume their own child under the floor",
      isinstance(r1, dict) and isinstance(r2, dict) and r1["auth_id"] != r2["auth_id"]
      and r1["request_id"] == "r1" and r2["request_id"] == "r2" and r1["lease_generation"] == 1)
check("CAP: item cap+1 -> held standing_cap, zero further children", r3 == "standing_cap"
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE parent='a_cap'").fetchone()[0] == 2)

insert_standing("a_dup", label=LB, project=PJ, holder=H1, item_cap=5, expires=T0 + 3600)
consume("a_dup", LB, PJ, H1, "r_dup")
check("DUPLICATE: the same item id against the same standing grant is never consumed twice",
      consume("a_dup", LB, PJ, H1, "r_dup") == "standing_consumed")

insert_standing("a_spend", label=LB, project=PJ, holder=H1, item_cap=5, spend_cap=100, expires=T0 + 3600)
s1 = consume("a_spend", LB, PJ, H1, "r1", cost_cents=60)
s2 = consume("a_spend", LB, PJ, H1, "r2", cost_cents=60)
check("SPEND: first item within the remaining cap consumes", isinstance(s1, dict))
check("SPEND: second item would exceed the remaining cap -> held budget, nothing inserted", s2 == "budget"
      and store.execute("SELECT COUNT(*) FROM owner_dispatch_auth WHERE parent='a_spend'").fetchone()[0] == 1)
s3 = consume("a_spend", LB, PJ, H1, "r3")  # cost_cents omitted -> None: never fabricated as free
check("SPEND: no validated cost against a REAL spend cap -> standing_cost_missing, never spent as 0",
      s3 == "standing_cost_missing"
      and store.execute("SELECT spent_cents FROM owner_dispatch_auth WHERE auth_id='a_spend'").fetchone()[0] == 60)

insert_standing("a_qsha", label=LB, project=PJ, holder=H1, item_cap=5, expires=T0 + 3600)
check("QUEUE SHA: a digest that does not match the grant's bound queue.json -> queue_sha_mismatch",
      consume("a_qsha", LB, PJ, H1, "r1", queue_sha="0" * 64) == "queue_sha_mismatch")

# ---- lane 2: same-holder restart (success), then a skipped generation (refused) ----
LB2, PJ2 = "proj-std-restart", "tntpgh/proj-std-restart"
PANE2, BIRTH2, SESS2 = "wS:p2", "term_stdb", hashlib.sha256(b"sess-b").hexdigest()
ol.register_owner(lc, LB2, PJ2, now=T0)
ol.acquire(lc, LB2, PANE2, BIRTH2, 5, T0, session_digest=SESS2)  # short TTL: about to lapse
H2_floor = ol.holder_tuple(lc, LB2, T0)  # gen 1, the floor the grant is signed at
insert_standing("a_restart", label=LB2, project=PJ2, holder=H2_floor, item_cap=5, expires=T0 + 3600)

ol.acquire(lc, LB2, PANE2, BIRTH2, 5, T0 + 10, session_digest=SESS2)  # SAME holder, overnight TTL lapse -> gen 2
H2_g2 = ol.holder_tuple(lc, LB2, T0 + 10)
r_restart_nolease = consume("a_restart", LB2, PJ2, H2_g2, "r_nolease", now=T0 + 11, lease_conn=None)
check("RESTART: generation above the floor without lease_conn to verify it -> fails closed",
      r_restart_nolease == "standing_holder_changed")
r_restart = consume("a_restart", LB2, PJ2, H2_g2, "r1", now=T0 + 11, lease_conn=lc)
check("RESTART: same holder, floor generation released expired, zero open requests -> floor+1 accepted",
      isinstance(r_restart, dict) and r_restart["lease_generation"] == 2 and r_restart["pane_id"] == PANE2)

ol.acquire(lc, LB2, PANE2, BIRTH2, 5, T0 + 20, session_digest=SESS2)  # SAME holder, gen 2 also lapses -> gen 3
H2_g3 = ol.holder_tuple(lc, LB2, T0 + 20)
r_restart_gap = consume("a_restart", LB2, PJ2, H2_g3, "r2", now=T0 + 21, lease_conn=lc)
check("RESTART: floor=1 but live generation is 3 (skipped 2) -> standing_holder_changed, never silently accepted",
      r_restart_gap == "standing_holder_changed")

# ---- lane 3: a genuinely different holder takes the lease after expiry ----
LB3, PJ3 = "proj-std-changed", "tntpgh/proj-std-changed"
PANE3, BIRTH3, SESS3 = "wS:p3", "term_stdc", hashlib.sha256(b"sess-c").hexdigest()
ol.register_owner(lc, LB3, PJ3, now=T0)
ol.acquire(lc, LB3, PANE3, BIRTH3, 5, T0, session_digest=SESS3)
H3_floor = ol.holder_tuple(lc, LB3, T0)
insert_standing("a_changed", label=LB3, project=PJ3, holder=H3_floor, item_cap=5, expires=T0 + 3600)
PANE3B, BIRTH3B, SESS3B = "wS:p3b", "term_stdc2", hashlib.sha256(b"sess-c2").hexdigest()
ol.acquire(lc, LB3, PANE3B, BIRTH3B, 3600, T0 + 10, session_digest=SESS3B)  # a DIFFERENT pane recycles the label
H3_g2 = ol.holder_tuple(lc, LB3, T0 + 10)
check("CHANGED HOLDER: a different pane after expiry does not inherit the grant",
      consume("a_changed", LB3, PJ3, H3_g2, "r1", now=T0 + 11, lease_conn=lc) == "standing_holder_changed")

# ---- lane 4: same pane/birth, only the agent SESSION changed after expiry ----
LB4, PJ4 = "proj-std-sess", "tntpgh/proj-std-sess"
PANE4, BIRTH4 = "wS:p4", "term_stdd"
SESS4A, SESS4B = hashlib.sha256(b"sess-d-a").hexdigest(), hashlib.sha256(b"sess-d-b").hexdigest()
ol.register_owner(lc, LB4, PJ4, now=T0)
ol.acquire(lc, LB4, PANE4, BIRTH4, 5, T0, session_digest=SESS4A)
H4_floor = ol.holder_tuple(lc, LB4, T0)
insert_standing("a_sess", label=LB4, project=PJ4, holder=H4_floor, item_cap=5, expires=T0 + 3600)
ol.acquire(lc, LB4, PANE4, BIRTH4, 3600, T0 + 10, session_digest=SESS4B)  # same pane/birth, NEW session post-expiry
H4_g2 = ol.holder_tuple(lc, LB4, T0 + 10)
check("CHANGED HOLDER: identical pane/birth but a new agent session after expiry still does not inherit",
      consume("a_sess", LB4, PJ4, H4_g2, "r1", now=T0 + 11, lease_conn=lc) == "standing_holder_changed")

# ===== Schema upgrade: an EXISTING v1 (pre-M9) store gains the M9 columns =====
# Simulates production: a store built by the ORIGINAL (pre-M9) migrate(), which
# never created a schema_version table at all, carrying real rows. Disposable
# OLD-schema DB, its own mkdtemp -- no lease DB needed (gen == floor, the
# restart-rule branch is never reached).
old_base = Path(os.path.realpath(tempfile.mkdtemp()))
old_store = sqlite3.connect(str(old_base / "old-auth.db"), isolation_level=None, timeout=10)
old_store.execute(oda.SCHEMA)
for stmt in oda.OPERATOR_SCHEMA + oda.ISSUANCE_SCHEMA:
    old_store.execute(stmt)

OLD_COLS = ("auth_id", "protocol", "owner_label", "project", "pane_id", "pane_birth", "session_digest",
           "lease_generation", "request_id", "body_sha256", "manifest", "prompt_id", "approval_id",
           "status", "decided_at", "expires_at", "consumed_at")


def old_row(aid, status, consumed_at=None):
    return (aid, oda.PROTOCOL, "proj-old", "tntpgh/proj-old", "wO:p1", "term_oldpane",
           hashlib.sha256(b"sess-old").hexdigest(), 1, f"r-{aid}", "c" * 64, "[]",
           "fixture-prompt", "fixture-approval", status, "2026-10-20T00:00:00Z", T0 + 3600, consumed_at)


existing_rows = [old_row("old_granted", "granted"), old_row("old_consumed", "consumed", "2026-10-20T01:00:00Z"),
                 old_row("old_denied", "denied")]
for row in existing_rows:
    old_store.execute(f"INSERT INTO owner_dispatch_auth({','.join(OLD_COLS)}) VALUES ({','.join('?' * len(OLD_COLS))})", row)

before = {r[0]: r for r in old_store.execute(f"SELECT {','.join(OLD_COLS)} FROM owner_dispatch_auth ORDER BY auth_id")}
check("UPGRADE: three pre-M9 rows present before migrate()", len(before) == 3)

version_after = oda.migrate(old_store)
check("UPGRADE: migrate() reaches schema version 2", version_after == 2)

after = {r[0]: r for r in old_store.execute(f"SELECT {','.join(OLD_COLS)} FROM owner_dispatch_auth ORDER BY auth_id")}
check("UPGRADE: every pre-existing row's ORIGINAL 17 columns are byte-identical after the upgrade (no DELETE, no rewrite)",
      after == before and set(after) == {"old_granted", "old_consumed", "old_denied"})

new_cols = old_store.execute(
    "SELECT auth_id, kind, parent, queue_sha256, item_cap, spend_cap_cents, used_count, spent_cents"
    " FROM owner_dispatch_auth ORDER BY auth_id").fetchall()
check("UPGRADE: the new M9 columns land on every pre-existing row with the documented defaults",
      new_cols == [("old_consumed", "single", None, None, None, None, 0, 0),
                  ("old_denied", "single", None, None, None, None, 0, 0),
                  ("old_granted", "single", None, None, None, None, 0, 0)])

check("UPGRADE: re-running migrate() on an already-v2 store is a no-op (version gate, no duplicate ALTER)",
      oda.migrate(old_store) == 2)

# the upgraded store is FUNCTIONAL, not just structurally present: a FRESH
# standing grant can be signed and consumed on it, through the SAME
# consume_standing() used everywhere else.
H_OLD = ("wO:p1", "term_oldpane", hashlib.sha256(b"sess-old2").hexdigest(), 1)
insert_standing("a_upgraded", label="proj-old2", project="tntpgh/proj-old2", holder=H_OLD, item_cap=2,
                queue_sha="d" * 64, expires=T0 + 3600, conn=old_store)
r_upgraded = oda.consume_standing(old_store, "a_upgraded", label="proj-old2", project="tntpgh/proj-old2",
                                  holder=H_OLD, request_id="r1", body_sha256=BODY, manifest=["m"],
                                  now=T0 + 1, queue_sha256="d" * 64)
check("UPGRADE: the upgraded store functions end-to-end -- a NEW standing grant consumes correctly",
      isinstance(r_upgraded, dict) and r_upgraded["lease_generation"] == 1 and r_upgraded["request_id"] == "r1")
old_store.close()

# ===== Migration atomicity: a failure PARTWAY through v2 rolls back EVERY =====
# partial ALTER from that same migrate() call, together with the version
# bump -- single transaction, nothing half-applied. Disposable: the injected
# break is patched into oda.MIGRATIONS[2] and restored in a finally before
# anything else runs.
atomic_base = Path(os.path.realpath(tempfile.mkdtemp()))
atomic_store = sqlite3.connect(str(atomic_base / "atomic-auth.db"), isolation_level=None, timeout=10)
atomic_store.execute("BEGIN IMMEDIATE")
atomic_store.execute("CREATE TABLE owner_dispatch_auth_schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
for stmt in oda.MIGRATIONS[1]:
    atomic_store.execute(stmt)
atomic_store.execute("INSERT INTO owner_dispatch_auth_schema_version VALUES (1, '2026-10-20T00:00:00Z')")
atomic_store.execute("COMMIT")

V1_COLS = sorted(("auth_id", "protocol", "owner_label", "project", "pane_id", "pane_birth", "session_digest",
                  "lease_generation", "request_id", "body_sha256", "manifest", "prompt_id", "approval_id",
                  "status", "decided_at", "expires_at", "consumed_at"))
cols_before = sorted(r[1] for r in atomic_store.execute("PRAGMA table_info(owner_dispatch_auth)"))
check("ATOMICITY: the hand-built v1-only store starts with exactly the original 17 columns",
      cols_before == V1_COLS)

# the 4th statement (after 3 real ALTERs succeed inside the SAME transaction)
# targets a table that does not exist -- deliberately raises mid-migration.
broken_v2 = oda.MIGRATIONS[2][:3] + ("ALTER TABLE owner_dispatch_auth_NONEXISTENT ADD COLUMN x INTEGER",) + oda.MIGRATIONS[2][3:]
orig_v2 = oda.MIGRATIONS[2]
oda.MIGRATIONS[2] = broken_v2
try:
    raised = False
    try:
        oda.migrate(atomic_store)
    except sqlite3.OperationalError:
        raised = True
finally:
    oda.MIGRATIONS[2] = orig_v2
check("ATOMICITY: the injected failure partway through v2 actually raises", raised)

version_after_fail = atomic_store.execute(
    "SELECT COALESCE(MAX(version),0) FROM owner_dispatch_auth_schema_version").fetchone()[0]
check("ATOMICITY: schema_version stays at 1 -- the failed v2 attempt was never recorded", version_after_fail == 1)

cols_after = sorted(r[1] for r in atomic_store.execute("PRAGMA table_info(owner_dispatch_auth)"))
check("ATOMICITY: the 3 v2 columns that succeeded before the injected failure are GONE too -- "
     "one transaction, nothing half-applied", cols_after == cols_before)

check("ATOMICITY: the real (unpatched) migrate() still reaches v2 cleanly on the SAME store afterward",
      oda.migrate(atomic_store) == 2)
atomic_store.close()
print(f"{'PASS' if not fails else 'FAIL'}: {fails} failure(s)")
sys.exit(1 if fails else 0)
