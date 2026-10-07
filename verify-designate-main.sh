#!/usr/bin/env bash
# verify-designate-main.sh — P3 (.handoffs/SPEC.md feat/main-designation-lock):
# designate-main.sh now stores Main as a CAS-guarded row in the registry's
# `owners` table (label "main") instead of a plain file, and enforces WHO may
# change the designation: self-designation only when no live Main exists or
# the caller already IS it, a live Main's own --handoff-to another live
# non-worker pane, or a human --force from a real tty with no HERDR_TASK_ID.
# A worker (HERDR_TASK_ID set, or a registered task's own active pane) may
# never change it. config.sh still reads the designation (now from the same
# table, via a direct sqlite3 query) whenever HERDR_MAIN_PANE_ID is unset.
# herdr is a stubbed function; the registry is a throwaway HERDR_RUN_STATE_DIR.
#
#   bash verify-designate-main.sh
set -uo pipefail
# This suite's OWN process may itself be a registered worker (HERDR_TASK_ID
# set by whatever spawned it) -- that must never leak into the fake panes
# below, or every "not a worker" case here would spuriously refuse.
unset HERDR_TASK_ID HERDR_RUN_ID
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

export HERDR_RUN_STATE_DIR="$(mktemp -d)/runs"

# ---- the fake herdr: panes are plain labels (no ':' — stays a valid var
# name), looked up via env indirection so a test can move a pane's birth
# (recycled-pane case) or flip whether it's agent-shaped mid-suite. ----------
export BIRTH_M1=gen_m1 BIRTH_M2=gen_m2 BIRTH_SH=gen_sh BIRTH_W1=gen_w1 \
       BIRTH_H1=gen_h1 BIRTH_F1=gen_f1 BIRTH_R1=gen_r1_a
export AGENT_M1=1 AGENT_M2=1 AGENT_SH=0 AGENT_W1=1 AGENT_H1=1 AGENT_F1=1 AGENT_R1=1
herdr() {
  case "$1 $2" in
    "pane list")
      local first=1 p b
      printf '{"result":{"panes":['
      for p in M1 M2 SH W1 H1 F1 R1; do
        eval "b=\${BIRTH_$p:-}"
        [ -n "$b" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"pane_id":"%s","terminal_id":"%s"}' "$p" "$b"
      done
      printf ']}}\n' ;;
    "pane process-info")
      local pane="$4" ag
      eval "ag=\${AGENT_$pane:-0}"
      if [ "$ag" = "1" ]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model x"}]}}}\n'
      else
        printf '{"result":{"process_info":{"foreground_processes":[]}}}\n'
      fi ;;
    *) printf '{}\n' ;;
  esac
}
export -f herdr

# dm [designate-main.sh flags...] — env var OVERRIDES (HERDR_PANE_ID=..., etc.)
# belong on the CALLER's side of this, e.g. `HERDR_PANE_ID=M1 dm --show`.
dm() { env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH bash "$here/designate-main.sh" "$@"; }
cfg() { env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH "$@" bash -c '. "$1/config.sh"; printf "%s|%s" "$HERDR_MAIN_PANE_ID" "$HERDR_MAIN_PANE_BIRTH"' _ "$here"; }
q() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$1" 2>/dev/null; }
owners_row() { q "SELECT pane_id||' '||pane_birth FROM owners WHERE label='main';"; }
event_count() { q "SELECT count(*) FROM events WHERE type='$1';"; }
last_event() { q "SELECT payload FROM events WHERE type='$1' ORDER BY sequence DESC LIMIT 1;"; }

# A registered, currently-active worker's own pane (task_for_pane state=running).
reg_worker() {         # pane birth
  bash -c '. "$1/lib/run-registry.sh"
    register_task run1 taskW worker1 cond_x "" "" "$2" "$3" /repo /wt impl:taskW feat/w main "" "" hook >/dev/null
    set_task_state run1 taskW running >/dev/null' _ "$here" "$1" "$2"
}

printf '== nothing designated -> config.sh leaves Main empty ==\n'
check "empty without a designation" "$(cfg)" "|"
check "--show with nothing designated" "$(dm --show)" "(no Main designated)"

printf '== a shell (non-agent) pane is refused, nothing written ==\n'
HERDR_PANE_ID=SH dm >/dev/null 2>/tmp/dm_err.txt; rc=$?
check "exit 3 for a non-agent pane" "$rc" "3"
[ -z "$(owners_row)" ] && ok "no owners row for a shell pane" || bad "owners row written for a shell pane: $(owners_row)"

printf '== an agent pane self-designates: owners row + config.sh pick it up ==\n'
HERDR_PANE_ID=M1 dm >/dev/null 2>&1; rc=$?
check "exit 0 for this pane" "$rc" "0"
check "owners row holds pane + birth" "$(owners_row)" "M1 gen_m1"
check "config.sh picks it up when env is unset" "$(cfg)" "M1|gen_m1"
check "an explicit env value still wins" "$(cfg HERDR_MAIN_PANE_ID=X9 HERDR_MAIN_PANE_BIRTH=b9)" "X9|b9"
check "an EMPTY env value falls back to the table (launchd exports it empty)" \
  "$(HERDR_MAIN_PANE_ID= bash -c '. "$1/config.sh"; printf "%s" "$HERDR_MAIN_PANE_ID"' _ "$here")" "M1"
check "main_designated event recorded, by self" "$(last_event main_designated | jq -r '.by')" "M1"

printf '== a worker is refused even from an otherwise-eligible agent pane ==\n'
# W1 is agent-shaped but currently a registered task's own ACTIVE pane.
reg_worker W1 gen_w1
HERDR_PANE_ID=W1 dm >/dev/null 2>&1; rc=$?
check "exit 3: registered active worker pane refused" "$rc" "3"
HERDR_PANE_ID=H1 HERDR_TASK_ID=some_task dm >/dev/null 2>&1; rc=$?
check "exit 3: HERDR_TASK_ID set refuses even an unregistered agent pane" "$rc" "3"
check "Main is still M1 (neither worker attempt changed it)" "$(owners_row)" "M1 gen_m1"

printf '== a live Main exists: a DIFFERENT pane may not self-designate ==\n'
pre_refused="$(event_count main_designation_refused)"
HERDR_PANE_ID=M2 dm >/dev/null 2>&1; rc=$?
check "exit 4: a different pane is refused while Main is live" "$rc" "4"
check "Main is unchanged" "$(owners_row)" "M1 gen_m1"
post_refused="$(event_count main_designation_refused)"
[ "$post_refused" -eq $((pre_refused + 1)) ] \
  && ok "main_designation_refused recorded" || bad "refusal not recorded ($pre_refused -> $post_refused)"

printf '== the live Main re-designating ITSELF is always allowed (idempotent) ==\n'
HERDR_PANE_ID=M1 dm >/dev/null 2>&1; rc=$?
check "exit 0: Main re-designating itself" "$rc" "0"
check "owners row unchanged" "$(owners_row)" "M1 gen_m1"

printf '== a recycled pane (same id, new birth) counts as Main being GONE ==\n'
q "DELETE FROM owners WHERE label='main';" >/dev/null
HERDR_PANE_ID=R1 dm >/dev/null 2>&1
check "R1 becomes Main at its first birth" "$(owners_row)" "R1 gen_r1_a"
export BIRTH_R1=gen_r1_b   # the pane id is reused by a NEW occupant: different birth
HERDR_PANE_ID=M1 dm >/dev/null 2>&1; rc=$?
check "exit 0: a stale (recycled) Main is treated as gone, any eligible pane may take over" "$rc" "0"
check "M1 is the new Main" "$(owners_row)" "M1 gen_m1"
q "DELETE FROM owners WHERE label='main';" >/dev/null

printf '== --handoff-to: only the live Main may hand off, to a live non-worker pane ==\n'
HERDR_PANE_ID=M1 dm >/dev/null 2>&1
HERDR_PANE_ID=M2 dm --handoff-to H1 >/dev/null 2>&1; rc=$?
check "exit 4: a non-Main pane cannot hand off" "$rc" "4"
check "Main unchanged by the refused handoff" "$(owners_row)" "M1 gen_m1"
HERDR_PANE_ID=M1 dm --handoff-to W1 >/dev/null 2>&1; rc=$?
check "exit 3: handoff to a registered active worker pane refused" "$rc" "3"
HERDR_PANE_ID=M1 dm --handoff-to SH >/dev/null 2>&1; rc=$?
check "exit 3: handoff to a non-agent pane refused" "$rc" "3"
HERDR_PANE_ID=M1 dm --handoff-to H1 >/dev/null 2>&1; rc=$?
check "exit 0: the live Main hands off to an eligible pane" "$rc" "0"
check "Main is now H1" "$(owners_row)" "H1 gen_h1"
check "main_designated handoff event: from M1 to H1" \
  "$(last_event main_designated | jq -c '{from,to,reason}')" '{"from":"M1","to":"H1","reason":"handoff"}'

printf '== --clear: only the live Main (or --force) may clear ==\n'
HERDR_PANE_ID=M2 dm --clear >/dev/null 2>&1; rc=$?
check "exit 4: a non-Main pane cannot clear" "$rc" "4"
check "Main unchanged by the refused clear" "$(owners_row)" "H1 gen_h1"
HERDR_PANE_ID=H1 dm --clear >/dev/null 2>&1; rc=$?
check "exit 0: the live Main clears itself" "$rc" "0"
[ -z "$(owners_row)" ] && ok "owners row removed" || bad "owners row still present: $(owners_row)"
check "config.sh empty again after --clear" "$(cfg)" "|"
HERDR_PANE_ID=M2 dm --clear >/dev/null 2>&1; rc=$?
check "exit 0: clearing with no live Main is a harmless no-op from any pane" "$rc" "0"

printf '== --force: human-only override, refused from an agent/task context ==\n'
HERDR_PANE_ID=M1 HERDR_TASK_ID=taskX dm --force --reason "stuck" F1 </dev/null >/dev/null 2>&1; rc=$?
check "exit 3: --force refused when HERDR_TASK_ID is set" "$rc" "3"
HERDR_PANE_ID=M1 dm --force --reason "stuck" F1 </dev/null >/dev/null 2>&1; rc=$?
check "exit 3: --force refused when stdin is not a tty" "$rc" "3"
check "nothing designated by either refused --force" "$(owners_row)" ""
if command -v script >/dev/null 2>&1; then
  # Re-designate a live Main first, then force over it from a genuine tty
  # with no HERDR_TASK_ID — the one allowed shape.
  HERDR_PANE_ID=M1 dm >/dev/null 2>&1
  script -q /dev/null env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH -u HERDR_TASK_ID \
    HERDR_PANE_ID=M1 bash "$here/designate-main.sh" --force --reason "stuck Main, forcing F1" F1 \
    >/tmp/dm_force.out 2>&1
  rc=$?
  check "exit 0: --force from a real tty, no HERDR_TASK_ID, overrides a live Main" "$rc" "0"
  check "Main is now F1 (forced over the still-live M1)" "$(owners_row)" "F1 gen_f1"
  check "main_designated event recorded by=human-force" "$(last_event main_designated | jq -r '.by')" "human-force"
  rm -f /tmp/dm_force.out
else
  bad "script(1) unavailable — cannot prove the --force SUCCESS path on this host"
fi
q "DELETE FROM owners WHERE label='main';" >/dev/null

printf '== concurrent self-designation when no Main exists: exactly one wins ==\n'
HERDR_PANE_ID=M1 dm >/tmp/dm_race_m1.out 2>&1 &
pid1=$!
HERDR_PANE_ID=M2 dm >/tmp/dm_race_m2.out 2>&1 &
pid2=$!
wait "$pid1"; rc1=$?
wait "$pid2"; rc2=$?
winners=0
[ "$rc1" = 0 ] && winners=$((winners+1))
[ "$rc2" = 0 ] && winners=$((winners+1))
check "exactly one of the two racing panes wins" "$winners" "1"
winner_row="$(owners_row)"
case "$winner_row" in
  "M1 gen_m1"|"M2 gen_m2") ok "the owners row holds exactly the winner: $winner_row" ;;
  *) bad "owners row is neither racer cleanly: $winner_row" ;;
esac
rm -f /tmp/dm_race_m1.out /tmp/dm_race_m2.out
q "DELETE FROM owners WHERE label='main';" >/dev/null

printf '== the escalation path still refuses a recycled pane (POSITIVE-birth-mismatch-only) ==\n'
HERDR_PANE_ID=M1 dm >/dev/null 2>&1
reachable() {
  bash -c '. "$1/config.sh"; . "$1/lib/pane-guard.sh"
    [ -n "$HERDR_MAIN_PANE_ID" ] && pane_is_agent "$HERDR_MAIN_PANE_ID" || { echo unreachable; exit; }
    live=$(pane_birth_now "$HERDR_MAIN_PANE_ID")
    [ -n "$HERDR_MAIN_PANE_BIRTH" ] && [ -n "$live" ] && [ "$live" != "$HERDR_MAIN_PANE_BIRTH" ] && { echo refused; exit; }
    echo deliver' _ "$here"
}
check "designated live Main -> deliver" "$(env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH bash -c "$(declare -f reachable); here='$here'; reachable")" "deliver"
check "same pane id, new occupant (recycled) -> refused" \
  "$(env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH BIRTH_M1=gen_m1_recycled bash -c "$(declare -f reachable); here='$here'; reachable")" "refused"

printf '== the REAL controller reads the designation (owners table -> attention-tick.sh seam) ==\n'
check "sourcing attention-tick.sh with no env yields the designated Main" \
  "$(env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH bash -c '. "$1/attention-tick.sh"; printf "%s|%s" "$HERDR_MAIN_PANE_ID" "$HERDR_MAIN_PANE_BIRTH"' _ "$here")" "M1|gen_m1"

printf '== a failed write is reported, not a false success ==\n'
ro="$(mktemp -d)"; chmod 500 "$ro"
HERDR_RUN_STATE_DIR="$ro/runs" HERDR_PANE_ID=M1 env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH \
  bash "$here/designate-main.sh" >/tmp/dm_rofail.out 2>&1
rc=$?
[ "$rc" != "0" ] && ok "non-zero exit when the registry directory cannot be created (rc=$rc)" \
  || bad "falsely succeeded against an unwritable registry dir: $(cat /tmp/dm_rofail.out)"
chmod 700 "$ro"; rm -rf "$ro" /tmp/dm_rofail.out /tmp/dm_err.txt

echo "-----"; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
