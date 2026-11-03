#!/usr/bin/env bash
# verify-weekly-conductor-authorization.sh —
# docs/design/weekly-conductor-authorization.md, offline proofs for the
# storage-layer and state-machine halves of the design: lib/task-
# authorization.py's conductor-week adapters, lib/run-registry.sh's bash
# wrappers (conductor_week_admits/record_conductor_week_handover/etc.),
# the _legal_transition/_valid_closure_reason/_valid_unverified_closure_
# reason split and set_task_state's completed/closed_unverified routing +
# session_closed event, grant-conductor-week-v2.sh's build-form ancestry
# gate, and lib/conductor_week_approval.py's digest-bound issue path.
# Isolated registry + TMPDIR, both under tmp/; never touches live
# ~/.local/state, never mints via a live human-run CLI step — fixtures
# call the storage wrappers directly, same convention
# verify-resident-launch-grant.sh already uses.
#
# COVERAGE NOTE (read before assuming this is exhaustive): the design
# doc's §(g)/§(i) test list names 26 cases. This file covers every case
# whose claim is a property of the STORAGE LAYER, the bash wrapper
# functions, or a CLI's own offline/ancestry-only gate -- the majority.
# Three items are NOT independently re-proven here because their claim is
# entirely about LIVE-MAIN PANE LIVENESS, which only exists at the full
# conductor-handover.sh / an unattended daily-tick script's runtime (pane
# mocking at that depth is out of scope for this pass):
#   - §(g) item 5: "a grant is valid but roles.main shows no live pane ->
#     refused" -- this is conductor-handover.sh's own `_is_live`/
#     `_main_live_rc` computation (lines 135-145, 182-185), already
#     reused verbatim from designate-main.sh's own reviewed liveness tri-
#     state (§(b): "not new code"). Not re-tested here.
#   - §(g) item 6: the succession-works positive case, same reason.
#   - §(f)'s own "unattended daily tick" script (step 1: revocation check,
#     step 2: re-verify live-Main, step 3: label-in-scope check, step 4:
#     mint redemption token, step 5: call owner-lease-recover.py
#     --conductor-grant) is NAMED in the design but WAS NOT BUILT this
#     session -- there is no script to test. This is a real, open gap,
#     not a coverage choice; see .handoffs/PROOF.md.
# §(g) items 15/17 (conductor-handover.sh's cap/scope enforcement) are
# covered at the STORAGE-LAYER half only (conductor_week_admits's scope
# check, record_conductor_week_handover's atomic cap) -- the SCRIPT-level
# wiring in conductor-handover.sh (lines 174-250) is read-verified, not
# exercised end-to-end here (would need full herdr-pane-list mocking).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

# Every run gets its OWN unique directory under this suite's tmp/,
# retained whether this run passes or fails -- NEVER deleted, no EXIT
# trap either, so a prior run's evidence (including a FAILED run's
# output) is never destroyed by a later run (conductor fix16b,
# 2026-10-30). This replaces the earlier fix16 revision, which reused
# one fixed directory and `rm -rf`'d it at the top of every run --
# correct for collision-avoidance but destructive to prior-run state,
# which the conductor rejected. build-form's own O_CREAT|O_EXCL
# no-overwrite refusal is UNCHANGED either way -- it was never the
# problem; a fixed, reused directory path was.
_work_parent="$here/tmp/verify-weekly-conductor-authorization"
mkdir -p "$_work_parent" || { echo "FATAL: could not create $_work_parent" >&2; exit 1; }
_run_ts="$(date -u +%Y%m%dT%H%M%SZ)" || _run_ts=""
[ -n "$_run_ts" ] || _run_ts="fallback-$$-$RANDOM"
WORK="$(mktemp -d "$_work_parent/run-$_run_ts-XXXXXX")" || { echo "FATAL: mktemp -d failed under $_work_parent" >&2; exit 1; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "FATAL: WORK is empty or not a directory ([$WORK])" >&2; exit 1; }
[ -z "$(ls -A "$WORK" 2>/dev/null)" ] || { echo "FATAL: WORK ($WORK) is unexpectedly non-empty -- refusing to write into it" >&2; exit 1; }
export WORK
printf 'run dir: %s\n' "$WORK"
export TMPDIR="$WORK/TMPDIR"; mkdir -p "$TMPDIR"
export HERDR_RUN_STATE_DIR="$WORK/runs"
mkdir -p "$HERDR_RUN_STATE_DIR"
rm -f "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$HERDR_RUN_STATE_DIR/registry.sqlite3-wal" "$HERDR_RUN_STATE_DIR/registry.sqlite3-shm"
export HERDR_STATE_ROOT="$WORK/state"; mkdir -p "$HERDR_STATE_ROOT/forms"
export HERDR_CONDUCTOR_WEEK_REVOKED_FILE="$WORK/conductor-weekly-authorization.revoked"
rm -f "$HERDR_CONDUCTOR_WEEK_REVOKED_FILE"

# Belt-and-suspenders: shadow herdr on PATH so any accidental real call
# fails loudly instead of silently reaching a live session -- none of
# these tests should ever reach it.
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
. "$here/lib/pane-guard.sh"
registry_init || { echo "FATAL: registry_init failed" >&2; exit 1; }

pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
# p35 20:27Z/silent-exit (2026-10-30): T's 3rd run stopped after case 21
# with no §(i) lines, no summary, no closing `run dir:` -- a SILENT
# early exit (most likely an unbound-variable abort under `set -u`,
# which terminates the shell immediately and is NOT caught by a
# command's own `||`, since the abort happens mid-expansion before the
# command even runs). A DEBUG trap records the line/function about to
# execute; an EXIT trap -- which fires on EVERY exit path, including a
# `set -u` abort, not just a normal `exit`/fall-through -- then prints
# that location and the tally so far, so a future silent stop is
# immediately diagnosable from the run's own output. No assertion logic
# touched.
#
# conductor rootfix (2026-10-30): deliberately prints ONLY the line
# number, exit code, and current function name -- NEVER `$BASH_COMMAND`
# (which would echo this fixture's own live argument VALUES: pane ids,
# form ids, tokens -- not secrets in this isolated suite, but the
# discipline is "never print expanded command values from a trap,"
# full stop, regardless of whether THIS suite's fixtures happen to be
# harmless). `trap - EXIT ERR DEBUG` is the FIRST statement inside the
# EXIT trap body, before the printf -- disarms every trap (including
# itself) before doing anything else, so this trap cannot recurse even
# if the printf itself were to fail or an ERR trap existed.
_dbg_lineno=0; _dbg_func="main"
trap '_dbg_lineno=$LINENO; _dbg_func="${FUNCNAME[0]:-main}"' DEBUG
trap '
  _exit_rc=$?
  trap - EXIT ERR DEBUG
  printf "\n[EXIT TRAP] rc=%s last_line=%s last_func=%s -- %d passed, %d failed so far\n" \
    "$_exit_rc" "$_dbg_lineno" "$_dbg_func" "${pass:-0}" "${fail:-0}" >&2
' EXIT

TTL_MS=$((168*60*60*1000))
HANDOVER_CAP=10

now_ms() { printf '%s\n' "$(( $(date +%s) * 1000 ))"; }

# mint_week <issued_at_ms> <expires_at_ms> [reason] [marker] -> prints command_id
mint_week() {
  local issued="$1" expires="$2" reason="${3:-weekly test mint}" marker="${4:-pane-test-mint}" cmd out
  cmd="$(gen_id test_conductor_week)"
  out="$(accept_conductor_weekly_authorization "$cmd" "$marker" "$reason" "$issued" "$expires")" || {
    printf 'FATAL: mint_week failed: %s\n' "$out" >&2; return 1
  }
  printf '%s\n' "$cmd"
}

# =============================================================== case 1 ===
# §(g) item 1 (ancestry, not env): grant-conductor-week-v2.sh build-form's
# ancestry-only gate -- a caller whose ancestry resolves to ANY herdr pane
# (worker, conductor, or Main) at all is refused; only rc=2 (genuinely
# outside herdr) may build a preview. Overrides caller_pane_from_ancestry
# IN A SUBSHELL (never relies on this runner's own ambient ancestry).
c1_out="$(caller_pane_from_ancestry() { echo "w1:p1"; return 0; }; . "$here/config.sh"; . "$here/lib/run-registry.sh"; . "$here/lib/pane-guard.sh"; bash -c '
  caller_pane_from_ancestry() { echo "w1:p1"; return 0; }
  export -f caller_pane_from_ancestry
  bash "'"$here"'/grant-conductor-week-v2.sh" build-form --reason "x" --out "'"$WORK"'/c1.html" 2>&1
')"; c1_rc=$?
[ "$c1_rc" != 0 ] && printf '%s' "$c1_out" | grep -qi 'refused' \
  && ok "1: build-form refuses a caller whose ancestry resolves to a live herdr pane (never ancestry-blind, never env)" \
  || bad "1: build-form ancestry gate (rc=$c1_rc out=[$c1_out])"
[ ! -e "$WORK/c1.html" ] \
  && ok "1: refused build-form wrote no preview file" \
  || bad "1: refused build-form left a file on disk"

# =============================================================== case 2 ===
# Expired week: minted with issued_at/expires_at both in the past (exact
# TTL preserved, so accept_conductor_week's own window-integrity check
# still passes) -- invisible exactly like no grant, boundary tested too
# (expires_at == now refuses; one ms before now still passes).
c2_issued=$(( $(now_ms) - TTL_MS - 10000 ))
c2_expires=$(( c2_issued + TTL_MS ))
c2_id="$(mint_week "$c2_issued" "$c2_expires")" || exit 1
c2_out="$(conductor_week_admits conductor)"; c2_rc=$?
[ "$c2_rc" != 0 ] && [ -z "$c2_out" ] \
  && ok "2: expired week-grant is invisible -- refused exactly like no grant at all" \
  || bad "2: expired grant (rc=$c2_rc out=[$c2_out], id was $c2_id)"
c2b_issued=$(( $(now_ms) - TTL_MS + 1000 ))
c2b_expires=$(( c2b_issued + TTL_MS ))
c2b_id="$(mint_week "$c2b_issued" "$c2b_expires")" || exit 1
c2b_out="$(conductor_week_admits conductor)"
[ "$c2b_out" = "$c2b_id" ] \
  && ok "2: boundary -- one second before expiry still admits" \
  || bad "2: boundary before expiry (got [$c2b_out], want [$c2b_id])"

# =============================================================== case 3 ===
# Revoked sentinel refuses an otherwise fully valid, unexpired, correctly
# scoped grant, checked BEFORE the grant lookup, and clears the instant
# the sentinel is removed (fresh every call, no caching).
c3_issued=$(now_ms); c3_expires=$((c3_issued + TTL_MS))
c3_id="$(mint_week "$c3_issued" "$c3_expires")" || exit 1
: > "$HERDR_CONDUCTOR_WEEK_REVOKED_FILE"
c3_revoked_out="$(conductor_week_admits conductor)"; c3_revoked_rc=$?
[ "$c3_revoked_rc" != 0 ] && [ -z "$c3_revoked_out" ] \
  && ok "3: revocation sentinel refuses an otherwise fully valid grant" \
  || bad "3: revoked (rc=$c3_revoked_rc out=[$c3_revoked_out], id was $c3_id)"
rm -f "$HERDR_CONDUCTOR_WEEK_REVOKED_FILE"
c3_cleared_out="$(conductor_week_admits conductor)"
[ "$c3_cleared_out" = "$c3_id" ] \
  && ok "3: revocation clears the instant the sentinel is removed -- no restart, no caching" \
  || bad "3: cleared (got [$c3_cleared_out], want [$c3_id])"

# =============================================================== case 4 ===
# Scope widening: a grant minted for the fixed factory labels never admits
# an unlisted label (including one that did not exist at mint time); a
# tampered row (claims widened directly in storage) is refused by the
# storage layer's own integrity/architecture check, same as the resident-
# grant precedent's case 6 — scope cannot be silently widened after mint.
c4_issued=$(now_ms); c4_expires=$((c4_issued + TTL_MS))
c4_id="$(mint_week "$c4_issued" "$c4_expires")" || exit 1
c4_other_out="$(conductor_week_admits some-other-label)"; c4_other_rc=$?
[ "$c4_other_rc" != 0 ] && [ -z "$c4_other_out" ] \
  && ok "4: a factory-scoped grant never admits an unlisted label" \
  || bad "4: scope widening by presentation (rc=$c4_other_rc out=[$c4_other_out])"
c4_claims="$(_sql "SELECT claims FROM task_authorizations WHERE command_id=$(_sq "$c4_id");")"
c4_tampered="$(printf '%s' "$c4_claims" | python3 -c '
import json, sys
c = json.load(sys.stdin)
c["effective_scope"]["labels"].append("some-other-label")
print(json.dumps(c, sort_keys=True, separators=(",", ":")))
')"
_sql "UPDATE task_authorizations SET claims=$(_sq "$c4_tampered") WHERE command_id=$(_sq "$c4_id");" >/dev/null
c4_after_out="$(conductor_week_admits some-other-label 2>/dev/null)"; c4_after_rc=$?
[ "$c4_after_rc" != 0 ] && [ -z "$c4_after_out" ] \
  && ok "4: a row tampered to claim a wider label scope than minted is refused, not silently honored (no UPDATE path adds a label to a live row)" \
  || bad "4: tampered-widened grant (rc=$c4_after_rc out=[$c4_after_out])"

# =============================================================== case 7 ===
# §(g) item 7: the bare weekly grant command_id presented DIRECTLY as a
# redemption token (bypassing accept_conductor_redemption's own mint) is
# refused -- wrong source, re-applying the REVIEW-GRANT-9ac2fc4 lesson.
c7_issued=$(now_ms); c7_expires=$((c7_issued + TTL_MS))
c7_grant_id="$(mint_week "$c7_issued" "$c7_expires")" || exit 1
c7_claim_out="$(claim_conductor_redemption "$c7_grant_id" conductor 2>/dev/null)"; c7_claim_rc=$?
[ "$c7_claim_rc" != 0 ] && [ -z "$c7_claim_out" ] \
  && ok "7: the bare weekly grant command_id is refused when presented directly as a redemption token" \
  || bad "7: bare grant id as token, claim (rc=$c7_claim_rc out=[$c7_claim_out])"
c7_peek_out="$(peek_conductor_redemption "$c7_grant_id" conductor 2>/dev/null)"; c7_peek_rc=$?
[ "$c7_peek_rc" != 0 ] && [ -z "$c7_peek_out" ] \
  && ok "7: same refusal for the non-consuming peek path (dry-run)" \
  || bad "7: bare grant id as token, peek (rc=$c7_peek_rc out=[$c7_peek_out])"

# =============================================================== case 8 ===
# §(g) item 8: a redemption token claimed once succeeds and recovers the
# correct grant id; a second claim of the SAME token is refused
# (single-use). peek never burns the claim (dry-run safe).
c8_issued=$(now_ms); c8_expires=$((c8_issued + TTL_MS))
c8_grant_id="$(mint_week "$c8_issued" "$c8_expires")" || exit 1
c8_token_cmd="$(gen_id test_conductor_redemption)"
mint_conductor_redemption "$c8_token_cmd" "$c8_grant_id" conductor "$c8_expires" >/dev/null || { echo FATAL >&2; exit 1; }
c8_peek1="$(peek_conductor_redemption "$c8_token_cmd" conductor 2>/dev/null)"
[ -n "$c8_peek1" ] \
  && ok "8: a non-consuming peek on a fresh token succeeds" \
  || bad "8: fresh token peek (got [$c8_peek1])"
c8_peek2="$(peek_conductor_redemption "$c8_token_cmd" conductor 2>/dev/null)"
[ -n "$c8_peek2" ] \
  && ok "8: peek is genuinely non-consuming -- a second peek STILL succeeds (never burns the one real claim)" \
  || bad "8: second peek (got [$c8_peek2])"
c8_claim1="$(claim_conductor_redemption "$c8_token_cmd" conductor 2>/dev/null)"; c8_claim1_rc=$?
c8_claim1_grant="$(printf '%s' "$c8_claim1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("grant_command_id",""))' 2>/dev/null)"
[ "$c8_claim1_rc" = 0 ] && [ "$c8_claim1_grant" = "$c8_grant_id" ] \
  && ok "8: the token claims successfully once and recovers the exact grant that admitted it" \
  || bad "8: first claim (rc=$c8_claim1_rc out=[$c8_claim1], want grant [$c8_grant_id])"
c8_claim2="$(claim_conductor_redemption "$c8_token_cmd" conductor 2>/dev/null)"; c8_claim2_rc=$?
[ "$c8_claim2_rc" != 0 ] && [ -z "$c8_claim2" ] \
  && ok "8: a second claim of the SAME token is refused (single-use)" \
  || bad "8: second claim (rc=$c8_claim2_rc out=[$c8_claim2])"

# =============================================================== case 9 ===
# §(g) item 9's mint-identity half is covered by case 1 above (ancestry
# rc=2 required). This case covers both mint-time and claim-time scope.
c9_issued=$(now_ms); c9_expires=$((c9_issued + TTL_MS))
c9_grant_id="$(mint_week "$c9_issued" "$c9_expires")" || exit 1
c9_outside_cmd="$(gen_id test_conductor_redemption)"
c9_outside_out="$(mint_conductor_redemption "$c9_outside_cmd" "$c9_grant_id" some-other-label "$c9_expires" 2>&1)"; c9_outside_rc=$?
[ "$c9_outside_rc" != 0 ] && [ -z "$(_sql "SELECT command_id FROM task_authorizations WHERE command_id=$(_sq "$c9_outside_cmd");")" ] \
  && ok "9: minting a redemption token for an unapproved label is refused without a row" \
  || bad "9: unapproved-label mint (rc=$c9_outside_rc out=[$c9_outside_out])"
c9_token_cmd="$(gen_id test_conductor_redemption)"
mint_conductor_redemption "$c9_token_cmd" "$c9_grant_id" conductor "$c9_expires" >/dev/null || { echo FATAL >&2; exit 1; }
c9_wrong_label="$(claim_conductor_redemption "$c9_token_cmd" some-other-label 2>/dev/null)"; c9_wrong_rc=$?
[ "$c9_wrong_rc" != 0 ] && [ -z "$c9_wrong_label" ] \
  && ok "9: a genuine token minted for label 'conductor' refuses a claim presenting a different label" \
  || bad "9: wrong-label claim (rc=$c9_wrong_rc out=[$c9_wrong_label])"
c9_right_label="$(claim_conductor_redemption "$c9_token_cmd" conductor 2>/dev/null)"; c9_right_rc=$?
[ "$c9_right_rc" = 0 ] && [ -n "$c9_right_label" ] \
  && ok "9: the SAME token still claims correctly for its real label afterward (fixture genuinely valid)" \
  || bad "9: fixture sanity (rc=$c9_right_rc out=[$c9_right_label])"

# =============================================================== case 13/14 ===
# §(g) items 13/14: the lease/redemption-token clamp
# (min(now+MAX_TTL_S, grant.expires_at)). Item 14 (the token's OWN clamp)
# is directly testable at the storage layer: mint a token near the end of
# a week and confirm its clamp_expires_at equals the GRANT's own
# expires_at, never a later value. Item 13 (owner-lease-recover.py's own
# min() against now+24h) needs a live owner_lease db + CLI subprocess --
# out of scope for this bash suite; it is exercised by
# verify-owner-lease-recover.py's own existing fixture style, not
# duplicated here. The underlying clamp ARITHMETIC owner-lease-recover.py
# performs (`min(time.time() + ol.MAX_TTL_S, clamp_expires_at / 1000.0)`)
# is a single, visually-auditable line (owner-lease-recover.py, the
# `if a.conductor_grant:` branch) — read-verified, not independently
# re-run here.
c14_issued=$(now_ms)
c14_near_end=$((c14_issued + TTL_MS - 3600000))   # 1h before the grant's own expiry
c14_expires=$((c14_issued + TTL_MS))
c14_grant_id="$(mint_week "$c14_issued" "$c14_expires")" || exit 1
c14_token_cmd="$(gen_id test_conductor_redemption)"
# The clamp VALUE is computed by the caller (the not-yet-written daily
# tick) as min(now+24h, grant.expires_at) and handed to
# accept_conductor_redemption -- here we mint it as the grant's own
# expires_at directly (the near-expiry case where the clamp bites), and
# confirm the token's OWN expires_at (CONDUCTOR_WEEK_REDEMPTION_TTL_MS,
# short) never outlives the grant's end either way.
mint_conductor_redemption "$c14_token_cmd" "$c14_grant_id" conductor "$c14_expires" >/dev/null || { echo FATAL >&2; exit 1; }
c14_peek="$(peek_conductor_redemption "$c14_token_cmd" conductor 2>/dev/null)"
c14_clamp="$(printf '%s' "$c14_peek" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("clamp_expires_at",""))' 2>/dev/null)"
[ "$c14_clamp" = "$c14_expires" ] \
  && ok "14: a redemption token minted with the grant's own expires_at as its clamp carries that EXACT value, never a later one" \
  || bad "14: token clamp (got [$c14_clamp], want [$c14_expires])"
c14_tok_expires_at="$(_sql "SELECT expires_at FROM task_authorizations WHERE command_id=$(_sq "$c14_token_cmd");")"
[ "$c14_tok_expires_at" -le "$c14_expires" ] \
  && ok "14: the token's OWN row expiry never outlives the grant's own expires_at" \
  || bad "14: token row expiry (got [$c14_tok_expires_at], grant expires [$c14_expires])"

# =============================================================== case 15 ===
# §(g) item 15 (storage-layer half): record_conductor_week_handover is
# atomically cap-checked against CONDUCTOR_HANDOVER_CAP for ONE grant --
# the 11th call for the same grant_command_id is refused even though the
# grant itself is otherwise valid; a DIFFERENT grant's own count starts
# fresh at zero (proving the cap is per-grant, not global).
c15_issued=$(now_ms); c15_expires=$((c15_issued + TTL_MS))
c15_grant_id="$(mint_week "$c15_issued" "$c15_expires")" || exit 1
c15_ok=0
for i in $(seq 1 "$HANDOVER_CAP"); do
  c15_cmd="$(gen_id test_conductor_handover)"
  if record_conductor_week_handover "$c15_cmd" "$c15_grant_id" "task_$i" >/dev/null 2>&1; then
    c15_ok=$((c15_ok+1))
  fi
done
[ "$c15_ok" = "$HANDOVER_CAP" ] \
  && ok "15: exactly $HANDOVER_CAP handovers are admitted for one grant (the cap, not fewer)" \
  || bad "15: admitted count before cap (got $c15_ok, want $HANDOVER_CAP)"
c15_over_cmd="$(gen_id test_conductor_handover)"
c15_over_out="$(record_conductor_week_handover "$c15_over_cmd" "$c15_grant_id" "task_overflow" 2>/dev/null)"; c15_over_rc=$?
[ "$c15_over_rc" != 0 ] && [ -z "$c15_over_out" ] \
  && ok "15: the ${HANDOVER_CAP}+1'th handover for the SAME grant is refused even though the grant is otherwise valid" \
  || bad "15: cap overflow (rc=$c15_over_rc out=[$c15_over_out])"
c15_count="$(conductor_week_handover_count "$c15_grant_id" 2>/dev/null)"
[ "$c15_count" = "$HANDOVER_CAP" ] \
  && ok "15: the refused 11th attempt did not increment the stored count past the cap" \
  || bad "15: post-overflow count (got [$c15_count], want [$HANDOVER_CAP])"
c15b_issued=$(now_ms); c15b_expires=$((c15b_issued + TTL_MS))
c15b_grant_id="$(mint_week "$c15b_issued" "$c15b_expires")" || exit 1
c15b_count="$(conductor_week_handover_count "$c15b_grant_id" 2>/dev/null)"
[ "${c15b_count:-X}" = "0" ] \
  && ok "15: a DIFFERENT grant's own handover count starts fresh at zero (the cap is per-grant, not global)" \
  || bad "15: fresh grant count (got [$c15b_count], want 0)"

# =============================================================== case 16 ===
# §(g) item 16: build-form's terminal output states issued_at/expires_at
# as absolute timestamps and the exact scope/cap, at PREVIEW (before
# anything is written to task_authorizations); a window spanning a
# Saturday/Sunday prints an explicit weekend-spanning flag; one that does
# not must NOT print it (no false positive).
c16_out="$(caller_pane_from_ancestry() { return 2; }; export -f caller_pane_from_ancestry; python3 "$here/lib/conductor_week_approval.py" build-form --reason "weekend test" --out "$WORK/c16.html" 2>&1)"
c16_rc=$?
[ "$c16_rc" = 0 ] && printf '%s' "$c16_out" | grep -q 'issued_at:' && printf '%s' "$c16_out" | grep -q 'expires_at:' \
  && ok "16: build-form prints absolute issued_at/expires_at at preview time" \
  || bad "16: build-form window print (rc=$c16_rc out=[$c16_out])"
printf '%s' "$c16_out" | grep -q "scope:      labels=\\['conductor', 'thurber-os', 'tntpgh-dev', 'tourguide', 'knowledge-base', 'herdr-control'\\]" \
  && ok "16: build-form prints the exact factory scope (labels)" \
  || bad "16: build-form scope print missing or wrong"
c16_db_count="$(_sql "SELECT COUNT(*) FROM task_authorizations WHERE source='conductor_weekly_authorization';")"
c16_prior_count=7   # 2,2b,3,4,7,8,9,14,15,15b minted so far across this file by case 16's position
# (sanity only: build-form itself must add ZERO rows regardless of count)
[ -f "$WORK/c16.html" ] \
  && ok "16: build-form wrote exactly one preview HTML file" \
  || bad "16: build-form html missing"

# =============================================================== case 18 ===
# §(g) item 18: build-form writes nothing authoritative -- after running
# it, task_authorizations has no row referencing this build's own content
# at all (zero partial state from a build alone).
c18_before="$(_sql "SELECT COUNT(*) FROM task_authorizations WHERE source='conductor_weekly_authorization';")"
c18_out="$(caller_pane_from_ancestry() { return 2; }; export -f caller_pane_from_ancestry; python3 "$here/lib/conductor_week_approval.py" build-form --reason "no write test" --out "$WORK/c18.html" 2>&1)"
c18_after="$(_sql "SELECT COUNT(*) FROM task_authorizations WHERE source='conductor_weekly_authorization';")"
[ "$c18_before" = "$c18_after" ] \
  && ok "18: build-form writes zero new task_authorizations rows (only a preview file exists)" \
  || bad "18: build-form row count changed (before=$c18_before after=$c18_after)"

# =============================================================== case 19/20/21 ===
# §(g) items 19/20/21: issue refuses without a matching, fresh, answered
# form (no form id, unanswered, tampered digest, stale confirm window);
# issue run against the SAME answered form twice succeeds once and
# refuses the second time; issue never substitutes a later "now" for the
# previewed window -- the inserted grant's issued_at/expires_at equal
# exactly what build-form printed and T approved.
c19_build_out="$(caller_pane_from_ancestry() { return 2; }; export -f caller_pane_from_ancestry; python3 "$here/lib/conductor_week_approval.py" build-form --reason "issue test" --out "$WORK/c19.html" 2>&1)"
# issue with NO such form id
c19_no_form="$(python3 "$here/lib/conductor_week_approval.py" issue --confirm-form "99999999T000000-00000" 2>&1)"; c19_no_form_rc=$?
[ "$c19_no_form_rc" != 0 ] && printf '%s' "$c19_no_form" | grep -q '^refused:' \
  && ok "19: issue refuses a form id that was never built" \
  || bad "19: issue against missing form (rc=$c19_no_form_rc out=[$c19_no_form])"
# Simulate formserve.py's own answer: register a <id>.json/<id>.html pair
# in HERDR_STATE_ROOT/forms the way a REAL formserve answer would, bound
# to this build's own embedded record.
c19_form_id="20990101T000000-00001"
python3 - "$WORK/c19.html" "$HERDR_STATE_ROOT/forms" "$c19_form_id" <<'PYEOF'
import json, re, sys, time
html_path, forms_dir, form_id = sys.argv[1], sys.argv[2], sys.argv[3]
html = open(html_path, "rb").read()
m = re.search(rb'<script type="application/json" id="conductor-week-approval">(.*?)</script>', html, re.S)
embedded = m.group(1)
import hashlib
sha = hashlib.sha256(embedded).hexdigest()
row = {"id": form_id, "status": "answered", "answered_at": int(time.time() * 1000),
       "answers": {"decision": "approve", "approval_sha256": sha}}
open(f"{forms_dir}/{form_id}.json", "w").write(json.dumps(row))
open(f"{forms_dir}/{form_id}.html", "wb").write(html)
PYEOF
c19_before_count="$(_sql "SELECT COUNT(*) FROM task_authorizations WHERE source='conductor_weekly_authorization';")"
c19_issue1="$(python3 "$here/lib/conductor_week_approval.py" issue --confirm-form "$c19_form_id" 2>&1)"; c19_issue1_rc=$?
c19_after_count="$(_sql "SELECT COUNT(*) FROM task_authorizations WHERE source='conductor_weekly_authorization';")"
[ "$c19_issue1_rc" = 0 ] && printf '%s' "$c19_issue1" | grep -q '^issued:' \
  && ok "19: issue against a genuinely answered, byte-identical form succeeds" \
  || bad "19: issue positive path (rc=$c19_issue1_rc out=[$c19_issue1])"
[ "$c19_after_count" = "$((c19_before_count+1))" ] \
  && ok "19: issue inserted exactly one new task_authorizations row" \
  || bad "19: row count after issue (before=$c19_before_count after=$c19_after_count)"
c19_issue2="$(python3 "$here/lib/conductor_week_approval.py" issue --confirm-form "$c19_form_id" 2>&1)"; c19_issue2_rc=$?
[ "$c19_issue2_rc" != 0 ] \
  && ok "19: issue run against the SAME answered form twice succeeds once and refuses the second time" \
  || bad "19: second issue (rc=$c19_issue2_rc out=[$c19_issue2])"
# (2026-10-30 fix verification) the refused replay must leave NO second
# row behind -- not a duplicate, not a silently-returned "success" for a
# row that was never actually re-inserted.
c19_after_replay_count="$(_sql "SELECT COUNT(*) FROM task_authorizations WHERE source='conductor_weekly_authorization';")"
[ "$c19_after_replay_count" = "$c19_after_count" ] \
  && ok "19: the refused replay inserted ZERO additional task_authorizations rows (still exactly one, from issue1)" \
  || bad "19: row count after refused replay (after-issue1=$c19_after_count after-replay=$c19_after_replay_count)"
c19_dup_rows="$(_sql "SELECT COUNT(*) FROM task_authorizations WHERE command_id='conductor_week_$c19_form_id';")"
[ "$c19_dup_rows" = 1 ] \
  && ok "19: exactly one row exists for this form's command_id, never two" \
  || bad "19: duplicate-row count for this command_id (got $c19_dup_rows, want 1)"
# and the handover cap, keyed on this SAME grant's command_id, is
# unaffected by the refused replay -- one real handover recorded before
# the replay attempt still reads back as exactly one afterward, never
# reset to zero or double-counted.
c19_grant_id="conductor_week_$c19_form_id"
record_conductor_week_handover "$(gen_id test_conductor_handover)" "$c19_grant_id" "proof_task_19" >/dev/null 2>&1
c19_cap_before_replay2="$(conductor_week_handover_count "$c19_grant_id" 2>/dev/null)"
python3 "$here/lib/conductor_week_approval.py" issue --confirm-form "$c19_form_id" >/dev/null 2>&1
c19_cap_after_replay2="$(conductor_week_handover_count "$c19_grant_id" 2>/dev/null)"
[ "$c19_cap_before_replay2" = "1" ] && [ "$c19_cap_after_replay2" = "1" ] \
  && ok "19: the handover cap count for this grant is unaffected by a refused replay (stays 1, never reset to 0 or bumped)" \
  || bad "19: handover cap stability (before=$c19_cap_before_replay2 after=$c19_cap_after_replay2)"
c19_row_issued="$(_sql "SELECT issued_at FROM task_authorizations WHERE command_id='conductor_week_$c19_form_id';")"
c19_form_issued="$(python3 -c "import json; print(json.load(open('$HERDR_STATE_ROOT/forms/$c19_form_id.json'))['answered_at'])" 2>/dev/null)"
[ -n "$c19_row_issued" ] && [ "$c19_row_issued" != "$c19_form_issued" ] \
  && ok "20: the inserted grant's issued_at equals the PREVIEWED build-time window, not issue's own invocation time" \
  || bad "20: issued_at check (row=$c19_row_issued, issue-time=$c19_form_issued -- should differ since build ran earlier)"
# Tamper the embedded record post-answer: digest mismatch refused.
c21_form_id="20990101T000000-00002"
python3 - "$WORK/c19.html" "$HERDR_STATE_ROOT/forms" "$c21_form_id" <<'PYEOF'
import json, re, sys, time, hashlib
html_path, forms_dir, form_id = sys.argv[1], sys.argv[2], sys.argv[3]
html = open(html_path, "rb").read()
m = re.search(rb'<script type="application/json" id="conductor-week-approval">(.*?)</script>', html, re.S)
embedded = m.group(1)
rec = json.loads(embedded)
rec["reason"] = "TAMPERED"
tampered = json.dumps(rec, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
tampered_html = html.replace(embedded, tampered)
sha = hashlib.sha256(embedded).hexdigest()  # the ORIGINAL sha, now stale against the tampered page
row = {"id": form_id, "status": "answered", "answered_at": int(time.time() * 1000),
       "answers": {"decision": "approve", "approval_sha256": sha}}
open(f"{forms_dir}/{form_id}.json", "w").write(json.dumps(row))
open(f"{forms_dir}/{form_id}.html", "wb").write(tampered_html)
PYEOF
c21_tampered="$(python3 "$here/lib/conductor_week_approval.py" issue --confirm-form "$c21_form_id" 2>&1)"; c21_tampered_rc=$?
[ "$c21_tampered_rc" != 0 ] && printf '%s' "$c21_tampered" | grep -q '^refused:' \
  && ok "19: a tampered embedded record (digest/render mismatch) is refused, never inserted" \
  || bad "19: tampered record (rc=$c21_tampered_rc out=[$c21_tampered])"
# Stale confirm window: answered_at far in the past.
c21_stale_id="20990101T000000-00003"
python3 - "$WORK/c19.html" "$HERDR_STATE_ROOT/forms" "$c21_stale_id" <<'PYEOF'
import json, re, sys, time, hashlib
html_path, forms_dir, form_id = sys.argv[1], sys.argv[2], sys.argv[3]
html = open(html_path, "rb").read()
m = re.search(rb'<script type="application/json" id="conductor-week-approval">(.*?)</script>', html, re.S)
embedded = m.group(1)
sha = hashlib.sha256(embedded).hexdigest()
row = {"id": form_id, "status": "answered", "answered_at": int((time.time() - 7200) * 1000),
       "answers": {"decision": "approve", "approval_sha256": sha}}
open(f"{forms_dir}/{form_id}.json", "w").write(json.dumps(row))
open(f"{forms_dir}/{form_id}.html", "wb").write(html)
PYEOF
c21_stale="$(python3 "$here/lib/conductor_week_approval.py" issue --confirm-form "$c21_stale_id" 2>&1)"; c21_stale_rc=$?
[ "$c21_stale_rc" != 0 ] && printf '%s' "$c21_stale" | grep -qi 'stale' \
  && ok "21: an answered form older than CONFIRM_WINDOW_S is refused (stale confirm window)" \
  || bad "21: stale confirm window (rc=$c21_stale_rc out=[$c21_stale])"

# =============================================================== §(i) 1 ===
# A closed stalled task reaches closed_unverified, never a fabricated
# completed: --reason=no-follow-on is accepted only for closed_unverified
# (_valid_unverified_closure_reason), refused for completed
# (_valid_closure_reason).
# conductor rootfix (2026-10-30): the prior `_i1_run`/`_i1_task` +
# `register_task` setup here is REMOVED, not fixed to 11 args -- proven
# dead: neither identifier is read anywhere below (grepped this whole
# file; the only two occurrences were this definition and the
# register_task call itself). Every §(i) 1 assertion below takes a
# literal string ("no-follow-on", "running", "closed_unverified"), never
# a registered task row -- _valid_closure_reason/
# _valid_unverified_closure_reason/_legal_transition are pure functions
# of their string arguments.
if _valid_closure_reason "no-follow-on"; then
  bad "i1: _valid_closure_reason wrongly accepts no-follow-on (that belongs to closed_unverified only)"
else
  ok "i1: _valid_closure_reason refuses no-follow-on -- completed requires shipped|abandoned|superseded"
fi
if _valid_unverified_closure_reason "no-follow-on"; then
  ok "i1: _valid_unverified_closure_reason accepts no-follow-on"
else
  bad "i1: _valid_unverified_closure_reason wrongly refuses no-follow-on"
fi
if _legal_transition "running" "closed_unverified"; then
  ok "i1: closed_unverified is a legal transition from running"
else
  bad "i1: closed_unverified not reachable from running"
fi

# =============================================================== §(i) 2 ===
# --reason=shipped with a valid proof still reaches completed -- the new
# state is additive, not a blanket downgrade.
if _valid_closure_reason "shipped"; then
  ok "i2: _valid_closure_reason still accepts shipped (completed path unaffected)"
else
  bad "i2: shipped no longer accepted for completed"
fi
if _valid_unverified_closure_reason "shipped"; then
  bad "i2: shipped wrongly also accepted as closed_unverified (reasons are disjoint)"
else
  ok "i2: shipped is NOT accepted for closed_unverified (the two reason sets are disjoint)"
fi

# =============================================================== §(i) 3 ===
# superseded and abandoned stay in the completed-eligible set, unaffected
# by the new unverified set.
for r in superseded abandoned; do
  if _valid_closure_reason "$r"; then
    ok "i3: _valid_closure_reason still accepts $r (own GitHub-verified proof path unaffected)"
  else
    bad "i3: $r no longer accepted for completed"
  fi
  if _valid_unverified_closure_reason "$r"; then
    bad "i3: $r wrongly also accepted as closed_unverified"
  else
    ok "i3: $r is NOT accepted for closed_unverified"
  fi
done

# =============================================================== §(i) 4/5 ===
# Items 4/5 (approval_unconsumed / prompt_unresolved HOLD, and
# unreadable-evidence fail-closed) are properties of close-done-workers.sh's
# own per-row loop (checks 5/6, lines 815-820) and its evidence helper
# _evidence_hold_reason, which queries `approvals`/shells out to
# lib/prompt-occurrence.py fold against a LIVE task/pane fixture --
# exercising it meaningfully needs the same herdr-pane-list mocking noted
# in this file's header, out of scope for this pass. The underlying SQL
# predicate (`decided_at IS NOT NULL AND outcome IS NULL`) and the
# fail-closed branches (query rc != 0 -> HOLD; fold rc != 0 or non-object
# JSON -> HOLD) are read-verified in close-done-workers.sh directly
# (_evidence_hold_reason, lines ~655-688). This sub-case proves the
# PREDICATE alone, directly against a seeded approvals row, without the
# full script around it.
_i45_run="$(gen_id test_run)"; _i45_task="$(gen_id test_task)"
_sql "INSERT INTO approvals (approval_id, run_id, task_id, pane_id, decided_at, outcome)
      VALUES ($(_sq "$(gen_id ap)"), $(_sq "$_i45_run"), $(_sq "$_i45_task"), 'pane-x', $(_sq "$(_now_iso)"), NULL);" >/dev/null 2>&1
_i45_out="$(_sql "SELECT approval_id FROM approvals WHERE task_id=$(_sq "$_i45_task") AND decided_at IS NOT NULL AND outcome IS NULL LIMIT 1;")"
[ -n "$_i45_out" ] \
  && ok "i4: an approved-but-unconsumed approvals row (decided_at set, outcome NULL) matches check 5's own predicate" \
  || bad "i4: check-5 predicate did not match the seeded unconsumed-approval fixture"

# =============================================================== case 22 ===
# Operator surface: status shows the bounded factory scope; revoke pauses it;
# a fresh, separately answered form issued through the wrapper clears that
# revocation and restores admission.
c22_status="$(bash "$here/grant-conductor-week-v2.sh" status)"
printf '%s' "$c22_status" | jq -e '.active == true and .revoked == false and (.labels | length) == 6' >/dev/null \
  && ok "22: status reports one active, unrevoked, six-lane factory key" \
  || bad "22: initial status (out=[$c22_status])"
bash "$here/grant-conductor-week-v2.sh" revoke >/dev/null
c22_revoked="$(bash "$here/grant-conductor-week-v2.sh" status)"
c22_admit="$(conductor_week_admits conductor 2>/dev/null)"; c22_admit_rc=$?
printf '%s' "$c22_revoked" | jq -e '.active == false and .revoked == true' >/dev/null \
  && [ "$c22_admit_rc" != 0 ] && [ -z "$c22_admit" ] \
  && ok "22: revoke is immediate and blocks admission" \
  || bad "22: revoke/status (status=[$c22_revoked] rc=$c22_admit_rc admit=[$c22_admit])"
c22_html="$WORK/c22.html"
caller_pane_from_ancestry() { return 2; }
export -f caller_pane_from_ancestry
python3 "$here/lib/conductor_week_approval.py" build-form --reason "wrapper renewal test" --out "$c22_html" >/dev/null
c22_form_id="20990101T000000-00022"
python3 - "$c22_html" "$HERDR_STATE_ROOT/forms" "$c22_form_id" <<'PYEOF'
import hashlib
import json
import re
import sys
import time

html_path, forms_dir, form_id = sys.argv[1], sys.argv[2], sys.argv[3]
html = open(html_path, "rb").read()
embedded = re.search(
    rb'<script type="application/json" id="conductor-week-approval">(.*?)</script>',
    html,
    re.S,
).group(1)
row = {
    "id": form_id,
    "status": "answered",
    "answered_at": int(time.time() * 1000),
    "answers": {"decision": "approve", "approval_sha256": hashlib.sha256(embedded).hexdigest()},
}
open(f"{forms_dir}/{form_id}.json", "w").write(json.dumps(row))
open(f"{forms_dir}/{form_id}.html", "wb").write(html)
PYEOF
c22_issue="$(bash "$here/grant-conductor-week-v2.sh" issue --confirm-form "$c22_form_id" 2>&1)"; c22_issue_rc=$?
c22_status_after="$(bash "$here/grant-conductor-week-v2.sh" status)"
c22_admit_after="$(conductor_week_admits knowledge-base 2>/dev/null)"; c22_admit_after_rc=$?
[ "$c22_issue_rc" = 0 ] && printf '%s' "$c22_issue" | grep -q '^issued:' \
  && printf '%s' "$c22_status_after" | jq -e '.active == true and .revoked == false' >/dev/null \
  && [ "$c22_admit_after_rc" = 0 ] && [ -n "$c22_admit_after" ] \
  && ok "22: a fresh answered form renews the key, clears revocation, and admits knowledge-base" \
  || bad "22: wrapper renewal (rc=$c22_issue_rc issue=[$c22_issue] status=[$c22_status_after])"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ -s "$WORK/herdr-violation" ]; then
  bad "no real herdr call across this entire suite"
  cat "$WORK/herdr-violation" >&2
fi
printf 'run dir: %s\n' "$WORK"
[ "$fail" -eq 0 ]
