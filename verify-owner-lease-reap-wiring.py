#!/usr/bin/env python3
"""verify-owner-lease-reap-wiring.py — offline synthetic proofs for
lib/owner_lease_reap (plan_reap, snapshot_from_pane_list, reap_tick).
Real SQLite files and synthetic `herdr pane list` payloads; no
registry/panes/network.
Prints OK/FAIL per case; exit 1 on any FAIL.

  TMPDIR=tmp/test-tmp python3 verify-owner-lease-reap-wiring.py
"""
import hashlib
import json
import math
import os
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import owner_lease as ol  # noqa: E402
import owner_lease_reap as olr  # noqa: E402

T0 = 1_792_000_000.0
TTL = 600
FAILS = []
TOTAL = [0]
S = lambda t: hashlib.sha256(t.encode()).hexdigest()  # noqa: E731


def case(name, cond):
    TOTAL[0] += 1
    print(("OK   " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def fresh(label="kb", project="tntpgh/knowledge-base"):
    fd, path = tempfile.mkstemp(suffix=".sqlite3")
    os.close(fd)
    c = ol.connect(path)
    c.execute("PRAGMA journal_mode=WAL")
    ol.migrate(c)
    if label:
        ol.register_owner(c, label, project, now=T0)
    return path, c


# ---- probe_unknown_birth_skips_whole_tick ----
# A live, unexpired holder whose pane record has an empty birth must skip the
# WHOLE tick (no candidates at all), never a partial set that calls it gone.
_, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, S("a"), now=T0)
snapshot = {"w1:p1": {"pane_id": "w1:p1", "birth": ""}}
plan = olr.plan_reap(c, snapshot, snapshot_age_s=1, now=T0 + 10)
case("probe_unknown_birth_skips_whole_tick: status=skip",
     plan["status"] == "skip")
case("probe_unknown_birth_skips_whole_tick: reason=unknown_birth",
     plan.get("reason") == "unknown_birth")
c.close()

# missing birth key entirely (not just empty string) must also skip.
_, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, S("a"), now=T0)
snapshot = {"w1:p1": {"pane_id": "w1:p1"}}
plan = olr.plan_reap(c, snapshot, snapshot_age_s=1, now=T0 + 10)
case("probe_unknown_birth_skips_whole_tick: missing birth key also skips",
     plan["status"] == "skip" and plan["reason"] == "unknown_birth")
c.close()

# ---- probe_stale_skips_apply ----
_, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, S("a"), now=T0)
plan = olr.plan_reap(c, {}, snapshot_age_s=999, now=T0 + 10,
                      max_snapshot_age_s=olr.DEFAULT_MAX_SNAPSHOT_AGE_S)
case("probe_stale_skips_apply: over-TTL snapshot skips",
     plan["status"] == "skip" and plan["reason"] == "stale_snapshot")
plan = olr.plan_reap(c, {}, snapshot_age_s=None, now=T0 + 10)
case("probe_stale_skips_apply: missing freshness metadata skips",
     plan["status"] == "skip" and plan["reason"] == "stale_snapshot")
plan = olr.plan_reap(c, {}, snapshot_age_s=-1, now=T0 + 10)
case("probe_stale_skips_apply: negative age skips",
     plan["status"] == "skip" and plan["reason"] == "stale_snapshot")
c.close()

# ---- probe_malformed_skips ----
_, c = fresh()
plan = olr.plan_reap(c, None, snapshot_age_s=1, now=T0)
case("probe_malformed_skips: None snapshot (probe unavailable) skips",
     plan["status"] == "skip" and plan["reason"] == "probe_unavailable")
plan = olr.plan_reap(c, {"not": "a-mapping-of-records"}, snapshot_age_s=1, now=T0)
case("probe_malformed_skips: non-dict record value skips",
     plan["status"] == "skip" and plan["reason"] == "malformed_snapshot")
plan = olr.plan_reap(c, ["w1:p1"], snapshot_age_s=1, now=T0)
case("probe_malformed_skips: non-dict snapshot skips",
     plan["status"] == "skip" and plan["reason"] == "malformed_snapshot")
c.close()

# ---- probe_live_holder_never_released (A1-A3 scenario) ----
# Reproduce tmp/reap-unknown-birth-check.py scenario A: a live, unexpired
# holder whose pane's birth came back empty in the subscription snapshot.
# Before this guard, a careless controller that dropped the record and built
# live_panes = set() would see observe_stale() call it "pane-gone" and
# reap(dry_run=False) would release the LIVE row. plan_reap() must instead
# skip the whole tick -> zero candidates -> nothing for a caller to apply.
_, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, S("a"), now=T0)
snapshot = {"w1:p1": {"pane_id": "w1:p1", "birth": ""}}
plan = olr.plan_reap(c, snapshot, snapshot_age_s=1, now=T0 + 10)
case("probe_live_holder_never_released: plan_reap skips instead of candidate",
     plan["status"] == "skip")
# Prove the row is untouched: still live, and even feeding plan_reap's own
# (empty) candidate list through reap(dry_run=False) is a no-op because there
# are no candidates to apply.
case("probe_live_holder_never_released: still LIVE after plan_reap",
     ol._live(c, "kb", T0 + 10) is not None)
c.close()

# ---- probe_genuinely_dead_pane_is_candidate ----
# A holder whose pane is cleanly absent from a fresh, fully-known-birth,
# non-stale snapshot IS a pane-gone candidate (the guard isn't a blanket
# no-op — it only fires on genuine ambiguity).
_, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, S("a"), now=T0)
snapshot = {"w9:p9": {"pane_id": "w9:p9", "birth": "term_other"}}
plan = olr.plan_reap(c, snapshot, snapshot_age_s=1, now=T0 + 10)
case("probe_genuinely_dead_pane_is_candidate: status=ok",
     plan["status"] == "ok")
case("probe_genuinely_dead_pane_is_candidate: one pane-gone candidate",
     plan.get("candidates") and len(plan["candidates"]) == 1
     and plan["candidates"][0]["reason"] == "pane-gone"
     and plan["candidates"][0]["pane"] == "w1:p1")
# Applying that candidate through the real primitive (dry_run default) must
# still report dry_run=True, zero DB writes.
dry = ol.reap(c, plan["candidates"], now=T0 + 11)
case("probe_genuinely_dead_pane_is_candidate: default apply stays dry-run",
     dry and dry[0]["dry_run"] is True and dry[0]["released"] is False)
case("probe_genuinely_dead_pane_is_candidate: dry-run writes no events",
     c.execute("SELECT COUNT(*) FROM owner_events WHERE kind='reaped'").fetchone()[0] == 0)
# An expired lease (not pane-gone) must never appear in candidates.
c.close()
_, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, S("a"), now=T0)
plan = olr.plan_reap(c, {}, snapshot_age_s=1, now=T0 + TTL + 1)
case("probe_genuinely_dead_pane_is_candidate: expired lease excluded from candidates",
     plan["status"] == "ok" and plan["candidates"] == [])
c.close()

# ---- probe_whitespace_birth_skips_whole_tick ----
# A live, unexpired holder whose pane record has a whitespace-only (non-empty
# but malformed) birth is not the real birth: it must skip the WHOLE tick,
# not be treated as "known" just because the string is truthy.
_, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, S("a"), now=T0)
snapshot = {"w1:p1": {"pane_id": "w1:p1", "birth": "   "}}
plan = olr.plan_reap(c, snapshot, snapshot_age_s=1, now=T0 + 10)
case("probe_whitespace_birth_skips_whole_tick: status=skip",
     plan["status"] == "skip")
case("probe_whitespace_birth_skips_whole_tick: reason=unknown_birth",
     plan.get("reason") == "unknown_birth")
case("probe_whitespace_birth_skips_whole_tick: holder still live",
     ol._live(c, "kb", T0 + 10) is not None)
c.close()

# ---- probe_trailing_newline_birth_skips_whole_tick ----
# A live, unexpired holder whose pane record has a birth equal to the real
# birth PLUS one trailing newline is not the real birth: `$` in Python's re
# matches before a trailing \n, so BIRTH_RE.match() would wrongly accept it.
# fullmatch() must reject it and skip the WHOLE tick.
_, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, S("a"), now=T0)
snapshot = {"w1:p1": {"pane_id": "w1:p1", "birth": "term_abc123\n"}}
plan = olr.plan_reap(c, snapshot, snapshot_age_s=1, now=T0 + 10)
case("probe_trailing_newline_birth_skips_whole_tick: status=skip",
     plan["status"] == "skip")
case("probe_trailing_newline_birth_skips_whole_tick: reason=unknown_birth",
     plan.get("reason") == "unknown_birth")
case("probe_trailing_newline_birth_skips_whole_tick: holder still live",
     ol._live(c, "kb", T0 + 10) is not None)
c.close()

# ---- probe_nan_age_skips ----
# NaN fails every ordered comparison, so a naive `< 0 or > max` check lets it
# through. inf/-inf must also skip (they already did under the old
# comparison, but math.isfinite() makes the intent explicit and covers both
# in one guard).
_, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, S("a"), now=T0)
for bad_age in (math.nan, math.inf, -math.inf):
    plan = olr.plan_reap(c, {}, snapshot_age_s=bad_age, now=T0 + 10)
    case(f"probe_nan_age_skips: snapshot_age_s={bad_age!r} skips",
         plan["status"] == "skip" and plan["reason"] == "stale_snapshot")
c.close()

# ---- session-digest parity: corroboration must derive lease digests exactly as
# their producer (remote-mcp/publisher.owner_session_digest) does; a drift would
# turn every herdr-restart birth reissue into a "different session" candidate.
import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location(
    "publisher_digest_parity", os.path.join(os.path.dirname(os.path.abspath(__file__)), "remote-mcp", "publisher.py"))
_pub = importlib.util.module_from_spec(_spec)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "remote-mcp"))
_spec.loader.exec_module(_pub)
case("session_digest_matches_publisher_owner_session_digest",
     olr._session_digest("kb", "/synthetic/s.jsonl") == _pub.owner_session_digest("kb", {"agent_session": "/synthetic/s.jsonl"}))

# ================= `herdr pane list` payload -> dry-run reap_tick =================
SESS_A = "/synthetic/sessions/holder-a.jsonl"
DIG_A = olr._session_digest("kb", SESS_A)


def PL(*panes, envelope=True):
    """Synthetic `herdr pane list` JSON: (pane_id, terminal_id, agent_session|None)."""
    rows = [{"pane_id": p, "terminal_id": b, **({"agent_session": {"value": s}} if s is not None else {})}
            for p, b, s in panes]
    return json.dumps({"result": {"panes": rows}} if envelope else {"panes": rows})


def held_lease(digest=DIG_A):
    _, c = fresh()
    ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, digest, now=T0)
    return c


def counts(c):
    return tuple(c.execute(q).fetchone()[0] for q in (
        "SELECT COUNT(*) FROM owner_leases WHERE released_at IS NULL",
        "SELECT COUNT(*) FROM owner_events", "SELECT COUNT(*) FROM owner_requests"))


# ---- parse: both documented envelopes, agent_session.value extracted ----
snap = olr.snapshot_from_pane_list(PL(("w1:p1", "term_abc123", SESS_A)))
case("pane_list_parses_result_envelope",
     snap == {"w1:p1": {"pane_id": "w1:p1", "birth": "term_abc123", "agent_session": SESS_A}})
case("pane_list_parses_bare_panes_envelope",
     olr.snapshot_from_pane_list(PL(("w1:p1", "term_abc123", None), envelope=False))
     == {"w1:p1": {"pane_id": "w1:p1", "birth": "term_abc123", "agent_session": ""}})

# ---- unparseable payload: whole tick skips, never a partial live set ----
c = held_lease()
before = counts(c)
for name, payload in (("invalid JSON", "{not json"), ("no panes key", '{"result":{}}'),
                      ("panes not a list", '{"result":{"panes":{}}}'),
                      ("non-object entry", '{"result":{"panes":["w1:p1"]}}'),
                      ("duplicate pane id", PL(("w1:p1", "term_abc123", SESS_A), ("w1:p1", "term_other", SESS_A))),
                      ("non-herdr pane id", PL(("pane_fake", "term_abc123", SESS_A)))):
    t = olr.reap_tick(c, payload, captured_at=T0 + 9, now=T0 + 10)
    case(f"pane_list_unparseable_skips: {name}",
         t["status"] == "skip" and t["reason"] == "malformed_snapshot" and t["dry_run"] is True)
case("pane_list_unparseable_skips: lease rows/events untouched, holder live",
     counts(c) == before and ol._live(c, "kb", T0 + 10) is not None)
c.close()

# ---- probe missing / stale / unknown freshness ----
c = held_lease()
gone = PL(("w9:p9", "term_other", "/synthetic/other.jsonl"))
for name, payload, cap, reason in (("probe did not run", None, T0 + 9, "probe_unavailable"),
                                   ("captured_at unknown", gone, None, "stale_snapshot"),
                                   ("captured_at too old", gone, T0 + 10 - olr.DEFAULT_MAX_SNAPSHOT_AGE_S - 1, "stale_snapshot"),
                                   ("captured_at in the future", gone, T0 + 11, "stale_snapshot"),
                                   ("captured_at is a bool", gone, True, "stale_snapshot")):
    t = olr.reap_tick(c, payload, captured_at=cap, now=T0 + 10)
    case(f"reap_tick_fails_closed: {name}", t["status"] == "skip" and t["reason"] == reason)
c.close()

# ---- herdr restart: same pane id + same agent session under a reissued birth ----
c = held_lease()
t = olr.reap_tick(c, PL(("w1:p1", "term_afterrestart", SESS_A)), captured_at=T0 + 9, now=T0 + 10)
case("birth_reissued_is_held_not_reaped",
     t["status"] == "ok" and t["would_reap"] == [] and [h["reason"] for h in t["held"]] == ["birth_reissued"])
c.close()

# ---- same pane id, new birth, agent session missing on either side -> uncertain ----
c = held_lease()
t = olr.reap_tick(c, PL(("w1:p1", "term_afterrestart", None)), captured_at=T0 + 9, now=T0 + 10)
case("identity_uncertain_when_live_session_missing",
     t["would_reap"] == [] and [h["reason"] for h in t["held"]] == ["identity_uncertain"])
c.close()
_, c = fresh()
ol.acquire(c, "kb", "w1:p1", "term_abc123", TTL, T0)  # pre-v3 style lease: no session digest
t = olr.reap_tick(c, PL(("w1:p1", "term_afterrestart", SESS_A)), captured_at=T0 + 9, now=T0 + 10)
case("identity_uncertain_when_lease_digest_missing",
     t["would_reap"] == [] and [h["reason"] for h in t["held"]] == ["identity_uncertain"])
c.close()

# ---- pane id recycled to a DIFFERENT agent session -> holder genuinely gone ----
c = held_lease()
t = olr.reap_tick(c, PL(("w1:p1", "term_newowner", "/synthetic/sessions/someone-else.jsonl")),
                  captured_at=T0 + 9, now=T0 + 10)
case("recycled_pane_id_with_other_session_is_candidate",
     [o["pane"] for o in t["would_reap"]] == ["w1:p1"] and t["held"] == [])
c.close()

# ---- dry-run tick on a dead pane: reports, writes NOTHING (read-only conn) ----
path, c = fresh()
ol.claim_initial(c, "kb", "w1:p1", "term_abc123", TTL, DIG_A, now=T0)
c.close()
ro = sqlite3.connect(f"file:{path}?mode=ro", uri=True, isolation_level=None)
before = counts(ro)
t = olr.reap_tick(ro, gone, captured_at=T0 + 9, now=T0 + 10)
case("dry_run_tick_reports_would_reap",
     t["status"] == "ok" and t["dry_run"] is True and len(t["would_reap"]) == 1
     and t["would_reap"][0]["dry_run"] is True and t["would_reap"][0]["released"] is False
     and t["would_reap"][0]["reason"] == "pane-gone")
case("dry_run_tick_runs_on_read_only_connection_and_writes_nothing",
     counts(ro) == before and ol._live(ro, "kb", T0 + 10) is not None)
ro.close()

# ---- rollback: a disabled registry still reports (observation is read-only) ----
c = held_lease()
ol.disable(c, T0 + 5)
t = olr.reap_tick(c, gone, captured_at=T0 + 9, now=T0 + 10)
case("disabled_registry_still_observes_dry_run",
     t["status"] == "ok" and len(t["would_reap"]) == 1 and ol._live(c, "kb", T0 + 10) is not None)
c.close()

print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing of {TOTAL[0]}")
if FAILS:
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
sys.exit(0)
