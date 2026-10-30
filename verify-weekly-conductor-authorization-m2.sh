#!/usr/bin/env bash
# verify-weekly-conductor-authorization-m2.sh —
# docs/design/weekly-conductor-authorization.md, SCRIPT-LEVEL proofs that
# verify-weekly-conductor-authorization.sh's own header named as
# out-of-scope for that pass: conductor-week-daily-tick.sh's full §(f)
# chain against a live-Main fixture, conductor-handover.sh's recipient
# cap/expiry enforced THROUGH the real script (not just its storage-layer
# building blocks), close-done-workers.sh's §(i) checks 5/6 fail-closed
# behavior through the real per-row loop, the lease clamp at near-expiry
# through owner-lease-recover.py's real CLI, and §(i) item 2's
# "abandoned requires positive proof, never a bare label" through the
# real script. Same isolated-registry/TMPDIR/shadow-herdr convention;
# pane mocking follows verify-conductor-handover.sh's own
# ancestry-via-real-TEST_PID pattern. Nothing here calls
# lib/conductor_week_form.py or grant-conductor-week.sh (frozen).
#
#   bash verify-weekly-conductor-authorization-m2.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

# Every run gets its OWN unique directory under this suite's tmp/,
# retained whether this run passes or fails -- NEVER deleted, no EXIT
# trap either, so a prior run's evidence (including a failed run's own
# output) is never destroyed by a later run (conductor fix16b,
# 2026-10-30, applied identically to M1).
_work_parent="$here/tmp/verify-weekly-conductor-authorization-m2"
mkdir -p "$_work_parent" || { echo "FATAL: could not create $_work_parent" >&2; exit 1; }
_run_ts="$(date -u +%Y%m%dT%H%M%SZ)" || _run_ts=""
[ -n "$_run_ts" ] || _run_ts="fallback-$$-$RANDOM"
WORK="$(mktemp -d "$_work_parent/run-$_run_ts-XXXXXX")" || { echo "FATAL: mktemp -d failed under $_work_parent" >&2; exit 1; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "FATAL: WORK is empty or not a directory ([$WORK])" >&2; exit 1; }
[ -z "$(ls -A "$WORK" 2>/dev/null)" ] || { echo "FATAL: WORK ($WORK) is unexpectedly non-empty -- refusing to write into it" >&2; exit 1; }
export WORK
printf 'run dir: %s\n' "$WORK"
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_STATE_ROOT="$WORK/state"; mkdir -p "$HERDR_STATE_ROOT/forms"
export HERDR_CONDUCTOR_WEEK_REVOKED_FILE="$WORK/conductor-weekly-authorization.revoked"
export HERDR_PROMPT_SETTLE_WAIT_S=0
unset HERDR_PANE_ID HERDR_TASK_ID HERDR_RUN_ID HERDR_CONDUCTOR_PANE_ID \
      HERDR_MAIN_PANE_ID HERDR_MAIN_PANE_BIRTH HERDR_CONDUCTOR_ID HERDR_TASK_LABEL 2>/dev/null || true
TEST_PID=$$
export TEST_PID

. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"
. "$here/lib/push-wake.sh"
registry_init || { echo "FATAL: registry_init failed" >&2; exit 1; }

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
# p35 20:27Z/silent-exit (2026-10-30): same diagnostic trap added to M1,
# applied identically here -- an EXIT trap fires on every exit path
# (including a `set -u` unbound-variable abort, which a command's own
# `||` cannot catch) and prints the last line/function seen plus the
# running tally, so a silent early stop is immediately diagnosable from
# the run's own output. No assertion logic touched.
#
# conductor rootfix (2026-10-30): prints ONLY line number, exit code,
# and function name -- NEVER `$BASH_COMMAND` (this suite's fixtures
# carry pane ids, form ids, tokens and CALLER_PANE values; a trap must
# never echo expanded command arguments, full stop, regardless of
# whether a given run's values happen to be harmless). `trap - EXIT ERR
# DEBUG` disarms every trap, including itself, as the FIRST statement
# inside the EXIT trap body -- cannot recurse even if the printf itself
# were to fail or an ERR trap existed.
_dbg_lineno=0; _dbg_func="main"
trap '_dbg_lineno=$LINENO; _dbg_func="${FUNCNAME[0]:-main}"' DEBUG
trap '
  _exit_rc=$?
  trap - EXIT ERR DEBUG
  printf "\n[EXIT TRAP] rc=%s last_line=%s last_func=%s -- %d passed, %d failed so far\n" \
    "$_exit_rc" "$_dbg_lineno" "$_dbg_func" "${pass:-0}" "${fail:-0}" >&2
' EXIT

TTL_MS=$((120*60*60*1000))
now_ms() { printf '%s\n' "$(( $(date +%s) * 1000 ))"; }
mint_week() {
  local issued="$1" expires="$2" reason="${3:-m2 test mint}" cmd out
  cmd="$(gen_id test_conductor_week)"
  out="$(accept_conductor_weekly_authorization "$cmd" "pane-test-mint" "$reason" "$issued" "$expires")" || {
    printf 'FATAL: mint_week failed: %s\n' "$out" >&2; return 1
  }
  printf '%s\n' "$cmd"
}

# ---- fixture panes ----------------------------------------------------------
MAIN="m1:p1"; MAINB="m1b"
C1="c1:p1"; C1B="c1b"
SH="sh:p1"
export MAIN MAINB C1 C1B SH

_fsafe() { printf '%s' "${1//[:\/]/_}"; }
export -f _fsafe

herdr() {
  local sub="$1 $2" pane
  case "$sub" in
    "pane process-info")
      pane="$4"
      if [ "$pane" = "$SH" ]; then
        printf '{"result":{"process_info":{"foreground_processes":[]}}}\n'
      elif [ -n "${CALLER_PANE:-}" ] && [ "$pane" = "$CALLER_PANE" ]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' "$TEST_PID"
      else
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":2147483000,"name":"omp","cmdline":"omp --model sonnet"}]}}}\n'
      fi ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
        "$MAIN" "$MAINB" "$C1" "$C1B" ;;
    "pane read")  : ;;
    "pane send-text") : ;;
    "pane send-keys") : ;;
    "pane close") : ;;
    *) return 0 ;;
  esac
}
export -f herdr

ch() { bash "$here/conductor-handover.sh" "$@"; }

# =========================================================== case A ========
# §(g) item 6 (live-Main/restart positive): conductor-week-daily-tick.sh's
# full §(f) chain (revocation+scope -> live-Main -> fresh single-use
# redemption -> owner-lease-recover.py --conductor-grant) succeeds
# end-to-end against a real, live, registered Main and a valid grant.
CALLER_PANE="$MAIN" bash "$here/designate-main.sh" >/dev/null \
  || { echo "setup: designate-main.sh could not designate $MAIN" >&2; exit 1; }
cA_issued=$(now_ms); cA_expires=$((cA_issued + TTL_MS))
cA_grant="$(mint_week "$cA_issued" "$cA_expires")" || exit 1
cA_project="tntpgh/stuck-project-a"
cA_db=$(mktemp -d)/owner.sqlite3
python3 - "$cA_db" "$cA_project" <<PYEOF
import sys
sys.path.insert(0, "$here/lib")
import owner_lease as ol
c = ol.connect(sys.argv[1])
ol.migrate(c)
ol.register_owner(c, "conductor", sys.argv[2], now=__import__("time").time() - 200_000,
                   lifecycle_end_at=__import__("time").time() - 1000, unregister_token="")
c.close()
PYEOF
cA_out="$(HERDR_OWNER_LEASE_DB="$cA_db" bash "$here/conductor-week-daily-tick.sh" \
  --label conductor --project "$cA_project" --recover-label conductor \
  --pane-id "$MAIN" --pane-birth "$MAINB" --apply 2>&1)"; cA_rc=$?
[ "$cA_rc" = 0 ] && printf '%s' "$cA_out" | grep -q '^apply:recovered:conductor:' \
  && ok "A: daily tick succeeds end-to-end against a live, registered Main and a valid grant" \
  || bad "A: daily tick positive path (rc=$cA_rc out=[$cA_out])"
cA_row="$(python3 -c "
import sys; sys.path.insert(0, '$here/lib')
import owner_lease as ol
c = ol.connect('$cA_db')
print(c.execute(\"SELECT unregister_token FROM owner_projects WHERE label='conductor'\").fetchone()[0])
")"
[ -n "$cA_row" ] \
  && ok "A: the owner_projects row actually advanced (real recovery, not a dry no-op)" \
  || bad "A: owner_projects row unchanged after apply"

# =========================================================== case A2 =======
# No live Main: the tick refuses at step 2, never reaches owner-lease-recover.py.
CALLER_PANE="$MAIN" bash "$here/designate-main.sh" --clear >/dev/null 2>&1 || true
cA2_issued=$(now_ms); cA2_expires=$((cA2_issued + TTL_MS))
cA2_grant="$(mint_week "$cA2_issued" "$cA2_expires")" || exit 1
cA2_out="$(HERDR_OWNER_LEASE_DB="$cA_db" bash "$here/conductor-week-daily-tick.sh" \
  --label conductor --project "$cA_project" --recover-label conductor \
  --pane-id "$MAIN" --pane-birth "$MAINB" --apply 2>&1)"; cA2_rc=$?
[ "$cA2_rc" != 0 ] && [ "$cA2_out" = "refused:no_live_main" ] \
  && ok "A2: with no live Main the tick refuses at step 2, even with a fully valid grant" \
  || bad "A2: no-live-Main refusal (rc=$cA2_rc out=[$cA2_out])"
# restore Main for the remaining cases
CALLER_PANE="$MAIN" bash "$here/designate-main.sh" >/dev/null \
  || { echo "setup: re-designate-main.sh failed" >&2; exit 1; }

# =========================================================== case B ========
# §(g) item 15/17 SCRIPT-level: conductor-handover.sh's own recipient cap,
# exercised through the REAL script -- CONDUCTOR_HANDOVER_CAP self-
# handovers to Main succeed, the next is refused with the exact message,
# and no task state changed for the refused one.
cB_issued=$(now_ms); cB_expires=$((cB_issued + TTL_MS))
cB_grant="$(mint_week "$cB_issued" "$cB_expires")" || exit 1
for i in $(seq 1 11); do
  register_task run1 "capTask$i" "w" "c" "$C1" "$C1B" "w${i}:p1" "wb${i}" "/repo/x" "/wt/capTask$i" "impl:capTask$i" >/dev/null 2>&1
  set_task_state run1 "capTask$i" running >/dev/null 2>&1
done
cB_ok=0 cB_refused_11=""
for i in $(seq 1 11); do
  out="$(CALLER_PANE="$C1" ch --task "capTask$i" --to "$MAIN" --reason "m2 cap test" 2>&1)"
  if printf '%s' "$out" | grep -q "handed over capTask$i"; then
    cB_ok=$((cB_ok+1))
  elif [ "$i" = 11 ]; then
    cB_refused_11="$out"
  fi
done
[ "$cB_ok" = 10 ] \
  && ok "B: exactly 10 self-handovers to Main succeed against one grant (the cap, not fewer)" \
  || bad "B: admitted handover count (got $cB_ok, want 10)"
printf '%s' "$cB_refused_11" | grep -q 'weekly conductor-handover cap (10) reached' \
  && ok "B: the 11th self-handover to Main is refused through the real script with the cap message" \
  || bad "B: 11th handover refusal (out=[$cB_refused_11])"
check "B: capTask11's conductor is still C1, not Main (refused handover changed nothing)" \
  "$(read_task run1 capTask11 | jq -r .conductor_pane_id)" "$C1"

# =========================================================== case B2 =======
# Expired grant: the SAME self-handover-to-Main shape, through the real
# script, is refused outright (no grant admits) even on the FIRST attempt.
#
# T's 22:07Z run: this refused with "cap (10) reached" instead, because
# `read_conductor_week` returns the MOST RECENT *unexpired* row
# (task-authorization.py:581-583) -- case B's own grant is still fully
# valid (120h window, just cap-exhausted), so it's what gets found and
# fails at the cap check, before B2's own separately-minted EXPIRED
# grant is ever even looked at (an expired row is filtered out of
# candidacy entirely, not just deprioritized by recency).
#
# p35 REJECT r1 (criterion a): the first fix bracketed this with the
# GLOBAL revoke sentinel, which made revoked+cap-exhausted+expired all
# simultaneously true -- the refusal could not be attributed to expiry
# alone from this test's own evidence. `conductor_week_revoked` is a
# single global flag (lib/run-registry.sh:1044-1047), never grant-
# scoped -- there is no production mechanism to invalidate ONE grant
# row while leaving another valid. p35's proposed, adopted fix instead
# directly neutralizes case B's own leftover row via plain fixture SQL
# (the same `_sql` helper used throughout this suite, never touching
# `lib/run-registry.sh`'s revoke sentinel or any other production
# mechanism): forcing its `expires_at` into the past. With case B's row
# genuinely expired (not revoked, not merely cap-exhausted-but-valid)
# and B2's own grant already expired, ONLY expired rows are DB-present
# when B2 runs -- `read_conductor_week`'s own `expires_at>?` filter is
# the SOLE gate standing between admit and refuse, no cap confound (the
# row is gone from candidacy entirely, not just capped) and no
# revocation confound (the sentinel file is never touched here at all).
cB2_issued=$(( $(now_ms) - TTL_MS - 10000 )); cB2_expires=$((cB2_issued + TTL_MS))
cB2_grant="$(mint_week "$cB2_issued" "$cB2_expires" "m2 expired grant")" || exit 1
register_task run1 capTaskExp "w" "c" "$C1" "$C1B" "wE:p1" "wbE" "/repo/x" "/wt/capTaskExp" "impl:capTaskExp" >/dev/null 2>&1
set_task_state run1 capTaskExp running >/dev/null 2>&1
_sql "UPDATE task_authorizations SET expires_at=$(( $(now_ms) - 1 ))
      WHERE command_id=$(_sq "$cB_grant") AND source='conductor_weekly_authorization';" >/dev/null
# Explicit pre-attempt disproof of the two confounds p35's r1 reject
# named (conductor instruction): the refusal below cannot be the global
# revoke sentinel (it is absent) or the handover cap (cB2's own grant's
# own count is well under it) -- expiry is the only thing left standing.
[ ! -f "$HERDR_CONDUCTOR_WEEK_REVOKED_FILE" ] \
  && ok "B2: the global revoke sentinel is absent at attempt time (the refusal below cannot be revocation)" \
  || bad "B2: revoke sentinel unexpectedly present before the attempt"
cB2_handover_count="$(conductor_week_handover_count "$cB2_grant")"
[ "${cB2_handover_count:-0}" -lt "$CONDUCTOR_HANDOVER_CAP" ] \
  && ok "B2: cB2's own handover count ($cB2_handover_count) is below the cap ($CONDUCTOR_HANDOVER_CAP) at attempt time (the refusal below cannot be the cap either)" \
  || bad "B2: cB2's handover count unexpectedly at/above cap before the attempt (count=$cB2_handover_count)"
cB2_out="$(CALLER_PANE="$C1" ch --task capTaskExp --to "$MAIN" --reason "m2 expired grant test" 2>&1)"
printf '%s' "$cB2_out" | grep -q 'no valid weekly conductor authorization active' \
  && ok "B2: with case B's own leftover grant row forced to genuinely expired (not revoked, not merely capped) and B2's own grant already expired, no grant admits -- a self-handover to Main is refused through the real script, proving expiry alone, isolated from the cap and from revocation" \
  || bad "B2: expired-grant handover (out=[$cB2_out])"
check "B2: capTaskExp's conductor is still C1 (refused handover changed nothing)" \
  "$(read_task run1 capTaskExp | jq -r .conductor_pane_id)" "$C1"

# =========================================================== case C ========
# §(i) checks 5/6 through the REAL close-done-workers.sh loop: an
# unconsumed approval HOLDS a task that is otherwise perfectly clean
# (idle pane, no worktree on disk so hygiene checks short-circuit clean).
#
# T's 22:07Z run: `--reason=shipped --proof="x"` was refused outright by
# close-done-workers.sh's own proof-format gate (close-done-workers.sh:
# 180-183/_valid_proof_ref, lib/run-registry.sh:1426) -- "x" matches
# neither the `<merged PR URL> <merge sha>` shape nor a `*PROOF.md*`
# reference, so the real script exits before the per-row loop (and its
# checks 5/6) is ever reached. A real GitHub PR URL would need a live
# network `gh` lookup (_gh_pr_lookup, line 1485) this sandboxed suite
# cannot make. Fixed by switching to `--reason=no-follow-on`: the
# proof gate (close-done-workers.sh:137) is scoped to
# shipped|abandoned|superseded ONLY -- no-follow-on needs none -- while
# checks 5/6 themselves run "on EVERY candidate row... same as every
# other check here" (close-done-workers.sh:815-819) regardless of which
# reason was requested; this proves the exact same HOLD behavior this
# case always intended, without a fabricated or network-dependent proof.
cdw() { bash "$here/close-done-workers.sh" "$@"; }
register_task run1 cTask1 "w" "c" "$C1" "$C1B" "pC1:p1" "pC1b" "/repo/x" "/does/not/exist" "closable1" >/dev/null 2>&1
set_task_state run1 cTask1 running >/dev/null 2>&1
_sql "INSERT INTO approvals (approval_id, run_id, task_id, pane_id, decided_at, outcome)
      VALUES ($(_sq "$(gen_id ap)"), 'run1', 'cTask1', 'pC1:p1', $(_sq "$(date -u +%Y-%m-%dT%H:%M:%SZ)"), NULL);" >/dev/null
cC_out="$(CALLER_PANE="$C1" cdw --apply --reason=no-follow-on --pane=pC1:p1 2>&1)"
printf '%s' "$cC_out" | grep -q 'approval_unconsumed' \
  && ok "C: an unconsumed approval HOLDS an otherwise-clean task through the real close-done-workers.sh loop" \
  || bad "C: evidence check 5 through real loop (out=[$cC_out])"
check "C: cTask1 is still running (held, not closed)" "$(read_task run1 cTask1 | jq -r .state)" "running"

# =========================================================== case C2 =======
# Fail-closed: the registry db made temporarily unreadable mid-check (the
# ONLY way to force a genuine read failure in-process) HOLDS, never
# "assume clean" -- restored immediately after, in a trap, so the rest of
# this suite is unaffected regardless of outcome. Same --reason=no-follow-on
# fix as case C above, same reasoning (no proof needed, checks 5/6 still run).
_sql "DELETE FROM approvals WHERE task_id='cTask1';" >/dev/null
db_path="$(registry_db)"
chmod 000 "$db_path" 2>/dev/null
restore_db() { chmod 600 "$db_path" 2>/dev/null; }
trap restore_db RETURN 2>/dev/null || true
cC2_out="$(CALLER_PANE="$C1" cdw --apply --reason=no-follow-on --pane=pC1:p1 2>&1)"
restore_db
printf '%s' "$cC2_out" | grep -qi 'could not be read' \
  && ok "C2: an unreadable approvals/registry query HOLDS, fail-closed, never treated as clean" \
  || bad "C2: fail-closed on read failure (out=[$cC2_out])"
check "C2: cTask1 is still running after the unreadable-evidence attempt" "$(read_task run1 cTask1 | jq -r .state)" "running"

# =========================================================== case P1 =======
# p35 REVIEW-M2-FIX-VERDICT-p35-r1.md (b): `_valid_proof_ref`
# (lib/run-registry.sh:1426, called from lib/run-registry.sh:1663,1690)
# had ZERO test call sites in either suite -- named as a gap, not fixed
# by the B2/C/C2 fixes themselves. P1-P4 close it. P1: --reason=shipped
# with NO --proof at all is refused before the per-row loop.
register_task run1 capTaskP1 "w" "c" "$C1" "$C1B" "pP1:p1" "pP1b" "/repo/x" "/does/not/exist" "impl:capTaskP1" >/dev/null 2>&1
set_task_state run1 capTaskP1 running >/dev/null 2>&1
cP1_out="$(CALLER_PANE="$C1" cdw --apply --reason=shipped --pane=pP1:p1 2>&1)"; cP1_rc=$?
[ "$cP1_rc" != 0 ] && printf '%s' "$cP1_out" | grep -q -- '--reason=shipped requires --proof' \
  && ok "P1: --reason=shipped with no --proof at all is refused through the real proof-format gate" \
  || bad "P1: shipped-no-proof (rc=$cP1_rc out=[$cP1_out])"
check "P1: capTaskP1 is still running (refused, nothing closed)" "$(read_task run1 capTaskP1 | jq -r .state)" "running"

# =========================================================== case P2 =======
# An invalid proof shape ("x": no space, not a PR URL, not a PROOF.md
# reference) is refused at the SAME format gate, not merely "no proof".
register_task run1 capTaskP2 "w" "c" "$C1" "$C1B" "pP2:p1" "pP2b" "/repo/x" "/does/not/exist" "impl:capTaskP2" >/dev/null 2>&1
set_task_state run1 capTaskP2 running >/dev/null 2>&1
cP2_out="$(CALLER_PANE="$C1" cdw --apply --reason=shipped --proof="x" --pane=pP2:p1 2>&1)"; cP2_rc=$?
[ "$cP2_rc" != 0 ] && printf '%s' "$cP2_out" | grep -q -- '--reason=shipped requires --proof' \
  && ok "P2: --reason=shipped with an invalid proof ('x') is refused through the real proof-format gate" \
  || bad "P2: shipped-invalid-proof (rc=$cP2_rc out=[$cP2_out])"
check "P2: capTaskP2 is still running (refused, nothing closed)" "$(read_task run1 capTaskP2 | jq -r .state)" "running"

# =========================================================== case P3 =======
# A VALID offline proof (a non-empty PROOF.md section in the selected
# task's own worktree -- no gh/network) actually reaches completed.
# Same minimal git fixture verify-close-done-workers.sh's own
# "shipped accepted once PROOF.md actually holds something" case uses
# (init -b main, one commit -- a normal attached branch, never
# detached, so the review-PR/detached-head hygiene path never engages).
cP3_wt=$(mktemp -d)/wtP3
git init -q -b main "$cP3_wt"
git -C "$cP3_wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$cP3_wt/.handoffs"
printf 'verified: m2 case P3, ran the check, output attached\n' > "$cP3_wt/.handoffs/PROOF.md"
register_task run1 capTaskP3 "w" "c" "$C1" "$C1B" "pP3:p1" "pP3b" "$cP3_wt" "$cP3_wt" "impl:capTaskP3" >/dev/null 2>&1
set_task_state run1 capTaskP3 running >/dev/null 2>&1
cP3_out="$(CALLER_PANE="$C1" cdw --apply --reason=shipped --proof=".handoffs/PROOF.md#ok" --pane=pP3:p1 2>&1)"; cP3_rc=$?
[ "$cP3_rc" = 0 ] \
  && ok "P3: --reason=shipped with a valid non-empty PROOF.md reference (no network) is accepted through the real proof-format gate" \
  || bad "P3: shipped-valid-proof (rc=$cP3_rc out=[$cP3_out])"
check "P3: capTaskP3 reaches completed (the row this proof covers, actually closed)" "$(read_task run1 capTaskP3 | jq -r .state)" "completed"

# =========================================================== case P4 =======
# --reason=no-follow-on, its own separate case: accepted with NO proof
# at all, reaching closed_unverified (never completed -- a different
# target state than P1-P3's shipped/completed).
register_task run1 capTaskP4 "w" "c" "$C1" "$C1B" "pP4:p1" "pP4b" "/repo/x" "/does/not/exist" "impl:capTaskP4" >/dev/null 2>&1
set_task_state run1 capTaskP4 running >/dev/null 2>&1
cP4_out="$(CALLER_PANE="$C1" cdw --apply --reason=no-follow-on --pane=pP4:p1 2>&1)"; cP4_rc=$?
[ "$cP4_rc" = 0 ] \
  && ok "P4: --reason=no-follow-on with no proof at all is accepted through the real script" \
  || bad "P4: no-follow-on-no-proof (rc=$cP4_rc out=[$cP4_out])"
check "P4: capTaskP4 reaches closed_unverified (no-follow-on's own target state, never completed)" "$(read_task run1 capTaskP4 | jq -r .state)" "closed_unverified"

# =========================================================== case D ========
# §(g) item 13: the 24h LEASE clamp at near-expiry, through owner-lease-
# recover.py's real --conductor-grant CLI path -- a redemption token
# minted with clamp_expires_at only ~1h out caps new_lifecycle_end at
# that bound, never the normal full 24h. CORRECTED (p35 16:53): this
# case alone does NOT prove the token's own separate 5-minute clamp --
# at 1h remaining the token's normal 5-min TTL is already far shorter
# than the grant's own remaining life, so that clamp is never actually
# exercised here. See case G below for a genuine under-5-minute fixture
# that proves the TOKEN clamp specifically.
cD_db=$(mktemp -d)/owner.sqlite3
cD_project="tntpgh/stuck-project-d"
python3 - "$cD_db" "$cD_project" <<PYEOF
import sys, time
sys.path.insert(0, "$here/lib")
import owner_lease as ol
c = ol.connect(sys.argv[1])
ol.migrate(c)
ol.register_owner(c, "conductor", sys.argv[2], now=time.time() - 200_000,
                   lifecycle_end_at=time.time() - 1000, unregister_token="")
c.close()
PYEOF
# T's 22:07Z run FATAL (line ~278): accept_conductor_weekly_authorization
# refuses any window where expires-issued != CONDUCTOR_WEEK_TTL_MS
# (task-authorization.py:540-542) -- a REAL grant can never have an
# arbitrary window, only ever exactly the fixed TTL. The prior
# `cD_near_clamp_ms = (real_now + 3600) * 1000` with `cD_issued=now_ms`
# built a ~1h window, which `mint_week` refused outright. Fixed with the
# same backdated-`issued_at` pattern case G already uses below: push
# `issued_at` back by (TTL_MS - 1h) so `expires = issued + TTL_MS` still
# lands ~1h from now, while the window itself stays exactly TTL_MS.
cD_real_now=$(date +%s)
cD_issued=$(( $(now_ms) - TTL_MS + 3600000 ))
cD_near_clamp_ms=$(( cD_issued + TTL_MS ))   # grant ends in exactly 1h, window == TTL_MS
cD_grant_id="$(mint_week "$cD_issued" "$cD_near_clamp_ms" "m2 near-expiry clamp test")" || exit 1
cD_token="$(gen_id test_conductor_redemption)"
mint_conductor_redemption "$cD_token" "$cD_grant_id" conductor "$cD_near_clamp_ms" >/dev/null || { echo FATAL >&2; exit 1; }
cD_out="$(HERDR_OWNER_LEASE_WRITER=1 HERDR_OWNER_LEASE_DB="$cD_db" python3 "$here/owner-lease-recover.py" \
  --label conductor --project "$cD_project" --pane-id "$MAIN" --pane-birth "$MAINB" \
  --conductor-grant "$cD_token" --apply 2>&1)"; cD_rc=$?
[ "$cD_rc" = 0 ] && printf '%s' "$cD_out" | grep -q '^apply:recovered:conductor:' \
  && ok "D: the clamp path succeeds near grant expiry (does not simply refuse)" \
  || bad "D: near-expiry clamp apply (rc=$cD_rc out=[$cD_out])"
cD_new_end="$(python3 -c "
import sys; sys.path.insert(0, '$here/lib')
import owner_lease as ol
c = ol.connect('$cD_db')
print(c.execute(\"SELECT lifecycle_end_at FROM owner_projects WHERE label='conductor'\").fetchone()[0])
")"
cD_new_end_epoch="$(python3 -c "
import sys; sys.path.insert(0, '$here/lib')
import owner_lease as ol
print(ol._parse_iso('$cD_new_end'))" 2>/dev/null || python3 -c "
import datetime
print(datetime.datetime.strptime('$cD_new_end'.rstrip('Z'), '%Y-%m-%dT%H:%M:%S').replace(tzinfo=datetime.timezone.utc).timestamp())")"
cD_full_24h=$(( cD_real_now + 86400 ))
[ "${cD_new_end_epoch%.*}" -lt "$cD_full_24h" ] \
  && ok "D: the new lifecycle_end_at is clamped to the grant's own expiry, well short of a full 24h" \
  || bad "D: clamp did not bite (new_end=$cD_new_end_epoch, unclamped would be ~$cD_full_24h)"

# =========================================================== case E ========
# §(i) item 2: --reason=abandoned is accepted by the CLI vocabulary gate,
# but a task with NO positive detached-PR proof (not even a detached
# HEAD / closed-unmerged PR) still HOLDS through the real script -- never
# silently falls through to closed_unverified OR completed without
# evidence.
register_task run1 cTaskAbandon "w" "c" "$C1" "$C1B" "pC1:p1" "pC1b" "/repo/x" "/does/not/exist" "abandon-no-proof" >/dev/null 2>&1
set_task_state run1 cTaskAbandon running >/dev/null 2>&1
cE_out="$(CALLER_PANE="$C1" cdw --apply --reason=abandoned --pane=pC1:p1 2>&1)"
printf '%s' "$cE_out" | grep -qi 'only for a detached-HEAD reviewer whose PR closed unmerged' \
  && ok "E: --reason=abandoned without a real detached/closed-PR fixture HOLDS, never silently closes" \
  || bad "E: abandoned-without-proof (out=[$cE_out])"
check "E: cTaskAbandon is still running (held, no state fabricated)" "$(read_task run1 cTaskAbandon | jq -r .state)" "running"

# =========================================================== case F ========
# §(i) item 2 POSITIVE: --reason=abandoned against a task that genuinely
# HAS the required proof (detached HEAD at a commit matching a real,
# closed-unmerged PR's refs/pull/<n>/head on origin, clean worktree, no
# ignored artifacts to archive) reaches completed end-to-end through the
# real close-done-workers.sh --apply, and the pane is actually closed.
export GH_PRS="org/repoF#1 CLOSED -"
gh() {
  local n="" slug="" q="" prev=""
  [ "$1 $2" = "pr view" ] && n="$3"
  for a in "$@"; do [ "$prev" = -R ] && slug="$a"; [ "$prev" = -q ] && q="$a"; prev="$a"; done
  while read -r key st oid; do
    [ "$key" = "$slug#$n" ] || continue
    jq -nc --arg s "$st" --arg u "https://github.com/$slug/pull/$n" --arg o "$oid" \
      '{state:$s, url:$u, mergeCommit:(if $o=="-" then null else {oid:$o} end)}' | jq -r "$q"
    return 0
  done <<<"$GH_PRS"
  echo "GraphQL: Could not resolve to a PullRequest" >&2; return 1
}
export -f gh
cF_origin=$(mktemp -d)/origin.git
git init -q --bare "$cF_origin"
cF_repo=$(mktemp -d)/repo
mkdir -p "$cF_repo"
git -C "$cF_repo" init -q
git -C "$cF_repo" config user.email t@example.com
git -C "$cF_repo" config user.name t
echo hi > "$cF_repo/f.txt"
git -C "$cF_repo" add -A
git -C "$cF_repo" commit -q -m c1
git -C "$cF_repo" remote add origin "$cF_origin"
git -C "$cF_repo" push -q origin HEAD:refs/heads/main
cF_sha="$(git -C "$cF_repo" rev-parse HEAD)"
git -C "$cF_repo" push -q origin "HEAD:refs/pull/1/head"
git -C "$cF_repo" checkout -q --detach "$cF_sha"
register_task run1 cTaskAbandonOK "w" "c" "$C1" "$C1B" "pC2:p1" "pC2b" "$cF_repo" "$cF_repo" "review:cTaskAbandonOK" >/dev/null 2>&1
set_task_state run1 cTaskAbandonOK running >/dev/null 2>&1
set_task_review_pr run1 cTaskAbandonOK org/repoF 1 >/dev/null 2>&1 \
  || bad "F: setup -- set_task_review_pr failed"
cF_out="$(CALLER_PANE="$C1" cdw --apply --reason=abandoned --pane=pC2:p1 2>&1)"
printf '%s' "$cF_out" | grep -q 'close  pC2:p1' \
  && ok "F: a genuinely proven abandoned task (detached HEAD == closed PR's own ref, clean tree) is accepted as closable" \
  || bad "F: positive abandoned path did not report closable (out=[$cF_out])"
check "F: cTaskAbandonOK reached completed end-to-end with real proof (never closed_unverified)" \
  "$(read_task run1 cTaskAbandonOK | jq -r .state)" "completed"
check "F: the closure_reason recorded is abandoned" \
  "$(read_task run1 cTaskAbandonOK | jq -r .closure_reason)" "abandoned"

# =========================================================== case G ========
# §(g) item 14, corrected: case D above (grant ending in ~1h) only
# exercises the 24h LEASE clamp -- at 1h remaining, the token's own
# normal 5-minute redemption TTL is already far shorter than the grant's
# remaining life, so it was never actually constrained by the grant.
# This case mints a grant with underSIX MINUTES genuinely remaining (3s,
# to keep the suite fast) -- strictly less than the token's normal 5-min
# TTL -- and proves the TOKEN's own expires_at is shortened to the
# grant's own end, not the nominal 5 minutes, both by direct row value
# and by a real elapsed-time expiry.
cG_issued=$(( $(now_ms) - TTL_MS + 3000 ))
cG_expires=$(( cG_issued + TTL_MS ))   # grant has ~3s left from "now"
cG_grant_id="$(mint_week "$cG_issued" "$cG_expires" "m2 sub-5-min clamp test")" || exit 1
cG_token="$(gen_id test_conductor_redemption)"
mint_conductor_redemption "$cG_token" "$cG_grant_id" conductor "$cG_expires" >/dev/null || { echo FATAL >&2; exit 1; }
cG_tok_expires_at="$(_sql "SELECT expires_at FROM task_authorizations WHERE command_id=$(_sq "$cG_token");")"
[ "$cG_tok_expires_at" = "$cG_expires" ] \
  && ok "G: with under 5 minutes of grant life left, the token's own expires_at is shortened to the grant's end, not the nominal 5-min TTL" \
  || bad "G: token clamp row value (got [$cG_tok_expires_at], want [$cG_expires])"
cG_normal_5min=$(( cG_issued + 5 * 60 * 1000 ))
[ "$cG_tok_expires_at" -lt "$cG_normal_5min" ] \
  && ok "G: the clamped expires_at is strictly earlier than the unclamped 5-min TTL would have been" \
  || bad "G: clamp did not actually shorten anything (got [$cG_tok_expires_at], unclamped would be [$cG_normal_5min])"
cG_peek_before="$(peek_conductor_redemption "$cG_token" conductor 2>/dev/null)"
[ -n "$cG_peek_before" ] \
  && ok "G: the token is genuinely usable before its clamped (not its nominal) expiry" \
  || bad "G: pre-expiry peek failed (fixture not valid before asserting the boundary)"
sleep 4
cG_claim_after="$(claim_conductor_redemption "$cG_token" conductor 2>/dev/null)"; cG_claim_after_rc=$?
[ "$cG_claim_after_rc" != 0 ] && [ -z "$cG_claim_after" ] \
  && ok "G: real elapsed time past the grant's own end (not the nominal 5-min TTL) refuses the claim -- the TOKEN clamp genuinely bites" \
  || bad "G: post-clamp-expiry claim (rc=$cG_claim_after_rc out=[$cG_claim_after])"

# =========================================================== case H ========
# REVIEW-WEEKLY-SECURITY-DELTA (p35, 2026-10-30): deterministic negative
# proof that conductor-handover.sh's recipient-side grant check is now
# re-verified fresh, not cached for an entire invocation. True
# single-process mid-loop injection (pausing conductor-handover.sh's own
# while loop between two tasks of ONE --apply call to revoke in the
# middle) would need a test-only hook inside the production script --
# out of scope ("no new architecture"). This proves the SAME property
# the fix actually establishes instead: the fix makes
# `conductor_week_admits` a plain per-task call with NO invocation-scoped
# state at all -- identical whether it is the 2nd task of one
# `--apply` or the 1st task of a brand-new invocation. Before the fix,
# `_conductor_week_grant` was resolved ONCE per invocation and reused for
# every task THAT invocation touched, however many; after the fix, there
# is no such cache to reuse, in a single invocation or across many — so a
# revocation between invocation 1 and invocation 2 below exercises
# exactly the code path a revocation between task 1 and task 2 of one
# multi-task invocation would, with no special-cased behavior to game.
cH_issued=$(now_ms); cH_expires=$((cH_issued + TTL_MS))
mint_week "$cH_issued" "$cH_expires" "m2 revoke-between-invocations test" >/dev/null || exit 1
register_task run1 cwTask1 "w" "c" "$C1" "$C1B" "wH1:p1" "wbH1" "/repo/x" "/wt/cwTask1" "impl:cwTask1" >/dev/null 2>&1
set_task_state run1 cwTask1 running >/dev/null 2>&1
register_task run1 cwTask2 "w" "c" "$C1" "$C1B" "wH2:p1" "wbH2" "/repo/x" "/wt/cwTask2" "impl:cwTask2" >/dev/null 2>&1
set_task_state run1 cwTask2 running >/dev/null 2>&1
cH_out1="$(CALLER_PANE="$C1" ch --task cwTask1 --to "$MAIN" --reason "m2 revoke test 1" 2>&1)"
printf '%s' "$cH_out1" | grep -q "handed over cwTask1" \
  && ok "H: first self-handover to Main succeeds against a fresh, valid grant" \
  || bad "H: setup -- first handover (out=[$cH_out1])"
: > "$HERDR_CONDUCTOR_WEEK_REVOKED_FILE"
cH_out2="$(CALLER_PANE="$C1" ch --task cwTask2 --to "$MAIN" --reason "m2 revoke test 2" 2>&1)"
rm -f "$HERDR_CONDUCTOR_WEEK_REVOKED_FILE"
printf '%s' "$cH_out2" | grep -q 'no valid weekly conductor authorization active' \
  && ok "H: a revocation landing between the two tasks refuses the second one -- the fix re-verifies per task, never reuses a pre-batch snapshot" \
  || bad "H: revoked second handover (out=[$cH_out2])"
check "H: cwTask2's conductor is still C1 (refused, nothing fabricated)" "$(read_task run1 cwTask2 | jq -r .conductor_pane_id)" "$C1"

# =========================================================== case I ========
# Same proof for NATURAL EXPIRY rather than an explicit revoke (p35's
# correction: "the identical exposure applies to natural expiry, not just
# a human's revocation action"). A grant with ~3s of real life left (same
# technique as case G) admits the first handover, then a 4-second real
# sleep genuinely crosses the grant's own expires_at before the second.
cI_issued=$(( $(now_ms) - TTL_MS + 3000 )); cI_expires=$((cI_issued + TTL_MS))
mint_week "$cI_issued" "$cI_expires" "m2 expire-between-invocations test" >/dev/null || exit 1
register_task run1 cwTask3 "w" "c" "$C1" "$C1B" "wH3:p1" "wbH3" "/repo/x" "/wt/cwTask3" "impl:cwTask3" >/dev/null 2>&1
set_task_state run1 cwTask3 running >/dev/null 2>&1
register_task run1 cwTask4 "w" "c" "$C1" "$C1B" "wH4:p1" "wbH4" "/repo/x" "/wt/cwTask4" "impl:cwTask4" >/dev/null 2>&1
set_task_state run1 cwTask4 running >/dev/null 2>&1
cI_out1="$(CALLER_PANE="$C1" ch --task cwTask3 --to "$MAIN" --reason "m2 expiry test 1" 2>&1)"
printf '%s' "$cI_out1" | grep -q "handed over cwTask3" \
  && ok "I: first self-handover to Main succeeds while the grant genuinely still has real time left" \
  || bad "I: setup -- first handover before expiry (out=[$cI_out1])"
sleep 4
cI_out2="$(CALLER_PANE="$C1" ch --task cwTask4 --to "$MAIN" --reason "m2 expiry test 2" 2>&1)"
printf '%s' "$cI_out2" | grep -q 'no valid weekly conductor authorization active' \
  && ok "I: real elapsed time crossing the grant's own natural expiry refuses the second handover -- expiry is re-checked per task exactly like revocation, never just revocation alone" \
  || bad "I: expired second handover (out=[$cI_out2])"
check "I: cwTask4's conductor is still C1 (refused, nothing fabricated)" "$(read_task run1 cwTask4 | jq -r .conductor_pane_id)" "$C1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
printf 'run dir: %s\n' "$WORK"
[ "$fail" -eq 0 ]
