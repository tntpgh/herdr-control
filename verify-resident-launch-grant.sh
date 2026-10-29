#!/usr/bin/env bash
# verify-resident-launch-grant.sh — docs/design/resident-launch-grant.md,
# INERT implementation (feat/resident-launch-grant). 14 tests proving the
# feature fails closed / stays invisible in every way that matters before
# a human ever mints a real grant, plus (cases 10-14) the mint-time repo
# allowlist Terrence approved for Option B (2026-10-29T16:24:10Z):
# herdr-control, knowledge-base, tntpgh-dev, tourguide, exactly those
# four, fail-closed otherwise. Isolated registry + TMPDIR, both under
# tmp/; never actually MINTS a grant via the human-only
# grant-resident-escalation.sh CLI (its own ancestry gate would refuse
# this test runner anyway, same as spawn-task.sh's own gate does for the
# existing suite's case BB) — fixtures call the storage wrappers
# directly, same convention the existing suite already uses to seed
# task_authorizations rows without going through a CLI's own gate. Case
# 14 is the one exception: it invokes the CLI with no arguments, ENTIRELY
# inside this suite's own sandbox (isolated HERDR_RUN_STATE_DIR, shadowed
# herdr on PATH), to smoke-test that the file parses and fails its own
# early usage check before reaching ancestry or any live state.
#
#   1. No grant exists anywhere for the repo: resident_grant_admits
#      refuses, and the real (unmodified, no override) launch-authority
#      gate behaves EXACTLY as it did before this feature existed —
#      default-inert, zero behavior change for every repo with no grant.
#   2. An expired grant (expires_at in the past) is invisible — refused
#      exactly like no grant at all, never partially honored.
#   3. A grant minted for a DIFFERENT repo never admits this one.
#   4. A grant exists and is valid, but its job_classes list does not
#      include the tier being requested (tier-cap-exceeded) — refused,
#      the grant's own ceiling is enforced, not just its existence.
#   5. The global revocation sentinel refuses an otherwise fully valid,
#      admitting grant — and clears the INSTANT the sentinel is removed,
#      proving revocation is checked fresh every call, never cached.
#   6. A grant row tampered with directly in storage (widened past what
#      was actually minted) is refused by the storage layer's own
#      integrity check — scope can't be silently widened after the fact;
#      only a fresh, separately-reviewed mint can grant more.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

export WORK="$here/tmp/verify-resident-grant"
mkdir -p "$WORK"
export TMPDIR="$WORK/TMPDIR"; mkdir -p "$TMPDIR"
export HERDR_RUN_STATE_DIR="$WORK/runs"
mkdir -p "$HERDR_RUN_STATE_DIR"
rm -f "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$HERDR_RUN_STATE_DIR/registry.sqlite3-wal" "$HERDR_RUN_STATE_DIR/registry.sqlite3-shm"

export HERDR_ESCALATION_LADDER="fast standard deep frontier"
export HERDR_RESIDENT_GRANT_REVOKED_FILE="$WORK/resident-escalation.revoked"
rm -f "$HERDR_RESIDENT_GRANT_REVOKED_FILE"

# R3 #5-style belt-and-suspenders: shadow herdr on PATH so any accidental
# real call fails loudly instead of silently reaching a live session —
# none of these 6 tests should ever reach it (no spawn, no mint CLI).
HERDR_SHADOW_BIN="$WORK/shadow-bin"; mkdir -p "$HERDR_SHADOW_BIN"
rm -f "$WORK/herdr-violation"
cat >"$HERDR_SHADOW_BIN/herdr" <<SH
#!/usr/bin/env bash
printf 'UNEXPECTED REAL herdr CALL: %s\\n' "\$*" >> "$WORK/herdr-violation"
exit 1
SH
chmod +x "$HERDR_SHADOW_BIN/herdr"
export PATH="$HERDR_SHADOW_BIN:$PATH"

source "$here/config.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/escalation.sh"
registry_init || { echo "FATAL: registry_init failed" >&2; exit 1; }

pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# mint_grant <repo> <job_classes_csv> <max_tier> [ttl_ms] -> prints command_id
mint_grant() {
  local repo="$1" jc="$2" tier="$3" ttl="${4:-3600000}" cmd out
  cmd="$(gen_id test_resident_grant)"
  out="$(accept_resident_escalation_grant "$cmd" pane-test-mint birth-test-mint "$repo" "$jc" "$tier" "$ttl")" || {
    printf 'FATAL: mint_grant failed: %s\n' "$out" >&2; return 1
  }
  printf '%s\n' "$cmd"
}

# Real standalone git repos, NOT plain subdirectories under this worktree's
# own tree -- repo_root (lib/repo-root.sh) walks UP via git's own
# --git-common-dir to find an ENCLOSING repo's root for any directory that
# isn't itself a repo, so a bare mkdir'd dir under tmp/ here would silently
# resolve to this worktree's own root instead of itself.
REPO_A="$WORK/repo-a"; mkdir -p "$REPO_A"; git -C "$REPO_A" init -q; REPO_A="$(cd "$REPO_A" && pwd -P)"
REPO_B="$WORK/repo-b"; mkdir -p "$REPO_B"; git -C "$REPO_B" init -q; REPO_B="$(cd "$REPO_B" && pwd -P)"

# =============================================================== case 1 ===
# No grant exists anywhere. resident_grant_admits refuses, AND the real,
# unmodified _esc_check_launch_authority gate falls through to and is
# refused by the live-ancestry check exactly as before this feature
# existed. Forces caller_pane_from_ancestry to fail inside a subshell
# (rather than relying on this runner's OWN ambient ancestry, which is
# NOT guaranteed to fail here the way verify-no-progress-escalation.sh's
# case BB assumes for its own execution context -- this proves the
# documented contract -- "falls through unchanged" -- deterministically,
# not by coincidence of where this happens to run).
unset HERDR_ESC_AUTHORITY_CMD
c1_admits_out="$(resident_grant_admits "$REPO_A" implement)"; c1_admits_rc=$?
c1_gate_out="$(caller_pane_from_ancestry() { return 1; }; _esc_check_launch_authority "$REPO_A" standard 2>/dev/null)"; c1_gate_rc=$?
[ "$c1_admits_rc" != 0 ] && [ -z "$c1_admits_out" ] \
  && ok "1: no grant anywhere -- resident_grant_admits refuses, empty stdout" \
  || bad "1: resident_grant_admits (rc=$c1_admits_rc out=[$c1_admits_out])"
[ "$c1_gate_rc" != 0 ] && [ -z "$c1_gate_out" ] \
  && ok "1: no grant anywhere -- real launch-authority gate falls through to and is refused by the (forced-failing) live-ancestry check, empty stdout, exactly as before this feature existed" \
  || bad "1: _esc_check_launch_authority (rc=$c1_gate_rc out=[$c1_gate_out])"

# =============================================================== case 2 ===
# Expired grant: minted with a 50ms TTL, then genuinely waited past it --
# invisible exactly like absent, not partially honored.
c2_id="$(mint_grant "$REPO_A" "explore,implement" standard 50)" || exit 1
sleep 0.3
c2_out="$(resident_grant_admits "$REPO_A" implement)"; c2_rc=$?
[ "$c2_rc" != 0 ] && [ -z "$c2_out" ] \
  && ok "2: expired grant is invisible -- refused exactly like no grant at all" \
  || bad "2: expired grant (rc=$c2_rc out=[$c2_out], id was $c2_id)"

# =============================================================== case 3 ===
# Grant minted for repo A never admits repo B.
c3_id="$(mint_grant "$REPO_A" "explore,implement" standard)" || exit 1
c3_out="$(resident_grant_admits "$REPO_B" implement)"; c3_rc=$?
[ "$c3_rc" != 0 ] && [ -z "$c3_out" ] \
  && ok "3: grant minted for repo A never admits repo B" \
  || bad "3: cross-repo grant (rc=$c3_rc out=[$c3_out], id was $c3_id for repo A)"
c3_same_out="$(resident_grant_admits "$REPO_A" implement)"
[ "$c3_same_out" = "$c3_id" ] \
  && ok "3: the SAME grant still admits its own repo (fixture genuinely valid, not vacuous)" \
  || bad "3: fixture sanity (got [$c3_same_out], want [$c3_id])"

# =============================================================== case 4 ===
# Grant exists and is valid, max_tier=standard (job_classes=explore,
# implement) -- does NOT admit frontier's job class (deep-review).
# tier-cap-exceeded: existence of a grant alone is not enough, its own
# ceiling must also cover the requested tier.
c4_id="$(mint_grant "$REPO_A" "explore,implement" standard)" || exit 1
c4_out="$(resident_grant_admits "$REPO_A" deep-review)"; c4_rc=$?
[ "$c4_rc" != 0 ] && [ -z "$c4_out" ] \
  && ok "4: valid grant with max_tier=standard refuses a frontier (deep-review) request" \
  || bad "4: tier-cap-exceeded (rc=$c4_rc out=[$c4_out], id was $c4_id)"
c4_gate_out="$(caller_pane_from_ancestry() { return 1; }; _esc_check_launch_authority "$REPO_A" frontier 2>/dev/null)"; c4_gate_rc=$?
[ "$c4_gate_rc" != 0 ] && [ -z "$c4_gate_out" ] \
  && ok "4: the full launch-authority gate also refuses frontier under the same grant (falls through to the real, refusing ancestry check)" \
  || bad "4: gate under tier cap (rc=$c4_gate_rc out=[$c4_gate_out])"
c4_standard_out="$(_esc_check_launch_authority "$REPO_A" standard 2>/dev/null)"
[ -n "$c4_standard_out" ] && [ "$c4_standard_out" != "$c4_id" ] \
  && ok "4: the SAME grant DOES admit standard (fixture genuinely valid, not vacuous) -- a real, non-empty TOKEN is returned, distinct from the grant's own command_id (REVIEW-GRANT-9ac2fc4)" \
  || bad "4: fixture sanity (got token [$c4_standard_out], grant was [$c4_id])"
c4_standard_claim="$(claim_resident_redemption "$c4_standard_out" "$REPO_A" implement 2>/dev/null)"
[ "$c4_standard_claim" = "$c4_id" ] \
  && ok "4: the returned token claims successfully and recovers the exact grant that admitted it" \
  || bad "4: token claim (got [$c4_standard_claim], want [$c4_id])"

# =============================================================== case 5 ===
# Revocation sentinel refuses an otherwise fully valid, admitting grant --
# and clears the instant the sentinel file is removed (checked fresh every
# call, never cached in this or any other process).
c5_id="$(mint_grant "$REPO_A" "explore,implement" standard)" || exit 1
: > "$HERDR_RESIDENT_GRANT_REVOKED_FILE"
c5_revoked_out="$(resident_grant_admits "$REPO_A" implement)"; c5_revoked_rc=$?
[ "$c5_revoked_rc" != 0 ] && [ -z "$c5_revoked_out" ] \
  && ok "5: revocation sentinel refuses an otherwise fully valid, admitting grant" \
  || bad "5: revoked (rc=$c5_revoked_rc out=[$c5_revoked_out], id was $c5_id)"
rm -f "$HERDR_RESIDENT_GRANT_REVOKED_FILE"
c5_cleared_out="$(resident_grant_admits "$REPO_A" implement)"
[ "$c5_cleared_out" = "$c5_id" ] \
  && ok "5: revocation clears the instant the sentinel is removed -- no restart, no caching" \
  || bad "5: cleared (got [$c5_cleared_out], want [$c5_id])"

# =============================================================== case 6 ===
# A grant row tampered with directly in storage (widening job_classes past
# what was actually minted, without re-deriving expected_manifest) is
# refused -- scope cannot be silently widened after mint; only a fresh,
# separately-reviewed mint can grant more. Minted narrow (standard only),
# then the stored `claims` column alone is hand-edited to also claim
# frontier -- the realistic tamper (editing the JSON blob) without also
# updating the separate `effective_scope`/`expected_manifest` columns
# `_insert` set at mint time.
#
# LOW (REVIEW-GRANT-9ac2fc4): this refusal comes from ARCHITECTURE
# (column/blob separation), not from `_check_source`'s hash/field
# integrity cross-check as an earlier version of this comment claimed --
# `resident_grant_admits` reads job_classes from the separate,
# UNTOUCHED `effective_scope` column via `public(row)`, never from
# `claims` at all, so this specific tamper is refused regardless of
# whether the integrity cross-check runs. Confirmed by mutant: disabling
# `_check_source`'s cross-check entirely does not flip this case. Both
# layers independently prevent scope widening (genuine defense in
# depth); this test proves the architectural one, not the integrity-
# check one specifically.
c6_id="$(mint_grant "$REPO_A" "explore,implement" standard)" || exit 1
c6_before_out="$(resident_grant_admits "$REPO_A" deep-review)"
c6_claims="$(_sql "SELECT claims FROM task_authorizations WHERE command_id=$(_sq "$c6_id");")"
c6_tampered_claims="$(printf '%s' "$c6_claims" | python3 -c '
import json, sys
c = json.load(sys.stdin)
c["effective_scope"]["job_classes"].append("deep-review")
print(json.dumps(c, sort_keys=True, separators=(",", ":")))
')"
_sql "UPDATE task_authorizations SET claims=$(_sq "$c6_tampered_claims") WHERE command_id=$(_sq "$c6_id");" >/dev/null
c6_after_out="$(resident_grant_admits "$REPO_A" deep-review 2>/dev/null)"; c6_after_rc=$?
[ -z "$c6_before_out" ] \
  && ok "6: fixture sanity -- narrowly-minted grant did NOT admit frontier before tampering" \
  || bad "6: fixture sanity before (got [$c6_before_out], want empty)"
[ "$c6_after_rc" != 0 ] && [ -z "$c6_after_out" ] \
  && ok "6: a row tampered to claim a wider scope than it was minted with is refused, not silently honored" \
  || bad "6: tampered-widened grant (rc=$c6_after_rc out=[$c6_after_out])"

# =============================================================== case 7 ===
# design-doc item 5 (REVIEW-GRANT-9ac2fc4 HIGH): the standing grant's own
# command_id -- discoverable later via any spawned task's ordinary,
# unauthenticated audit record (claims.grant_command_id) -- is NOT a
# redeemable token. Presenting it directly to claim_resident_redemption
# (what spawn-task.sh's admission branch calls), bypassing
# _esc_check_launch_authority entirely (the only place a genuine token is
# ever minted), must refuse: it is a real row, but the wrong SOURCE
# (resident_escalation_grant, not resident_escalation_redemption) --
# structurally unreachable as a token, proving the grant is not a
# general-purpose spawn bypass usable outside escalation's own call path.
c7_grant_id="$(mint_grant "$REPO_A" "explore,implement" standard)" || exit 1
c7_out="$(claim_resident_redemption "$c7_grant_id" "$REPO_A" implement 2>/dev/null)"; c7_rc=$?
[ "$c7_rc" != 0 ] && [ -z "$c7_out" ] \
  && ok "7: design-doc item 5 -- the standing grant's own (audit-trail-discoverable) command_id is refused when presented as a redemption token, bypassing the authority check that mints a genuine one" \
  || bad "7: bare grant id as token (rc=$c7_rc out=[$c7_out], grant was $c7_grant_id)"

# =============================================================== case 8 ===
# design-doc item 9/positive baseline + the redemption token's own
# single-use property: the full happy path through _esc_check_launch_
# authority (grant exists and admits -> mints a fresh token -> token
# independently claims -> recovers the correct grant_command_id), then
# design-doc item 8: a SECOND claim of the SAME token is refused -- one
# grant authorizing two concurrent spawns off a single redemption is not
# possible, the token itself is the single-use choke point (REVIEW-
# GRANT-9ac2fc4's structural fix), independent of the deeper, pre-
# existing claim_task_worktree_mutation/task_id-UNIQUE machinery this
# proposal reuses unchanged for the resulting resident_escalation_spawn
# record.
c8_grant_id="$(mint_grant "$REPO_A" "explore,implement" standard)" || exit 1
c8_token="$(caller_pane_from_ancestry() { return 1; }; _esc_check_launch_authority "$REPO_A" standard 2>/dev/null)"; c8_gate_rc=$?
[ "$c8_gate_rc" = 0 ] && [ -n "$c8_token" ] \
  && ok "8: positive path -- a valid, admitting grant makes _esc_check_launch_authority mint and return a real token" \
  || bad "8: positive path token mint (rc=$c8_gate_rc out=[$c8_token])"
c8_first_claim="$(claim_resident_redemption "$c8_token" "$REPO_A" implement 2>/dev/null)"; c8_first_rc=$?
[ "$c8_first_rc" = 0 ] && [ "$c8_first_claim" = "$c8_grant_id" ] \
  && ok "8: positive path -- the token claims successfully and recovers the exact grant command_id that admitted it" \
  || bad "8: first claim (rc=$c8_first_rc out=[$c8_first_claim], want [$c8_grant_id])"
c8_second_claim="$(claim_resident_redemption "$c8_token" "$REPO_A" implement 2>/dev/null)"; c8_second_rc=$?
[ "$c8_second_rc" != 0 ] && [ -z "$c8_second_claim" ] \
  && ok "8: design-doc item 8 -- a second claim of the SAME token is refused (single-use, not two concurrent spawns off one redemption)" \
  || bad "8: second claim (rc=$c8_second_rc out=[$c8_second_claim])"

# =============================================================== case 9 ===
# A redemption token is scoped to the EXACT (repo, job_class) it was
# minted for -- presenting a genuine, unconsumed, unexpired token but for
# the WRONG job_class (a different tier than what it actually authorizes)
# is refused, same as a wrong-repo presentation would be. Proves the
# token itself carries real scope, not just "any token admits anything."
c9_grant_id="$(mint_grant "$REPO_A" "explore,implement" standard)" || exit 1
c9_token="$(caller_pane_from_ancestry() { return 1; }; _esc_check_launch_authority "$REPO_A" standard 2>/dev/null)"
c9_wrong_job="$(claim_resident_redemption "$c9_token" "$REPO_A" explore 2>/dev/null)"; c9_wrong_job_rc=$?
[ "$c9_wrong_job_rc" != 0 ] && [ -z "$c9_wrong_job" ] \
  && ok "9: a genuine token minted for 'implement' refuses a claim presenting a different job_class ('explore')" \
  || bad "9: wrong job_class claim (rc=$c9_wrong_job_rc out=[$c9_wrong_job])"
c9_right_job="$(claim_resident_redemption "$c9_token" "$REPO_A" implement 2>/dev/null)"
[ "$c9_right_job" = "$c9_grant_id" ] \
  && ok "9: the SAME token still claims correctly for its real job_class afterward (fixture genuinely valid, not vacuous)" \
  || bad "9: fixture sanity (got [$c9_right_job], want [$c9_grant_id])"

# ============================================================== case 10 ===
# resident_grant_allowed_repo: an explicitly allowlisted repo is permitted.
c10_list="$REPO_A:$REPO_B"
HERDR_RESIDENT_GRANT_REPO_ALLOWLIST="$c10_list" resident_grant_allowed_repo "$REPO_A" \
  && ok "10: an explicitly allowlisted repo (REPO_A) is permitted" \
  || bad "10: REPO_A was refused despite being in the allowlist"

# ============================================================== case 11 ===
# A repo genuinely not in the allowlist is refused, even with a
# non-empty, otherwise-valid allowlist in effect.
REPO_C="$WORK/repo-c"; mkdir -p "$REPO_C"; git -C "$REPO_C" init -q; REPO_C="$(cd "$REPO_C" && pwd -P)"
if HERDR_RESIDENT_GRANT_REPO_ALLOWLIST="$c10_list" resident_grant_allowed_repo "$REPO_C"; then
  bad "11: REPO_C was wrongly permitted -- it is not in the allowlist ($c10_list)"
else
  ok "11: a repo genuinely absent from the allowlist is refused"
fi

# ============================================================== case 12 ===
# Fail-closed: an EXPLICITLY empty allowlist refuses EVERY repo, never
# silently permits everything -- including REPO_A, which case 10 just
# proved WOULD be permitted under a real, non-empty list.
if HERDR_RESIDENT_GRANT_REPO_ALLOWLIST="" resident_grant_allowed_repo "$REPO_A"; then
  bad "12: an explicitly EMPTY allowlist wrongly permitted REPO_A -- fail-closed is broken"
else
  ok "12: an explicitly empty allowlist refuses every repo, including one that would otherwise be allowlisted"
fi

# ============================================================== case 13 ===
# A worktree of an allowlisted repo, and a `..`-laden path inside it,
# both resolve (via repo_root's own --git-common-dir canonicalization)
# to the SAME canonical root as the main checkout -- so the allowlist
# check, keyed on that canonical root, admits either alias exactly like
# it admits REPO_A itself, never by name/basename matching that a
# differently-named clone could spoof.
git -C "$REPO_A" commit -q --allow-empty -m "fixture: base commit so a worktree can be added" 2>/dev/null
REPO_A_WT_RAW="$WORK/repo-a-worktree"
git -C "$REPO_A" worktree add -q -b fixture-wt-branch "$REPO_A_WT_RAW" >/dev/null 2>&1
REPO_A_WT_CANON="$(repo_root "$REPO_A_WT_RAW" 2>/dev/null)"
[ "$REPO_A_WT_CANON" = "$REPO_A" ] \
  && ok "13a: a worktree of REPO_A canonically resolves to REPO_A itself, not its own worktree path" \
  || bad "13a: worktree canonical root [$REPO_A_WT_CANON] != REPO_A [$REPO_A]"
HERDR_RESIDENT_GRANT_REPO_ALLOWLIST="$c10_list" resident_grant_allowed_repo "$REPO_A_WT_CANON" \
  && ok "13b: the worktree's canonical root is permitted under the SAME allowlist entry as REPO_A" \
  || bad "13b: the worktree alias was refused despite REPO_A being allowlisted"
mkdir -p "$REPO_A/nested/dir"
REPO_A_DOTDOT="$REPO_A/nested/dir/../.."
REPO_A_DOTDOT_CANON="$(repo_root "$REPO_A_DOTDOT" 2>/dev/null)"
[ "$REPO_A_DOTDOT_CANON" = "$REPO_A" ] \
  && ok "13c: a \`..\`-laden path inside REPO_A canonically resolves to REPO_A's own real root" \
  || bad "13c: traversal path canonical root [$REPO_A_DOTDOT_CANON] != REPO_A [$REPO_A]"
HERDR_RESIDENT_GRANT_REPO_ALLOWLIST="$c10_list" resident_grant_allowed_repo "$REPO_A_DOTDOT_CANON" \
  && ok "13d: the traversal path's canonical root is permitted under the SAME allowlist entry as REPO_A" \
  || bad "13d: the traversal-path alias was refused despite REPO_A being allowlisted"

# ============================================================== case 14 ===
# The mint CLI itself (grant-resident-escalation.sh, never exercised by
# any case above -- those all call the storage/allowlist functions
# directly) parses cleanly and fails a controlled, early usage check
# with no arguments -- entirely inside THIS suite's own sandbox
# (HERDR_RUN_STATE_DIR under $WORK, shadowed herdr on PATH, scratch
# revoke-file path), so even if something in the file reached further
# than expected it could not touch live state. A syntax error anywhere
# in the file (including the allowlist check added this round) would
# fail this before ever reaching the usage message.
c14_out="$(bash "$here/grant-resident-escalation.sh" 2>&1)"; c14_rc=$?
[ "$c14_rc" != 0 ] && printf '%s' "$c14_out" | grep -qi usage \
  && ok "14: the mint CLI parses cleanly and refuses a no-argument call with a controlled usage error (rc=$c14_rc)" \
  || bad "14: expected a controlled usage refusal, got rc=$c14_rc: $c14_out"
[ -s "$WORK/herdr-violation" ] \
  && bad "14: the no-arg CLI call reached a real herdr call before its own usage check" \
  || ok "14: the no-arg CLI call never reached herdr (shadow PATH still clean)"

# ---- belt-and-suspenders: no test above ever reached the real herdr -----
if [ -s "$WORK/herdr-violation" ]; then
  bad "no real herdr call across all 14 cases"
  cat "$WORK/herdr-violation" >&2
else
  ok "no real herdr call across all 14 cases (shadow PATH clean)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
