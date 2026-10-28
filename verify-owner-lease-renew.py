#!/usr/bin/env python3
"""verify-owner-lease-renew.py — offline proofs for lib/owner_lease_renew.py
(in-place lease renewal, R12-RENEWAL.md) and its OFF-BY-DEFAULT wiring in
remote-mcp/publisher.py (owner_lease_renew_tick). No live registry, pane,
network or herdr call."""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE / "remote-mcp"))  # publisher imports sanitize
import owner_lease as ol  # noqa: E402
import owner_lease_delivery as old  # noqa: E402
import owner_lease_renew as olr  # noqa: E402

FAILS: list[str] = []
T0 = 1_800_000_000.0
TTL = 3600
P1, B1, S1 = "w1:p1", "term_aaa", "a" * 64
P2, B2, S2 = "w1:p2", "term_bbb", "b" * 64


def case(name, cond):
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def _max_gen(conn, label):
    return conn.execute("SELECT MAX(generation) FROM owner_leases WHERE label=?", (label,)).fetchone()[0]


def scratch(kb_end=None, hc_end=None):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "owner.sqlite3")
    c = ol.connect(path)
    ol.migrate(c)
    ol.register_owner(c, "kb", "tntpgh/knowledge-base", now=T0,
                      lifecycle_end_at=T0 + 10_000_000 if kb_end is None else kb_end)
    ol.register_owner(c, "hc", "tntpgh/herdr-control", now=T0,
                      lifecycle_end_at=T0 + 10_000_000 if hc_end is None else hc_end)
    c.close()
    return path


def main():
    # --- renew_due: library level ---
    path = scratch()
    c = ol.connect(path)

    case("no live lease at all -> no_live_lease, never claims one here",
         olr.renew_due(c, "kb", (P1, B1, S1), now=T0) == "no_live_lease"
         and ol.holder_tuple(c, "kb", T0) is None)

    gen1 = ol.acquire(c, "kb", P1, B1, TTL, T0, session_digest=S1)
    case("fixture: kb live at gen 1", gen1 == 1)
    case("plenty of TTL left (> margin) -> not_due, nothing touched",
         olr.renew_due(c, "kb", (P1, B1, S1), now=T0 + 1, margin_s=900) == "not_due"
         and ol.holder_tuple(c, "kb", T0 + 1) == (P1, B1, S1, 1))

    due_at = T0 + TTL - 800  # 800s remain: inside the default 900s margin
    case("within margin + identity matches -> renewed, SAME generation, later expiry",
         olr.renew_due(c, "kb", (P1, B1, S1), now=due_at, margin_s=900, ttl_s=TTL) == "renewed"
         and ol.holder_tuple(c, "kb", due_at) == (P1, B1, S1, 1))
    renewed_expiry = c.execute("SELECT expires_at FROM owner_leases WHERE label='kb' AND released_at IS NULL"
                               ).fetchone()[0]
    case("renewal actually extended expires_at past the old boundary",
         olr._ts(renewed_expiry) == due_at + TTL)

    case("due again, but registry identity MISMATCHES the live holder -> identity_mismatch, untouched",
         olr.renew_due(c, "kb", (P2, B2, S2), now=due_at + TTL - 800, margin_s=900) == "identity_mismatch"
         and ol.holder_tuple(c, "kb", due_at + TTL - 800) == (P1, B1, S1, 1) and _max_gen(c, "kb") == 1)
    case("due again, registry has no resolution at all -> identity_unresolvable, untouched",
         olr.renew_due(c, "kb", None, now=due_at + TTL - 800, margin_s=900) == "identity_unresolvable"
         and ol.holder_tuple(c, "kb", due_at + TTL - 800) == (P1, B1, S1, 1) and _max_gen(c, "kb") == 1)

    # --- an EXPIRED lease is not renewed; renewal never claims/takes over ---
    c2 = ol.connect(path)
    gen_hc = ol.acquire(c2, "hc", P2, B2, 5, T0, session_digest=S2)  # 5s TTL
    case("fixture: hc live at gen 1, short TTL", gen_hc == 1)
    case("already expired by the time of the pass -> no_live_lease (never a takeover here)",
         olr.renew_due(c2, "hc", (P2, B2, S2), now=T0 + 10) == "no_live_lease")
    c2.close()

    # --- renew_all_due: one pass over every registered label ---
    c3 = ol.connect(path)
    anchor = T0 + 1_000_000  # clear of every earlier mutation on this same DB file
    ol.acquire(c3, "kb", P1, B1, TTL, anchor, session_digest=S1)  # fresh, known expiry
    ol.acquire(c3, "hc", P2, B2, TTL, anchor, session_digest=S2)  # fresh, known expiry
    due_pass = anchor + TTL - 800  # both due at the same pass
    identities = {"kb": (P1, B1, S1), "hc": None}  # hc unresolvable this pass
    out = olr.renew_all_due(c3, identities.get, now=due_pass)
    case("renew_all_due: one outcome per REGISTERED label, label order",
         list(out.keys()) == ["hc", "kb"])
    case("renew_all_due: kb (resolvable, due) renewed", out["kb"] == "renewed")
    case("renew_all_due: hc (unresolvable, due) reported, not renewed",
         out["hc"] == "identity_unresolvable")
    c3.close()
    c.close()

    # --- disabled store fails closed (ol._tx's own enabled check raises Disabled) ---
    c4 = ol.connect(path)
    gen_before_disabled = _max_gen(c4, "kb")  # kb is at gen 2 here (renew_all_due's fixture re-acquire took over)
    ol.disable(c4, T0 + 20 + TTL)
    case("disabled: due renewal is refused (renew_refused), not silently skipped as healthy",
         olr.renew_due(c4, "kb", (P1, B1, S1), now=T0 + 20 + TTL + 1, margin_s=10_000_000) == "renew_refused"
         and _max_gen(c4, "kb") == gen_before_disabled)
    c4.close()

    # --- r15/F1: renew_due() must NEVER mint a new lease_id/generation when
    # a concurrent release lands in its own TOCTOU window (between its
    # internal _live() read and its mutation step). Reproduces
    # tmp/in/ra/r15/race-renew-check.py: freeze renew_due's internal
    # ol._live() read to a snapshot taken BEFORE a concurrent release(),
    # then let the REAL renew_due() run its REAL mutation step (the
    # conditional UPDATE) against the row as it ACTUALLY is now (released).
    from unittest import mock
    c6 = ol.connect(scratch())
    gen_rc = ol.acquire(c6, "kb", P1, B1, TTL, T0, session_digest=S1)
    case("fixture: kb live at gen 1 (race fixture)", gen_rc == 1)
    due_rc = T0 + TTL - 800
    frozen_cur = ol._live(c6, "kb", due_rc)  # renew_due's own read, captured before the race
    case("fixture: frozen read captured a live lease", frozen_cur is not None)
    released = ol.release(c6, "kb", gen_rc, P1, B1, now=due_rc)
    case("fixture: concurrent release landed in the window", released and ol._live(c6, "kb", due_rc) is None)
    before_rows = c6.execute("SELECT lease_id, generation, released_at FROM owner_leases WHERE label='kb' "
                             "ORDER BY generation").fetchall()
    with mock.patch.object(ol, "_live", return_value=frozen_cur):
        race_status = olr.renew_due(c6, "kb", (P1, B1, S1), now=due_rc, margin_s=900, ttl_s=TTL)
    after_rows = c6.execute("SELECT lease_id, generation, released_at FROM owner_leases WHERE label='kb' "
                            "ORDER BY generation").fetchall()
    case("r15/F1: renew_due on a frozen-stale read of a concurrently-released lease is NOT 'renewed'",
         race_status != "renewed")
    case("r15/F1: status is exactly identity_mismatch (the conditional UPDATE's rowcount was 0)",
         race_status == "identity_mismatch")
    case("r15/F1: NO new lease_id/generation was minted -- exactly the original row, nothing else written",
         after_rows == before_rows)
    case("r15/F1: MAX(generation) unchanged after the race", _max_gen(c6, "kb") == gen_rc)
    c6.close()


    # --- R13-BOUNDS.md: ABSOLUTE lifecycle_end_at bound ---
    c5p = scratch()  # fresh DB; kb/hc keep the default far-future bound from scratch()
    c5 = ol.connect(c5p)
    ol.register_owner(c5, "nb", "tntpgh/no-bound", now=T0)  # no lifecycle_end_at recorded at all
    gen_nb = ol.acquire(c5, "nb", P1, B1, TTL, T0, session_digest=S1)
    case("fixture: nb live, registered with NO lifecycle_end_at", gen_nb == 1)
    due_nb = T0 + TTL - 800
    case("label with no lifecycle_end_at recorded at all -> no_lifecycle_bound, never renewed",
         olr.renew_due(c5, "nb", (P1, B1, S1), now=due_nb, margin_s=900) == "no_lifecycle_bound"
         and ol.holder_tuple(c5, "nb", due_nb) == (P1, B1, S1, 1))

    ol.register_owner(c5, "pe", "tntpgh/past-end", now=T0, lifecycle_end_at=T0 + 100)
    gen_pe = ol.acquire(c5, "pe", P2, B2, TTL, T0, session_digest=S2)
    case("fixture: pe live, lifecycle_end_at already in the past at renewal time", gen_pe == 1)
    case("now at/past lifecycle_end_at -> lifecycle_ended, never renewed",
         olr.renew_due(c5, "pe", (P2, B2, S2), now=T0 + 200, margin_s=10_000_000) == "lifecycle_ended"
         and ol.holder_tuple(c5, "pe", T0 + 200) == (P2, B2, S2, 1))

    ol.register_owner(c5, "cl", "tntpgh/clamped", now=T0, lifecycle_end_at=T0 + TTL + 500)
    gen_cl = ol.acquire(c5, "cl", "w1:p3", "term_ccc", TTL, T0, session_digest="c" * 64)
    case("fixture: cl live, lifecycle_end_at close ahead of a full-TTL renewal", gen_cl == 1)
    due_cl = T0 + TTL - 800
    case("renewal clamps to lifecycle_end_at, never requests the full ttl_s past it",
         olr.renew_due(c5, "cl", ("w1:p3", "term_ccc", "c" * 64), now=due_cl, margin_s=900, ttl_s=TTL) == "renewed")
    cl_expiry = c5.execute("SELECT expires_at FROM owner_leases WHERE label='cl' AND released_at IS NULL").fetchone()[0]
    case("clamped renewal's new expires_at lands exactly at lifecycle_end_at, not due_cl+ttl_s",
         olr._ts(cl_expiry) == T0 + TTL + 500 and olr._ts(cl_expiry) < due_cl + TTL)

    ol.register_owner(c5, "ze", "tntpgh/zero-edge", now=T0, lifecycle_end_at=T0 + TTL - 800 + 0.5)
    gen_ze = ol.acquire(c5, "ze", "w1:p4", "term_zzz", TTL, T0, session_digest="d" * 64)
    due_ze = T0 + TTL - 800
    case("fixture: ze live, lifecycle_end_at only 0.5s past the due instant", gen_ze == 1)
    case("effective_ttl truncates to < 1s -> lifecycle_ended, acquire() never called with an invalid ttl_s",
         olr.renew_due(c5, "ze", ("w1:p4", "term_zzz", "d" * 64), now=due_ze, margin_s=900, ttl_s=TTL)
         == "lifecycle_ended" and ol.holder_tuple(c5, "ze", due_ze) == ("w1:p4", "term_zzz", "d" * 64, 1))

    # "revoked" (r13's wording) maps to this codebase's release()/reap() -- both set released_at and
    # are observed identically by renew_due through ol._live(); neither is ever revived here.
    ol.release(c5, "cl", gen_cl, "w1:p3", "term_ccc", now=due_cl + 1)
    case("fixture: cl voluntarily released (stand-in for 'revoked')", ol.holder_tuple(c5, "cl", due_cl + 2) is None)
    case("renew_due on a released/revoked lease -> no_live_lease, never revives it",
         olr.renew_due(c5, "cl", ("w1:p3", "term_ccc", "c" * 64), now=due_cl + 2, margin_s=10_000_000)
         == "no_live_lease")
    c5.close()

    import ast as _ast
    _tree = _ast.parse((HERE / "lib" / "owner_lease_renew.py").read_text())
    _imported = {n.name.split(".")[0] for node in _ast.walk(_tree) if isinstance(node, _ast.Import) for n in node.names}
    _imported |= {node.module.split(".")[0] for node in _ast.walk(_tree)
                 if isinstance(node, _ast.ImportFrom) and node.module}
    case("GUARD: lib/owner_lease_renew.py never imports owner_dispatch_auth (no grant touched)",
         "owner_dispatch_auth" not in _imported)

    # --- publisher.py wiring (fake registry; no network, no pane) ---
    lpath = scratch()
    lc = ol.connect(lpath)
    ol.acquire(lc, "kb", P1, B1, TTL, time.time(), session_digest=S1)
    lc.close()
    for k in (old.FLAG, old.DB_ENV, "HERDR_OWNER_LEASE_RENEW"):
        os.environ.pop(k, None)
    spec = importlib.util.spec_from_file_location("publisher_renew", HERE / "remote-mcp" / "publisher.py")
    pub = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pub)
    pub.registry_resolver = lambda label: {"kb": (P1, B1, S1)}.get(label)

    case("publisher, flag OFF: owner_lease_renew_tick returns None, nothing touched",
         pub.owner_lease_renew_tick() is None)

    os.environ[old.FLAG] = "0"
    os.environ["HERDR_OWNER_LEASE_DB"] = lpath
    os.environ["HERDR_OWNER_LEASE_RENEW"] = "1"
    pub._OWNER_LEASE_GATE = None
    case("publisher, renew flag ON but gate flag OFF: gate is None -> raises (misconfiguration, never silent)",
         _raises(pub.owner_lease_renew_tick))

    os.environ[old.FLAG] = "1"
    pub._OWNER_LEASE_GATE = None
    out = pub.owner_lease_renew_tick()
    case("publisher, both flags ON: renew tick runs over every registered label",
         out == {"hc": "no_live_lease", "kb": "not_due"})

    print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing")
    return 1 if FAILS else 0


def _raises(fn):
    try:
        fn()
        return False
    except RuntimeError:
        return True


if __name__ == "__main__":
    sys.exit(main())
