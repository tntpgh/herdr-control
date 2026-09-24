#!/usr/bin/env bash
# verify-designate-main.sh — designate-main.sh records Main (pane + birth) only
# for a live agent pane; config.sh picks it up when HERDR_MAIN_PANE_ID is unset
# and an explicit env value still wins; the attention controller then escalates
# to the designated pane and refuses a stale designation (recycled pane).
# herdr is a stubbed function; the registry is a throwaway HERDR_RUN_STATE_DIR.
#
#   bash verify-designate-main.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

export HERDR_RUN_STATE_DIR="$(mktemp -d)/runs"
export MAIN_BIRTH="term_main_1"
# M1 is an agent pane (omp); SH is a bare shell (no foreground process).
herdr() {
  case "$1 $2" in
    "pane list") printf '{"result":{"panes":[{"pane_id":"M1","terminal_id":"%s"},{"pane_id":"SH","terminal_id":"term_sh"}]}}\n' "$MAIN_BIRTH" ;;
    "pane process-info")
      case "$4" in
        M1) printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model x"}]}}}\n' ;;
        *)  printf '{"result":{"process_info":{"foreground_processes":[]}}}\n' ;;
      esac ;;
    *) printf '{}\n' ;;
  esac
}
export -f herdr
role="$HERDR_RUN_STATE_DIR/roles/main"
cfg() { env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH "$@" bash -c '. "$1/config.sh"; printf "%s|%s" "$HERDR_MAIN_PANE_ID" "$HERDR_MAIN_PANE_BIRTH"' _ "$here"; }

printf '== nothing designated -> config.sh leaves Main empty ==\n'
check "empty without a designation" "$(cfg)" "|"

printf '== a shell pane is refused, nothing written ==\n'
bash "$here/designate-main.sh" SH >/dev/null 2>&1; check "exit 3 for a non-agent pane" "$?" "3"
[ -e "$role" ] && bad "role file written for a shell pane" || ok "no role file for a shell pane"

printf '== an agent pane is recorded with its birth ==\n'
HERDR_PANE_ID=M1 bash "$here/designate-main.sh" >/dev/null 2>&1; check "exit 0 for this pane" "$?" "0"
check "role file holds pane + birth" "$(cat "$role")" "M1 term_main_1"
check "config.sh picks it up when env is unset" "$(cfg)" "M1|term_main_1"
check "an explicit env value still wins" "$(cfg HERDR_MAIN_PANE_ID=X9 HERDR_MAIN_PANE_BIRTH=b9)" "X9|b9"
check "an EMPTY env value falls back to the file (launchd exports it empty)" \
  "$(HERDR_MAIN_PANE_ID= bash -c '. "$1/config.sh"; printf "%s" "$HERDR_MAIN_PANE_ID"' _ "$here")" "M1"

printf '== the escalation path uses it, and refuses a recycled pane ==\n'
# The same checks _attn_maybe_escalate makes, in the same order: agent pane,
# then a POSITIVE birth mismatch refuses.
reachable() {
  bash -c '. "$1/config.sh"; . "$1/lib/pane-guard.sh"
    [ -n "$HERDR_MAIN_PANE_ID" ] && pane_is_agent "$HERDR_MAIN_PANE_ID" || { echo unreachable; exit; }
    live=$(pane_birth_now "$HERDR_MAIN_PANE_ID")
    [ -n "$HERDR_MAIN_PANE_BIRTH" ] && [ -n "$live" ] && [ "$live" != "$HERDR_MAIN_PANE_BIRTH" ] && { echo refused; exit; }
    echo deliver' _ "$here"
}
check "designated live Main -> deliver" "$(env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH bash -c "$(declare -f reachable); here='$here'; reachable")" "deliver"
check "same pane id, new occupant (recycled) -> refused" \
  "$(env -u HERDR_MAIN_PANE_ID -u HERDR_MAIN_PANE_BIRTH MAIN_BIRTH=term_other bash -c "$(declare -f reachable); here='$here'; reachable")" "refused"

printf '== --show / --clear ==\n'
check "--show prints the designation" "$(bash "$here/designate-main.sh" --show)" "M1 term_main_1"
bash "$here/designate-main.sh" --clear >/dev/null
[ -e "$role" ] && bad "--clear left the file" || ok "--clear removes it"
check "config.sh empty again after --clear" "$(cfg)" "|"

echo "-----"; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
