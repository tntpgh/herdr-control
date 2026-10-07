#!/usr/bin/env bash
# verify-designate-main.sh — P3 (.handoffs/SPEC.md feat/main-designation-lock):
# designate-main.sh stores Main as a CAS-guarded row in the registry's OWN
# `roles` table (label "main" — a separate table from the shared `owners`
# table, security review PR #252 F1) and resolves its CALLER from REAL
# process ancestry (lib/pane-guard.sh's caller_pane_from_ancestry), never
# from self-asserted HERDR_PANE_ID/HERDR_TASK_ID (F2). --force requires that
# ancestry walk to find NO herdr-tracked pane at all, not merely a tty (F3).
# Every write reuses ONE read as its CAS pre-image (F4); every herdr/registry
# read failure refuses rather than silently permits (F5); config.sh's
# registry row wins over env unless no row exists (F6).
#
# herdr is a stubbed function; the registry is a throwaway HERDR_RUN_STATE_DIR.
# Caller identity is impersonated by making a fake pane's reported foreground
# pid equal a REAL ancestor of the test process (SELF_PID=$$ for everything
# single-process; the two genuinely-concurrent racers derive their own real
# subshell pid via `ps`, bash 3.2 having no $BASHPID) -- ancestry walking
# itself is never stubbed, only what herdr reports about which pane owns
# which pid.
#
#   bash verify-designate-main.sh
set -uo pipefail
# This suite's OWN process may itself be a registered worker (HERDR_TASK_ID
# set by whatever spawned it) -- irrelevant to designate-main.sh now (it
# never reads HERDR_TASK_ID), kept unset anyway so nothing here accidentally
# depends on it.
unset HERDR_TASK_ID HERDR_RUN_ID HERDR_PANE_ID
here=$(cd "$(dirname "$0")" && pwd)
SELF_PID=$$
pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

export HERDR_RUN_STATE_DIR="$(mktemp -d)/runs"

# ---- the fake herdr: panes are plain labels (no ':' — stays a valid var
# name), looked up via env indirection. PID_<pane> is the pid herdr reports
# as that pane's current foreground job; identity tests set exactly ONE
# pane's PID_* to a real ancestor of the invoking process (SELF_PID or, for
# the two-racer concurrency test, each racer's own real subshell pid) so
# caller_pane_from_ancestry resolves to that one pane and no other.
# FAIL_LIST/FAIL_INFO simulate a herdr call itself failing (F5).
export BIRTH_M1=gen_m1 BIRTH_M2=gen_m2 BIRTH_SH=gen_sh BIRTH_W1=gen_w1 \
       BIRTH_H1=gen_h1 BIRTH_F1=gen_f1 BIRTH_R1=gen_r1_a BIRTH_A=gen_a BIRTH_B=gen_b
export AGENT_M1=1 AGENT_M2=1 AGENT_SH=0 AGENT_W1=1 AGENT_H1=1 AGENT_F1=1 AGENT_R1=1 AGENT_A=1 AGENT_B=1
reset_pids() {
  local p
  for p in M1 M2 SH W1 H1 F1 R1 A B; do eval "export PID_$p=0"; done
}
# Exactly this pane's foreground job is a REAL ancestor of the calling
# process -- the only pane caller_pane_from_ancestry will resolve to.
caller_is() { reset_pids; eval "export PID_$1=\$SELF_PID"; }
reset_pids

herdr() {
  case "$1 $2" in
    "pane list")
      [ -z "${FAIL_LIST:-}" ] || return 1
      local first=1 p b
      printf '{"result":{"panes":['
      for p in M1 M2 SH W1 H1 F1 R1 A B; do
        eval "b=\${BIRTH_$p:-}"
        [ -n "$b" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"pane_id":"%s","terminal_id":"%s","label":"%s"}' "$p" "$b" "$p"
      done
      printf ']}}\n' ;;
    "pane process-info")
      [ -z "${FAIL_INFO:-}" ] || return 1
      local pane="$4" ag pid name
      eval "ag=\${AGENT_$pane:-0}"
      eval "pid=\${PID_$pane:-0}"
      if [ "$ag" = "1" ]; then name=omp; else name=bash; fi
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"%s","cmdline":"%s x","pid":%s}]}}}\n' \
        "$name" "$name" "$pid" ;;
    *) printf '{}\n' ;;
  esac
}
export -f herdr

dm() { bash "$here/designate-main.sh" "$@"; }
cfg() { env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH "$@" bash -c '. "$1/config.sh"; printf "%s|%s" "$HERDR_MAIN_PANE_ID" "$HERDR_MAIN_PANE_BIRTH"' _ "$here"; }
q() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$1" 2>/dev/null; }
role_row() { q "SELECT pane_id||' '||pane_birth FROM roles WHERE label='main';"; }
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

printf '== caller identity cannot be resolved (no pane traces here): refused, nothing written (F2) ==\n'
reset_pids
dm >/dev/null 2>/tmp/dm_err.txt; rc=$?
check "exit 3 when no herdr pane traces to the caller" "$rc" "3"
[ -z "$(role_row)" ] && ok "no roles row written" || bad "roles row written with no resolvable caller: $(role_row)"

printf '== a shell (non-agent) pane, resolvable via ancestry, is refused ==\n'
caller_is SH
dm >/dev/null 2>/tmp/dm_err.txt; rc=$?
check "exit 3 for a non-agent pane" "$rc" "3"
[ -z "$(role_row)" ] && ok "no roles row for a shell pane" || bad "roles row written for a shell pane: $(role_row)"

printf '== an agent pane self-designates: roles row + config.sh pick it up ==\n'
caller_is M1
dm >/dev/null 2>&1; rc=$?
check "exit 0 for this pane" "$rc" "0"
check "roles row holds pane + birth" "$(role_row)" "M1 gen_m1"
check "config.sh picks it up when env is unset" "$(cfg)" "M1|gen_m1"
check "the registry row WINS over an explicit env value (F6)" "$(cfg HERDR_MAIN_PANE_ID=X9 HERDR_MAIN_PANE_BIRTH=b9)" "M1|gen_m1"
check "an EMPTY env value also yields the row" \
  "$(HERDR_MAIN_PANE_ID= bash -c '. "$1/config.sh"; printf "%s" "$HERDR_MAIN_PANE_ID"' _ "$here")" "M1"
check "main_designated event recorded, by self" "$(last_event main_designated | jq -r '.by')" "M1"

printf '== a worker is refused even from an otherwise-eligible, ancestry-resolvable agent pane ==\n'
# W1 is agent-shaped but currently a registered task's own ACTIVE pane.
reg_worker W1 gen_w1
caller_is W1
dm >/dev/null 2>&1; rc=$?
check "exit 3: registered active worker pane refused" "$rc" "3"
check "Main is still M1 (the worker attempt did not change it)" "$(role_row)" "M1 gen_m1"

printf '== a live Main exists: a DIFFERENT ancestry-resolved pane may not self-designate ==\n'
pre_refused="$(event_count main_designation_refused)"
caller_is M2
dm >/dev/null 2>&1; rc=$?
check "exit 4: a different pane is refused while Main is live" "$rc" "4"
check "Main is unchanged" "$(role_row)" "M1 gen_m1"
post_refused="$(event_count main_designation_refused)"
[ "$post_refused" -eq $((pre_refused + 1)) ] \
  && ok "main_designation_refused recorded" || bad "refusal not recorded ($pre_refused -> $post_refused)"

printf '== the live Main re-designating ITSELF is always allowed (idempotent) ==\n'
caller_is M1
dm >/dev/null 2>&1; rc=$?
check "exit 0: Main re-designating itself" "$rc" "0"
check "roles row unchanged" "$(role_row)" "M1 gen_m1"

printf '== a recycled pane (same id, new birth) counts as Main being GONE ==\n'
q "DELETE FROM roles WHERE label='main';" >/dev/null
caller_is R1
dm >/dev/null 2>&1
check "R1 becomes Main at its first birth" "$(role_row)" "R1 gen_r1_a"
export BIRTH_R1=gen_r1_b   # the pane id is reused by a NEW occupant: different birth
caller_is M1
dm >/dev/null 2>&1; rc=$?
check "exit 0: a stale (recycled) Main is treated as gone, any eligible pane may take over" "$rc" "0"
check "M1 is the new Main" "$(role_row)" "M1 gen_m1"
q "DELETE FROM roles WHERE label='main';" >/dev/null

printf '== --handoff-to: only the live Main may hand off, to a live non-worker pane ==\n'
caller_is M1; dm >/dev/null 2>&1
caller_is M2
dm --handoff-to H1 >/dev/null 2>&1; rc=$?
check "exit 4: a non-Main pane cannot hand off" "$rc" "4"
check "Main unchanged by the refused handoff" "$(role_row)" "M1 gen_m1"
caller_is M1
dm --handoff-to W1 >/dev/null 2>&1; rc=$?
check "exit 3: handoff to a registered active worker pane refused" "$rc" "3"
dm --handoff-to SH >/dev/null 2>&1; rc=$?
check "exit 3: handoff to a non-agent pane refused" "$rc" "3"
dm --handoff-to H1 >/dev/null 2>&1; rc=$?
check "exit 0: the live Main hands off to an eligible pane" "$rc" "0"
check "Main is now H1" "$(role_row)" "H1 gen_h1"
check "main_designated handoff event: from M1 to H1" \
  "$(last_event main_designated | jq -c '{from,to,reason}')" '{"from":"M1","to":"H1","reason":"handoff"}'

printf '== --clear: only the live Main may clear a LIVE row; a worker is refused even with no live Main (F2) ==\n'
caller_is M2
dm --clear >/dev/null 2>&1; rc=$?
check "exit 4: a non-Main pane cannot clear a live row" "$rc" "4"
check "Main unchanged by the refused clear" "$(role_row)" "H1 gen_h1"
caller_is H1
dm --clear >/dev/null 2>&1; rc=$?
check "exit 0: the live Main clears itself" "$rc" "0"
[ -z "$(role_row)" ] && ok "roles row removed" || bad "roles row still present: $(role_row)"
check "config.sh empty again after --clear" "$(cfg)" "|"
caller_is W1
dm --clear >/dev/null 2>&1; rc=$?
check "exit 3: a worker is refused --clear even with no live Main at all" "$rc" "3"
caller_is M2
dm --clear >/dev/null 2>&1; rc=$?
check "exit 0: a non-worker clearing with no live Main is a harmless no-op" "$rc" "0"

printf '== --force: requires NO herdr pane anywhere in this process ancestry (F3) ==\n'
caller_is M1
dm --force --reason "stuck" F1 </dev/null >/dev/null 2>&1; rc=$?
check "exit 3: --force refused when the caller traces to an agent pane (even Main itself)" "$rc" "3"
caller_is SH
dm --force --reason "stuck" F1 </dev/null >/dev/null 2>&1; rc=$?
check "exit 3: --force refused when the caller traces to ANY herdr pane, even a plain shell pane" "$rc" "3"
check "nothing designated by either refused --force" "$(role_row)" ""
reset_pids
dm --force --reason "stuck" W1 </dev/null >/dev/null 2>&1; rc=$?
check "exit 3: --force to a registered worker target refused even with no traceable caller" "$rc" "3"
reset_pids
dm --force --reason "stuck" F1 </dev/null >/dev/null 2>&1; rc=$?
check "exit 0: --force succeeds when NO herdr pane traces to the caller at all" "$rc" "0"
check "roles row is F1" "$(role_row)" "F1 gen_f1"
check "event recorded by human-force" "$(last_event main_designated | jq -r '.by')" "human-force"
q "DELETE FROM roles WHERE label='main';" >/dev/null

printf '== concurrent self-designation when no Main exists: exactly one wins ==\n'
# bash 3.2 (this host's /bin/bash) has no $BASHPID (added in bash 4) -- and
# $$ stays fixed at the TOP-level script's pid across a `()` subshell fork
# here (lib/command-policy.sh makes the same observation), so neither gives
# a subshell's own real OS pid. 3.2-safe trick: background a short-lived
# `sleep` and ask `ps` for ITS parent -- that parent is this subshell
# itself. (A no-op like `:` exits too fast: `ps` sometimes samples it after
# the kernel has already reaped it, reading back nothing.)
racer() {
  reset_pids
  sleep 2 & local bgpid=$!
  local mypid; mypid=$(ps -o ppid= -p "$bgpid" 2>/dev/null | tr -d ' ')
  kill "$bgpid" 2>/dev/null; wait "$bgpid" 2>/dev/null
  eval "export PID_$1=\$mypid"
  dm
}
( racer A ) >/tmp/dm_race_a.out 2>&1 &
pid1=$!
( racer B ) >/tmp/dm_race_b.out 2>&1 &
pid2=$!
wait "$pid1"; rc1=$?
wait "$pid2"; rc2=$?
winners=0
[ "$rc1" = 0 ] && winners=$((winners+1))
[ "$rc2" = 0 ] && winners=$((winners+1))
check "exactly one of the two racing panes wins" "$winners" "1"
winner_row="$(role_row)"
case "$winner_row" in
  "A gen_a"|"B gen_b") ok "the winner's own row is the one left standing ($winner_row)" ;;
  *) bad "unexpected roles row after the race: $winner_row" ;;
esac
rm -f /tmp/dm_race_a.out /tmp/dm_race_b.out
q "DELETE FROM roles WHERE label='main';" >/dev/null

printf '== F4: the CAS pre-image is read exactly once per command (structural) ==\n'
# Excludes the "_main_row | awk {print $1}" idiom: that pattern only
# names who the current Main is for a REFUSAL EVENT LOG line, on a branch
# that dies immediately after (never reaches a CAS write) -- unrelated to
# F4's actual concern, which is the read that FEEDS
# register_role_cas/unregister_role_cas's expected_pane/expected_birth
# (always the `<<<"$(_main_row)"` form below).
for fn in cmd_self cmd_handoff cmd_force cmd_clear; do
  n=$(awk -v f="$fn" '
    $0 ~ "^"f"\\(\\) \\{" {in_fn=1; next}
    in_fn && /^}/ {in_fn=0}
    in_fn && /_main_row \| awk/ {next}
    in_fn && /_main_row/ {c++}
    END {print c+0}
  ' "$here/designate-main.sh")
  [ "$n" -le 1 ] && ok "$fn's CAS pre-image read happens at most once (found $n)" \
    || bad "$fn's CAS pre-image is read $n times -- a second read can race the first (F4)"
done

printf '== F9: clear is a CAS, not an unconditional delete (structural) ==\n'
grep -q 'unregister_role_cas' "$here/designate-main.sh" \
  && ok "cmd_clear uses unregister_role_cas" \
  || bad "cmd_clear does not call unregister_role_cas"
grep -qE 'unregister_role[^_]|unregister_owner' "$here/designate-main.sh" \
  && bad "designate-main.sh still calls an unconditional unregister (not CAS-guarded)" \
  || ok "no unconditional unregister call remains"

printf '== F1: "main" is reserved -- register-owner.sh/register_owner refuse it outright, never reaching Main ==\n'
caller_is M1; dm >/dev/null 2>&1
q "DELETE FROM owners WHERE label='main';" >/dev/null 2>&1
bash "$here/register-owner.sh" main H1 >/dev/null 2>&1; rc=$?
check "register-owner.sh main H1 is refused (label 'main' is reserved for Main)" "$rc" "2"
check "the owners table holds no 'main' row" "$(q "SELECT pane_id FROM owners WHERE label='main';")" ""
check "designate-main.sh's view of Main is unaffected" "$(role_row)" "M1 gen_m1"
check "config.sh still resolves Main to M1" "$(cfg)" "M1|gen_m1"
q "DELETE FROM owners WHERE label='main';" >/dev/null 2>&1
q "DELETE FROM roles WHERE label='main';" >/dev/null 2>&1

printf '== F5: a failed herdr pane-list read during the liveness check must NOT read as "Main is gone" ==\n'
caller_is M1; dm >/dev/null 2>&1
caller_is M2
FAIL_LIST=1 dm >/dev/null 2>&1; rc=$?
check "exit 3 (or a fail-closed refusal, never 0): a herdr read failure never lets a different pane take over a live Main" "$rc" "3"
check "Main is still M1 — the failed read did not let M2 in" "$(role_row)" "M1 gen_m1"
q "DELETE FROM roles WHERE label='main';" >/dev/null

printf '== F5: an unreadable registry during the worker-eligibility check must refuse, not silently pass ==\n'
chmod 000 "$HERDR_RUN_STATE_DIR/registry.sqlite3"
caller_is M1
dm >/dev/null 2>/tmp/dm_err2.txt; rc=$?
chmod 644 "$HERDR_RUN_STATE_DIR/registry.sqlite3"
check "exit 3: an unreadable registry fails the eligibility check closed, never defaults to eligible" "$rc" "3"
rm -f /tmp/dm_err2.txt

printf '== the escalation path still refuses a recycled pane (POSITIVE-birth-mismatch-only) ==\n'
caller_is M1; dm >/dev/null 2>&1
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
q "DELETE FROM roles WHERE label='main';" >/dev/null

printf '== the REAL controller reads the designation (roles table -> attention-tick.sh seam) ==\n'
caller_is M1; dm >/dev/null 2>&1
check "sourcing attention-tick.sh with no env yields the designated Main" \
  "$(bash -c '. "$1/attention-tick.sh"; printf "%s|%s" "$HERDR_MAIN_PANE_ID" "$HERDR_MAIN_PANE_BIRTH"' _ "$here")" "M1|gen_m1"
q "DELETE FROM roles WHERE label='main';" >/dev/null

printf '== a failed write is reported, not a false success ==\n'
ro="$(mktemp -d)"; chmod 500 "$ro"
caller_is M1
HERDR_RUN_STATE_DIR="$ro/runs" bash "$here/designate-main.sh" >/tmp/dm_rofail.out 2>&1
rc=$?
[ "$rc" != "0" ] && ok "non-zero exit when the registry directory cannot be created (rc=$rc)" \
  || bad "falsely succeeded against an unwritable registry dir: $(cat /tmp/dm_rofail.out)"
chmod 700 "$ro"; rm -rf "$ro" /tmp/dm_rofail.out /tmp/dm_err.txt

echo "-----"; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
