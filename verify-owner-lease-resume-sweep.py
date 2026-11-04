#!/usr/bin/env python3
"""verify-owner-lease-resume-sweep.py — offline proofs for
owner-lease-resume-sweep.py: the candidate-selection query at the library
level, plus a real end-to-end subprocess run of its CLI (the same way
remote-mcp/publisher.py:owner_lease_resume_tick() invokes it) against a
disposable owner-lease store AND a disposable run registry (so
publisher.registry_resolver resolves from a fixture, never the real
machine state). No network, no herdr call, no real ~/.local/state/herdr
path touched.

Real negative tests (never a silent takeover, never a crash):
  - different_holder: a registry identity change since the lease was
    issued must refuse, lease untouched, exactly as a human running
    owner-lease-resume.py by hand would see.
  - flags_off: HERDR_OWNER_LEASE_WRITER unset must refuse before opening
    anything, nothing attempted.
  - a still-LIVE lease is never a candidate (that is renew_all_due's job,
    see verify-owner-lease-renew.py; resuming it would be this script's
    OWN never-takes-over invariant failing if it fired on a live lease).
"""
from __future__ import annotations

import hashlib
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))
import owner_lease as ol  # noqa: E402
import owner_lease_delivery as oled  # noqa: E402

import importlib.util as _ilu  # noqa: E402
_spec = _ilu.spec_from_file_location("owner_lease_resume_sweep", HERE / "owner-lease-resume-sweep.py")
sweep = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(sweep)

FAILS: list[str] = []
T0 = 1_800_000_000.0
TTL = 3600
P1, B1 = "w1:p1", "term_aaa"
P2, B2 = "w1:p2", "term_bbb"  # a DIFFERENT pane -- the recycled-holder case


def case(name, cond):
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def session_digest(label: str, agent_session: str) -> str:
    """Exactly remote-mcp/publisher.py:owner_session_digest -- a fixture's
    lease row and its registry row must agree on this derivation, or
    registry_resolver() and the lease's own session_digest column can
    never match even for the genuinely same holder."""
    return hashlib.sha256(f"{label}:{agent_session}".encode()).hexdigest()


def scratch_lease_db():
    d = tempfile.mkdtemp()
    path = os.path.realpath(os.path.join(d, "owner.sqlite3"))
    c = ol.connect(path)
    ol.migrate(c)
    ol.register_owner(c, "thurber-os", "tntpgh/thurber-os", now=T0, lifecycle_end_at=T0 + 10_000_000)
    ol.register_owner(c, "knowledge-base", "tntpgh/knowledge-base", now=T0, lifecycle_end_at=T0 + 10_000_000)
    ol.register_owner(c, "tourguide", "tntpgh/tourguide", now=T0, lifecycle_end_at=T0 + 10_000_000)
    c.close()
    os.chmod(path, 0o600)  # private_sqlite.py requires zero group/other mode bits; default umask leaves it 0644
    return path


def scratch_registry_db(rows):
    """rows: {label: (pane_id, pane_birth, agent_session)} -- minimal owners
    table publisher.registry_owners()/registry_resolver() read."""
    d = tempfile.mkdtemp()
    path = os.path.realpath(os.path.join(d, "registry.sqlite3"))
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE owners (label TEXT PRIMARY KEY, pane_id TEXT, pane_birth TEXT, "
              "agent_session TEXT, workspace TEXT, registered_at TEXT, updated_at TEXT)")
    for label, (pane, birth, agent_session) in rows.items():
        c.execute("INSERT INTO owners VALUES (?,?,?,?,?,?,?)",
                  (label, pane, birth, agent_session, "/tmp/ws", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"))
    c.commit()
    c.close()
    return path


def run_sweep(lease_db, registry_db, apply, writer="1", delivery="1"):
    env = os.environ.copy()
    env["HERDR_OWNER_LEASE_WRITER"] = writer
    env["HERDR_OWNER_LEASE_DELIVERY"] = delivery
    env["HERDR_OWNER_LEASE_DB"] = lease_db
    env["HERDR_RUN_REGISTRY"] = registry_db
    argv = [sys.executable, str(HERE / "owner-lease-resume-sweep.py")]
    if apply:
        argv.append("--apply")
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=30, env=env)
    return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()


def scratch_lease_db_with_bounds(bounds):
    """bounds: {label: lifecycle_end_at epoch float | None}. Each label is
    registered with that bound and an already-expired gen-1 lease held by
    (P1, B1), so the CLI's write-path lifecycle enforcement (F1) can be
    exercised directly, independent of the sweep's read-only pre-filter."""
    d = tempfile.mkdtemp()
    path = os.path.realpath(os.path.join(d, "owner.sqlite3"))
    c = ol.connect(path)
    ol.migrate(c)
    real_now = time.time()
    for label, end_at in bounds.items():
        ol.register_owner(c, label, f"tntpgh/{label}", now=real_now, lifecycle_end_at=end_at,
                          unregister_token=f"tok-{label}")
        ol.acquire(c, label, P1, B1, 2, real_now - 10, session_digest=session_digest(label, "same-session"))
    c.close()
    os.chmod(path, 0o600)
    return path, real_now


def run_resume_cli(lease_db, registry_db, label, gen, apply, ttl=None, writer="1", delivery="1"):
    env = os.environ.copy()
    env["HERDR_OWNER_LEASE_WRITER"] = writer
    env["HERDR_OWNER_LEASE_DELIVERY"] = delivery
    env["HERDR_OWNER_LEASE_DB"] = lease_db
    env["HERDR_RUN_REGISTRY"] = registry_db
    argv = [sys.executable, str(sweep.RESUME_CLI), "--label", label,
            "--ttl", str(ttl if ttl is not None else sweep.olr.RENEW_TTL_S),
            "--expect-prev-generation", str(gen)]
    if apply:
        argv.append("--apply")
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=30, env=env)
    return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()


def main():
    # --- due_candidates: library level, no subprocess ---
    path = scratch_lease_db()
    c = ol.connect(path)

    case("no lease at all for a registered label -> not a candidate",
         "tourguide" not in sweep.due_candidates(c, T0))

    ol.acquire(c, "thurber-os", P1, B1, TTL, T0, session_digest=session_digest("thurber-os", "s1"))
    case("freshly-acquired, still-live lease -> NOT a candidate (renew_all_due's job, never this one's)",
         "thurber-os" not in sweep.due_candidates(c, T0 + 1))

    expired_at = T0 + TTL + 10
    case("same lease, now past its own expires_at, released_at still NULL -> IS a candidate at gen 1",
         sweep.due_candidates(c, expired_at).get("thurber-os") == 1)

    ol.acquire(c, "knowledge-base", P1, B1, TTL, T0, session_digest=session_digest("knowledge-base", "s2"))
    ol.release(c, "knowledge-base", 1, P1, B1, now=T0 + 5)
    case("explicitly RELEASED lease, even though its own expires_at is also past -> NOT a candidate",
         "knowledge-base" not in sweep.due_candidates(c, expired_at))

    ol.register_owner(c, "no-bound-lane", "tntpgh/no-bound-lane", now=T0, lifecycle_end_at=None)
    ol.acquire(c, "no-bound-lane", P1, B1, TTL, T0, session_digest=session_digest("no-bound-lane", "s3"))
    case("REAL NEGATIVE: NULL lifecycle_end_at, expired lease -> NOT a candidate (F1 defense-in-depth)",
         "no-bound-lane" not in sweep.due_candidates(c, expired_at))

    ol.register_owner(c, "past-bound-lane", "tntpgh/past-bound-lane", now=T0, lifecycle_end_at=T0 + 5)
    ol.acquire(c, "past-bound-lane", P1, B1, TTL, T0, session_digest=session_digest("past-bound-lane", "s4"))
    case("REAL NEGATIVE: lifecycle_end_at already past at scan time -> NOT a candidate (F1 defense-in-depth)",
         "past-bound-lane" not in sweep.due_candidates(c, expired_at))
    c.close()

    # --- end-to-end CLI, real subprocess + real sqlite fixtures ---
    # The subprocess has no injectable `now`: it reads real wall-clock time,
    # so this fixture must be expired against time.time(), not T0.
    lease_db = scratch_lease_db()
    c = ol.connect(lease_db)
    real_now = time.time()
    digest_thurber = session_digest("thurber-os", "same-session")
    digest_tour = session_digest("tourguide", "same-session")
    gen_a = ol.acquire(c, "thurber-os", P1, B1, 2, real_now - 10, session_digest=digest_thurber)  # 2s TTL, 10s ago
    gen_b = ol.acquire(c, "tourguide", P1, B1, 2, real_now - 10, session_digest=digest_tour)       # same shape
    c.close()
    case("fixture: both leases already expired against real wall-clock time", gen_a == 1 and gen_b == 1)

    # thurber-os: registry identity MATCHES the lease's own holder -> resumable.
    # tourguide: registry identity is a DIFFERENT pane -> must refuse, never take over.
    registry_db = scratch_registry_db({
        "thurber-os": (P1, B1, "same-session"),
        "tourguide": (P2, B2, "same-session"),
    })

    rc, out, err = run_sweep(lease_db, registry_db, apply=False)
    case("dry-run: exits 0, never writes", rc == 0)
    case("dry-run: thurber-os plan is a RESUME plan (same holder)", '"thurber-os"' in out and "plan:resume" in out)
    case("dry-run: tourguide is refused (different holder), not planned", "refused:different_holder" in out)

    c = ol.connect(lease_db)
    case("dry-run genuinely wrote nothing: thurber-os still at gen 1",
         c.execute("SELECT MAX(generation) FROM owner_leases WHERE label='thurber-os'").fetchone()[0] == 1)
    c.close()

    rc, out, err = run_sweep(lease_db, registry_db, apply=True)
    case("--apply: exits 0 even though one label refused (never aborts the whole sweep)", rc == 0)
    case("--apply: thurber-os resumed to gen 2", '"thurber-os": "resumed:thurber-os:gen2"' in out)
    case("REAL NEGATIVE: --apply: tourguide (recycled pane) refused:different_holder, NEVER taken over",
         "refused:different_holder" in out and '"tourguide": "resumed' not in out)

    c = ol.connect(lease_db)
    case("the write actually landed: thurber-os lease row is gen 2 now",
         c.execute("SELECT MAX(generation) FROM owner_leases WHERE label='thurber-os'").fetchone()[0] == 2)
    case("REAL NEGATIVE proven at the data layer too: tourguide lease is STILL gen 1, STILL held by P1/B1 "
         "-- the registry disagreeing about who holds it never silently moved the lease to P2/B2",
         c.execute("SELECT generation, pane_id, pane_birth FROM owner_leases WHERE label='tourguide' "
                   "ORDER BY generation DESC LIMIT 1").fetchone() == (1, P1, B1))
    c.close()

    # --- REAL NEGATIVE: flags off refuses before anything is even opened ---
    rc, out, err = run_sweep(lease_db, registry_db, apply=True, writer="0")
    case("REAL NEGATIVE: HERDR_OWNER_LEASE_WRITER unset -> refused:flags_off, exit 4, nothing attempted",
         rc == 4 and out == "refused:flags_off")
    c = ol.connect(lease_db)
    case("flags-off refusal wrote nothing: thurber-os still gen 2 (unchanged from the prior successful run)",
         c.execute("SELECT MAX(generation) FROM owner_leases WHERE label='thurber-os'").fetchone()[0] == 2)
    c.close()

    # --- F1 (HIGH, independent review): lifecycle bound enforced at the WRITE
    # path itself (owner-lease-resume.py), never just the sweep's pre-read, so
    # the manual/human CLI path cannot bypass it either. F4 (unregistered
    # race, same review): checked at the same write path too. ---
    floor = oled.CLAIM_TTL_FLOOR_S
    bound_db, bound_now = scratch_lease_db_with_bounds({
        "nb": None,                              # NULL bound
        "pb": None,                              # set to a PAST bound below (needs bound_now first)
        "tb": None,                              # set to a too-tight bound below
        "ok": None,                              # set to a generous-but-clamping bound below
        "ur": None,                              # registered, then unregistered below
    })
    conn = ol.connect(bound_db)
    conn.execute("UPDATE owner_projects SET lifecycle_end_at=? WHERE label='pb'",
                 (sweep.ol._iso(bound_now - 100),))  # noqa: SLF001 -- already past
    conn.execute("UPDATE owner_projects SET lifecycle_end_at=? WHERE label='tb'",
                 (sweep.ol._iso(bound_now + floor - 100),))  # noqa: SLF001 -- remaining < floor after clamp
    conn.execute("UPDATE owner_projects SET lifecycle_end_at=? WHERE label='ok'",
                 (sweep.ol._iso(bound_now + floor + 50),))  # noqa: SLF001 -- clamps below RENEW_TTL_S, still clears floor
    conn.execute("UPDATE owner_projects SET lifecycle_end_at=? WHERE label='ur'",
                 (sweep.ol._iso(bound_now + 10_000),))  # noqa: SLF001 -- generous; 'ur' is refused for a DIFFERENT reason
    ol.unregister_owner(conn, "ur", "tok-ur", dry_run=False)
    conn.commit()
    conn.close()

    bound_registry = scratch_registry_db({label: (P1, B1, "same-session") for label in ("nb", "pb", "tb", "ok", "ur")})

    rc, out, err = run_resume_cli(bound_db, bound_registry, "nb", 1, apply=True)
    case("REAL NEGATIVE (F1): NULL lifecycle_end_at -> refused:no_lifecycle_bound, exit 2, nothing written",
         rc == 2 and out == "refused:no_lifecycle_bound")

    rc, out, err = run_resume_cli(bound_db, bound_registry, "pb", 1, apply=True)
    case("REAL NEGATIVE (F1): lifecycle_end_at already PAST -> refused:lifecycle_ended, exit 2, nothing written",
         rc == 2 and out == "refused:lifecycle_ended")

    rc, out, err = run_resume_cli(bound_db, bound_registry, "tb", 1, apply=True)
    case("REAL NEGATIVE (F1): bound clamps remaining TTL below the delivery floor -> refused, exit 2, nothing written",
         rc == 2 and out.startswith("refused:ttl_below_delivery_floor_after_lifecycle_clamp:"))

    conn = ol.connect(bound_db)
    for lbl in ("nb", "pb", "tb"):
        case(f"F1 negative '{lbl}' genuinely wrote nothing: still gen 1",
             conn.execute("SELECT MAX(generation) FROM owner_leases WHERE label=?", (lbl,)).fetchone()[0] == 1)
    conn.close()

    rc, out, err = run_resume_cli(bound_db, bound_registry, "ok", 1, apply=True)
    case("F1 positive: bound ahead of the floor resumes, clamped (not refused)",
         rc == 0 and out == "resumed:ok:gen2")
    conn = ol.connect(bound_db)
    ok_row = conn.execute("SELECT expires_at FROM owner_leases WHERE label='ok' AND released_at IS NULL").fetchone()
    conn.close()
    new_expires = sweep.olr._ts(ok_row[0])  # noqa: SLF001 -- same reviewed parser
    bound = bound_now + floor + 50
    case("F1 positive: the clamp actually fired -- new expires_at lands within 2s of the bound "
         "(int-truncation + real subprocess scheduling drift, never exactly at now+RENEW_TTL_S=3600s)",
         bound - 2 <= new_expires <= bound and new_expires < bound_now + sweep.olr.RENEW_TTL_S - 100)

    rc, out, err = run_resume_cli(bound_db, bound_registry, "ur", 1, apply=True)
    case("REAL NEGATIVE (F4): unregistered label -> refused:unregistered_label, exit 2, nothing written",
         rc == 2 and out == "refused:unregistered_label")
    conn = ol.connect(bound_db)
    case("F4 negative 'ur' genuinely wrote nothing: still gen 1",
         conn.execute("SELECT MAX(generation) FROM owner_leases WHERE label='ur'").fetchone()[0] == 1)
    conn.close()

    print()
    print(f"{len(FAILS)} failure(s)" if FAILS else "all checks passed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
