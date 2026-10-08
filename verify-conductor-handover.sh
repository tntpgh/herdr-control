#!/usr/bin/env bash
# verify-conductor-handover.sh — SPEC.md feat/conductor-handover. Proves:
#   - lib/run-registry.sh set_task_conductor is a real compare-and-swap:
#     a stale/raced caller changes nothing, exactly one of two concurrent
#     handovers of the same task wins, a terminal task refuses;
#   - lib/pane-guard.sh pane_is_conductor_eligible (#252/P3, shared with
#     spawn-task.sh's HERDR_MCP_CONDUCTOR_PANE fallback and
#     designate-main.sh) refuses a registered worker's own pane, a
#     non-agent pane, and fails closed on a herdr read failure;
#   - conductor-handover.sh resolves its caller from REAL process ancestry
#     (caller_pane_from_ancestry), never a self-asserted
#     HERDR_PANE_ID/HERDR_TASK_ID — a worker spoofing HERDR_PANE_ID=<Main>
#     is still refused as a worker, and a herdr ancestry-read failure
#     refuses rather than guessing;
#   - its authority rule (current live conductor gives its own tasks away;
#     Main — read from the roles table, not an env var — gives any task
#     away; everyone else, and every worker, is refused), its target rule
#     (--to must be live and conductor-eligible), its re-wake of a pending
#     prompt through the existing push-wake path, and its best-effort
#     [handover] notify to both sides;
#   - after a successful handover, herdr-select.sh's own conductor check
#     (the `owner_pane`/`owner_birth` comparison at herdr-select.sh:282-293)
#     passes for the NEW conductor pane and fails for the OLD one.
#
# Hermetic: a throwaway HERDR_RUN_STATE_DIR, a stubbed `herdr` function (same
# pattern as verify-attention-tick.sh / verify-omp-hooks.sh) standing in for
# every pane send-to-agent.sh and push_wake touch — no live herdr, no network.
#
#   bash verify-conductor-handover.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export SENT="$WORK/sent.log"
: > "$SENT"
# This suite may itself be running inside a real herdr-spawned pane (it is
# one, in CI) — unset every HERDR_* identity var so none of that real
# session leaks into what's being tested as a fixture below.
unset HERDR_PANE_ID HERDR_TASK_ID HERDR_RUN_ID HERDR_CONDUCTOR_PANE_ID \
      HERDR_MAIN_PANE_ID HERDR_MAIN_PANE_BIRTH HERDR_CONDUCTOR_ID HERDR_TASK_LABEL 2>/dev/null || true

# conductor-handover.sh and designate-main.sh (#252/P3) resolve the caller
# from REAL process ancestry (caller_pane_from_ancestry), not an env var —
# so simulating "this call comes from pane X" means the herdr stub's "pane
# process-info" response for X must report a pid that is a genuine ancestor
# of the `ch`/`dm` subshell. TEST_PID (this script's own real PID, captured
# once here, before any subshell) always is one; CALLER_PANE picks which
# fixture pane the stub attributes it to for the next call.
TEST_PID=$$
export TEST_PID

. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"
. "$here/lib/push-wake.sh"

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# ---- fixture panes ----------------------------------------------------------
W1="w1:p1"; W1B="w1b"   # taskA's worker
W2="w2:p1"; W2B="w2b"   # taskB's worker — also used as an invalid --to target
C1="c1:p1"; C1B="c1b"   # current conductor of taskA..taskF
C2="c2:p1"; C2B="c2b"   # handover target — live, non-worker agent pane
MAIN="m1:p1"; MAINB="m1b"
OTHER="o1:p1"; OTHERB="o1b"   # live agent pane, neither conductor nor Main
SH="sh:p1"                     # a bare shell pane (no foreground agent)
export W1 W1B W2 W2B C1 C1B C2 C2B MAIN MAINB OTHER OTHERB SH

_fsafe() { printf '%s' "${1//[:\/]/_}"; }
export -f _fsafe

herdr() {
  local sub="$1 $2" pane screen wake target
  case "$sub" in
    "pane process-info")
      [ -z "${FAIL_PANE_LIST:-}" ] || return 1
      pane="$4"
      if [ "$pane" = "$SH" ]; then
        printf '{"result":{"process_info":{"foreground_processes":[]}}}\n'
      elif [ -n "${CALLER_PANE:-}" ] && [ "$pane" = "$CALLER_PANE" ]; then
        # Attributes TEST_PID (a real ancestor of this call) to the fixture
        # pane the current test wants to act as the caller.
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' "$TEST_PID"
      else
        printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n'
      fi ;;
    "pane list")
      # FAIL_PANE_LIST simulates a herdr read failure for the
      # "could not verify caller identity" / "herdr read failure" negative
      # rows — caller_pane_from_ancestry and pane_is_conductor_eligible must
      # both refuse outright on this, never fall back to "not found".
      [ -z "${FAIL_PANE_LIST:-}" ] || return 1
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
        "$W1" "$W1B" "$W2" "$W2B" "$C1" "$C1B" "$C2" "$C2B" "$OTHER" "$OTHERB" "$MAIN" "$MAINB" ;;
    "pane read")
      pane="$3"; screen="$WORK/screen_$(_fsafe "$pane").txt"
      cat "$screen" 2>/dev/null; true ;;
    "pane send-text")
      pane="$3"; printf 'send-text %s\n' "$pane" >> "$SENT"
      printf '%s' "$4" > "$WORK/wake_$(_fsafe "$pane").txt" ;;
    "pane send-keys")
      target="$3"; printf 'send-keys %s %s\n' "$target" "$4" >> "$SENT"
      if [ "$4" = "Enter" ]; then
        wake="$WORK/wake_$(_fsafe "$target").txt"
        screen="$WORK/screen_$(_fsafe "$target").txt"
        { printf ' %s\n' "$(cat "$wake" 2>/dev/null)"
          printf '\n submitted\n $ \n ready\n'; } > "$screen"
      fi ;;
    *) return 0 ;;
  esac
}
export -f herdr

# roles/main, via the REAL designate-main.sh (same approved pattern
# verify-designate-main.sh uses), not a direct file write.
CALLER_PANE="$MAIN" bash "$here/designate-main.sh" >/dev/null \
  || { echo "setup: designate-main.sh could not designate $MAIN as Main" >&2; exit 1; }

ch() { bash "$here/conductor-handover.sh" "$@"; }

reg() { register_task run1 "$1" "worker_$1" "cond_$1" "$2" "$3" "$4" "$5" "/repo/x" "/wt/$1" "impl:$1"; }

printf '== fixture: six active tasks under C1, one worker pane each ==\n'
reg taskA "$C1" "$C1B" "$W1" "$W1B"   || bad "register taskA"
reg taskB "$C1" "$C1B" "$W2" "$W2B"   || bad "register taskB"
reg taskC "$C1" "$C1B" "w3:p1" "w3b"  || bad "register taskC"
reg taskD "$C1" "$C1B" "w4:p1" "w4b"  || bad "register taskD"
reg taskE "$C1" "$C1B" "w5:p1" "w5b"  || bad "register taskE"
reg taskF "$C1" "$C1B" "w6:p1" "w6b"  || bad "register taskF"
for t in taskA taskB taskC taskD taskE taskF; do
  set_task_state run1 "$t" running >/dev/null 2>&1 || bad "$t starting->running"
done
check "taskA starts owned by C1" "$(read_task run1 taskA | jq -r .conductor_pane_id)" "$C1"

printf '== pane_is_conductor_eligible (#252/P3): the shared conductor-eligibility check, standalone ==\n'
_eligible() { pane_is_conductor_eligible "$1" 2>/dev/null && echo eligible || echo refused; }
check "a plain unregistered live pane is eligible" "$(_eligible "$C2")" "eligible"
check "a registered worker's own active pane is refused" "$(_eligible "$W1")" "refused"
check "a non-agent pane is refused" "$(_eligible "$SH")" "refused"
FAIL_PANE_LIST=1
check "a herdr read failure is refused, not treated as eligible" "$(_eligible "$C2")" "refused"
unset FAIL_PANE_LIST

printf '== lib/run-registry.sh set_task_conductor: the raw CAS ==\n'
set_task_conductor run1 taskC "$C1" "$C1B" "$C2" "$C2B" "conductor_$C2" "conductor_$C1" "unit test" \
  || bad "a correct from/birth CAS was refused"
check "taskC's conductor is now C2" "$(read_task run1 taskC | jq -r .conductor_pane_id)" "$C2"
check "conductor_handover event recorded" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='taskC' AND type='conductor_handover';")" "1"
check "event payload names from/to" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.from')||'->'||json_extract(payload,'\$.to') FROM events WHERE task_id='taskC' AND type='conductor_handover';")" \
  "$C1->$C2"

printf '== stale from (CAS miss): refused, no event, row untouched ==\n'
if set_task_conductor run1 taskC "$C1" "$C1B" "$MAIN" "$MAINB" "conductor_$MAIN" "conductor_$C1" "stale" 2>/dev/null; then
  bad "a stale from-pane (taskC's conductor already moved to C2) was accepted"
else
  ok "stale from-pane refused"
fi
check "taskC's conductor is still C2" "$(read_task run1 taskC | jq -r .conductor_pane_id)" "$C2"
check "no second conductor_handover event for the stale attempt" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='taskC' AND type='conductor_handover';")" "1"

printf '== two concurrent handovers of the same task: exactly one wins ==\n'
reg taskRace "$C1" "$C1B" "w7:p1" "w7b" || bad "register taskRace"
set_task_state run1 taskRace running >/dev/null 2>&1
r1=0; r2=0
set_task_conductor run1 taskRace "$C1" "$C1B" "$C2" "$C2B" "conductor_$C2" by "race" || r1=1
set_task_conductor run1 taskRace "$C1" "$C1B" "$MAIN" "$MAINB" "conductor_$MAIN" by "race" || r2=1
check "exactly one of the two same-from CAS attempts won" "$((r1 + r2))" "1"
check "taskRace landed on the winner, C2" "$(read_task run1 taskRace | jq -r .conductor_pane_id)" "$C2"

printf '== terminal task: refused ==\n'
reg taskDone "$C1" "$C1B" "w8:p1" "w8b" || bad "register taskDone"
set_task_state run1 taskDone running >/dev/null 2>&1
set_task_state run1 taskDone completed no-follow-on >/dev/null 2>&1 || bad "could not close taskDone"
if set_task_conductor run1 taskDone "$C1" "$C1B" "$C2" "$C2B" "conductor_$C2" by "x" 2>/dev/null; then
  bad "a terminal task accepted a conductor handover"
else
  ok "terminal task refused the CAS (state not IN starting/running/blocked)"
fi

printf '== CLI: current live conductor hands its own task to a live non-worker pane ==\n'
out="$(CALLER_PANE="$C1" ch --task taskA --to "$C2" --reason "stalled conductor, 2026-10-07")"; rc=$?
check "exit 0" "$rc" "0"
check "taskA's conductor is now C2" "$(read_task run1 taskA | jq -r .conductor_pane_id)" "$C2"
check "taskA's conductor_pane_birth is now C2's live birth" "$(read_task run1 taskA | jq -r .conductor_pane_birth)" "$C2B"

printf '== herdr-select.sh conductor check, replicated: passes for C2, fails for C1 ==\n'
# The same comparison herdr-select.sh:282-293 makes before answering a
# `--authority conductor` prompt: task_for_pane's recorded owner must equal
# the live caller pane AND its live birth.
select_conductor_ok() {                 # <claimed-caller-pane> <claimed-caller-birth> -> ok|refused
  local t owner_pane owner_birth
  t="$(task_for_pane "$W1")"
  owner_pane="$(printf '%s' "$t" | jq -r '.conductor_pane_id // empty')"
  owner_birth="$(printf '%s' "$t" | jq -r '.conductor_pane_birth // empty')"
  if [ "$owner_pane" = "$1" ] && [ -n "$owner_birth" ] && [ "$owner_birth" = "$2" ]; then
    echo ok
  else
    echo refused
  fi
}
check "the NEW conductor (C2) can now answer taskA's worker pane" "$(select_conductor_ok "$C2" "$C2B")" "ok"
check "the OLD conductor (C1) can no longer answer it" "$(select_conductor_ok "$C1" "$C1B")" "refused"

printf '== CLI: the old conductor can no longer hand over a task it already gave away ==\n'
out2="$(CALLER_PANE="$C1" ch --task taskA --to "$MAIN" --reason "double handover" 2>&1)"; rc2=$?
[ "$rc2" -ne 0 ] && ok "exit nonzero: ex-conductor refused" || bad "ex-conductor's second handover was accepted (rc=$rc2)"
check "taskA's conductor is still C2" "$(read_task run1 taskA | jq -r .conductor_pane_id)" "$C2"

printf '== CLI: Main hands over ANY task, not just its own; both sides get a tagged notify ==\n'
: > "$SENT"
out3="$(CALLER_PANE="$MAIN" ch --task taskB --to "$C2" --reason "main reassign")"; rc3=$?
check "exit 0" "$rc3" "0"
check "taskB's conductor is now C2" "$(read_task run1 taskB | jq -r .conductor_pane_id)" "$C2"
check "old conductor (C1) got exactly one notify, no wake (taskB wasn't blocked)" \
  "$(grep -c "^send-text $C1\$" "$SENT")" "1"
check "new conductor (C2) got exactly one notify, no wake (taskB wasn't blocked)" \
  "$(grep -c "^send-text $C2\$" "$SENT")" "1"
grep -q '\[handover\]' "$WORK/wake_$(_fsafe "$C1").txt" \
  && ok "old conductor's message is tagged [handover]" \
  || bad "old conductor's message missing [handover] tag: $(cat "$WORK/wake_$(_fsafe "$C1").txt" 2>/dev/null)"
grep -q '\[handover\]' "$WORK/wake_$(_fsafe "$C2").txt" \
  && ok "new conductor's message is tagged [handover]" \
  || bad "new conductor's message missing [handover] tag: $(cat "$WORK/wake_$(_fsafe "$C2").txt" 2>/dev/null)"

printf '== CLI: a non-conductor, non-Main caller is refused ==\n'
out4="$(CALLER_PANE="$OTHER" ch --task taskD --to "$C2" --reason "squatting" 2>&1)"; rc4=$?
[ "$rc4" -ne 0 ] && ok "exit nonzero" || bad "a random live pane's handover was accepted"
check "taskD's conductor is unchanged" "$(read_task run1 taskD | jq -r .conductor_pane_id)" "$C1"

printf "== CLI: a worker caller (its real ancestry traces to its own active pane) is refused ==\n"
out5="$(CALLER_PANE="$W1" ch --task taskD --to "$C2" --reason "self-serve" 2>&1)"; rc5=$?
check "exit 4" "$rc5" "4"
check "taskD's conductor is unchanged" "$(read_task run1 taskD | jq -r .conductor_pane_id)" "$C1"

printf "== CLI: a worker spoofing HERDR_PANE_ID=<Main> is still refused — identity comes from ancestry, not env ==\n"
out6="$(CALLER_PANE="$W1" HERDR_PANE_ID="$MAIN" ch --task taskD --to "$C2" --reason "spoofed env" 2>&1)"; rc6=$?
check "exit 4" "$rc6" "4"
check "taskD's conductor is unchanged" "$(read_task run1 taskD | jq -r .conductor_pane_id)" "$C1"

printf "== CLI: a herdr ancestry-read failure refuses the caller, never guesses ==\n"
out6b="$(FAIL_PANE_LIST=1 CALLER_PANE="$C1" ch --task taskD --to "$C2" --reason "herdr down" 2>&1)"; rc6b=$?
check "exit 3" "$rc6b" "3"
check "taskD's conductor is unchanged" "$(read_task run1 taskD | jq -r .conductor_pane_id)" "$C1"

printf "== CLI: the target must not be a registered worker's own active pane ==\n"
out7="$(CALLER_PANE="$C1" ch --task taskD --to "$W2" --reason "bad target" 2>&1)"; rc7=$?
[ "$rc7" -ne 0 ] && ok "exit nonzero: worker-pane target refused" || bad "a worker pane was accepted as a handover target"
check "taskD's conductor is unchanged" "$(read_task run1 taskD | jq -r .conductor_pane_id)" "$C1"

printf '== CLI: a dead target pane is refused ==\n'
out8="$(CALLER_PANE="$C1" ch --task taskD --to "nope:p9" --reason "dead target" 2>&1)"; rc8=$?
[ "$rc8" -ne 0 ] && ok "exit nonzero: dead target refused" || bad "a dead pane was accepted as a handover target"
check "taskD's conductor is unchanged" "$(read_task run1 taskD | jq -r .conductor_pane_id)" "$C1"

printf '== CLI: --dry-run changes nothing ==\n'
dry_events_before="$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='taskE' AND type='conductor_handover';")"
: > "$SENT"
out9="$(CALLER_PANE="$C1" ch --task taskE --to "$C2" --reason "dry run" --dry-run)"; rc9=$?
check "exit 0" "$rc9" "0"
printf '%s\n' "$out9" | grep -q 'DRY RUN' || bad "dry-run output did not say DRY RUN: $out9"
check "taskE's conductor is unchanged" "$(read_task run1 taskE | jq -r .conductor_pane_id)" "$C1"
check "no conductor_handover event written" \
  "$(sqlite3 "$(registry_db)" "SELECT count(*) FROM events WHERE task_id='taskE' AND type='conductor_handover';")" \
  "$dry_events_before"
check "dry-run sent no notify at all" "$(wc -l < "$SENT" | tr -d ' ')" "0"

printf "== re-wake: a blocked task's pending prompt is re-delivered to the new conductor ==\n"
set_task_state run1 taskF blocked >/dev/null 2>&1 || bad "taskF running->blocked"
append_event run1 taskF input_required \
  "$(jq -nc '{message:"needs review", prompt_id:"promptF1", command:"git push", tool:"bash"}')" >/dev/null
: > "$SENT"
outF="$(CALLER_PANE="$C1" ch --task taskF --to "$C2" --reason "blocked conductor")"; rcF=$?
check "exit 0" "$rcF" "0"
check "taskF's conductor is now C2" "$(read_task run1 taskF | jq -r .conductor_pane_id)" "$C2"
check "the new conductor (C2) got the re-delivered wake PLUS the notify (2 sends)" \
  "$(grep -c "^send-text $C2\$" "$SENT")" "2"
check "the old conductor (C1) got only the notify, no wake" \
  "$(grep -c "^send-text $C1\$" "$SENT")" "1"
check "wake_attempted recorded against the new conductor pane" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.conductor_pane') FROM events WHERE task_id='taskF' AND type='wake_attempted' ORDER BY sequence DESC LIMIT 1;")" \
  "$C2"
check "wake_result recorded submitted (delivered through send-to-agent.sh, not a new sender)" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.outcome') FROM events WHERE task_id='taskF' AND type='wake_result' ORDER BY sequence DESC LIMIT 1;")" \
  "submitted"

printf "== F1 (security review PR #253): a LATER prompt wakes the NEW conductor even with a stale env HERDR_CONDUCTOR_PANE_ID ==\n"
# A worker's HERDR_CONDUCTOR_PANE_ID is stamped once at spawn and never
# updated — after the handover above, taskF's own hook calls still carry
# the OLD conductor pane (C1) in that env var. push_wake must now read
# conductor_pane_id off the CURRENT registry row (C2, set by the handover)
# instead of trusting it, or every later prompt refuses as
# "conductor_pane_recycled" once C1's birth stops matching C2's.
# HERDR_ALERT_FORCE=1 isolates the cpane-resolution bug from alert-gate's
# separate hold/allow-class classification, which is not what this proves.
: > "$SENT"
(
  export HERDR_RUN_ID=run1 HERDR_TASK_ID=taskF HERDR_PANE_ID=w6:p1 \
         HERDR_CONDUCTOR_PANE_ID="$C1" HERDR_TASK_LABEL=impl:taskF HERDR_ALERT_FORCE=1
  push_wake "second prompt after handover" "" "" "bash"
)
rcW=$?
check "exit 0 (delivered)" "$rcW" "0"
check "woken the NEW conductor (C2), not the stale env pane (C1)" \
  "$(grep -c "^send-text $C2\$" "$SENT")" "1"
check "nothing sent to the stale env pane (C1)" "$(grep -c "^send-text $C1\$" "$SENT")" "0"
check "wake_attempted recorded against the NEW conductor pane, not the stale env one" \
  "$(sqlite3 "$(registry_db)" "SELECT json_extract(payload,'\$.conductor_pane') FROM events WHERE task_id='taskF' AND type='wake_attempted' ORDER BY sequence DESC LIMIT 1;")" \
  "$C2"


printf '== help text and bad usage ==\n'
ch --help >/dev/null; check "exit 0" "$?" "0"
ch --to "$C2" --reason x >/dev/null 2>&1; check "neither --task nor --from: exit 2" "$?" "2"
CALLER_PANE="$C1" ch --task taskD --from "$C1" --to "$C2" --reason x >/dev/null 2>&1
check "both --task and --from: exit 2" "$?" "2"
CALLER_PANE="$C1" ch --task taskD --to "$C2" >/dev/null 2>&1
check "no --reason: exit 2" "$?" "2"

echo "-----"; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
