#!/usr/bin/env python3
"""verify-owner-lease-reap-wiring.py — offline synthetic proofs for
lib/owner_lease_reap.plan_reap(). Real SQLite files, no registry/panes/network.
Prints OK/FAIL per case; exit 1 on any FAIL.

  TMPDIR=tmp/test-tmp python3 verify-owner-lease-reap-wiring.py
"""
import hashlib
import math
import os
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

print(f"\n{'PASS' if not FAILS else 'FAIL'}: {len(FAILS)} failing of {TOTAL[0]}")
if FAILS:
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
sys.exit(0)
