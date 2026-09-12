#!/usr/bin/env bash
# verify-peer-answer.sh — proof that peer-answer.sh presses exactly what
# herdr-select.sh's peer authority allows, refuses the rest ONCE without
# nagging, and stops when its panes are gone. Same stubbed-herdr harness as
# verify-select-policy.sh (an exported function, because herdr-select.sh
# re-exports PATH); the real peer-answer.sh and the real herdr-select.sh run.
#
#   bash verify-peer-answer.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_BRIDGE_STATE="$WORK/bridge"
export SCREEN="$WORK/screen.txt"
export KEYS="$WORK/keys.log"
export AGENT_GONE="$WORK/agent-gone"     # touch it -> the pane is a bare shell
: > "$KEYS"

PANE="w1:p1"; BIRTH="term-abc-123"
export PANE BIRTH

herdr() {
  case "$1 $2" in
    "pane process-info")
      if [ -e "$AGENT_GONE" ]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"name":"zsh","cmdline":"-zsh"}]}}}\n'
      else
        printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --approval-mode write"}]}}}\n'
      fi ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp","agent":"omp"}]}}\n' "$PANE" "$BIRTH" ;;
    "pane read") cat "$SCREEN" ;;
    "pane send-keys") printf '%s\n' "$4" >> "$KEYS" ;;
    *) return 0 ;;
  esac
}
export -f herdr

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
keys_pressed() { wc -l < "$KEYS" | tr -d ' '; }

# A recognized omp approval panel with Approve highlighted (the SGR row).
menu() {  # <command>
  printf 'Allow tool: bash\nCommand: %s\n\n\033[48;2;42;47;65m Approve\033[0m\n Deny\n\nup/down navigate  enter select  esc cancel\n' "$1" > "$SCREEN"
}
run() { bash "$here/peer-answer.sh" --interval 0 "$@" >"$WORK/out.txt" 2>"$WORK/err.txt"; }
LOCKS="$HERDR_BRIDGE_STATE/peer-answer-locks"

printf '== PA-3: an INCOMPLETE panel (no footer) is never answered ==\n'
printf 'Allow tool: bash\nCommand: git status\n\n\033[48;2;42;47;65m Approve\033[0m\n Deny\n' > "$SCREEN"; : > "$KEYS"
run --max-rounds 1 "$PANE"; rc=$?
[ "$rc" -eq 3 ] && [ "$(keys_pressed)" = "0" ] && ok "incomplete panel: no key, pane still watched" || bad "rc=$rc keys=$(keys_pressed)"

printf '== PA-2: a non-policy outcome is NOT a permanent refusal (pane lock held, then released) ==\n'
menu "git status --short"; : > "$KEYS"
mkdir -p "$LOCKS/pane-$(printf '%s' "$PANE" | tr -c 'A-Za-z0-9' '_')"
( sleep 1; rmdir "$LOCKS/pane-$(printf '%s' "$PANE" | tr -c 'A-Za-z0-9' '_')" ) &
bash "$here/peer-answer.sh" --interval 2 --max-rounds 2 "$PANE" >"$WORK/out.txt" 2>"$WORK/err.txt"; rc=$?
wait
[ "$(keys_pressed)" = "1" ] && ok "pressed once the lock was released (not blacklisted)" || bad "keys=$(keys_pressed) rc=$rc out: $(cat "$WORK/out.txt")"

printf '== PA-1: --agent must declare menu-prompt; other agents are never swept in ==\n'
run --max-rounds 1 --agent weawr-lab --cwd-prefix /tmp; rc=$?
[ "$rc" -eq 2 ] && grep -q 'menu-prompt' "$WORK/err.txt" && ok "agent without menu-prompt refused at start (exit 2)" || bad "rc=$rc err: $(cat "$WORK/err.txt")"
menu "pwd"; : > "$KEYS"
run --max-rounds 1 --agent claude "$PANE"; rc=$?
[ "$rc" -eq 2 ] && [ "$(keys_pressed)" = "0" ] && ok "claude (numbered-prompt) refused at start, nothing pressed" || bad "rc=$rc keys=$(keys_pressed)"

printf '== PA-5: a second instance on the same watch set is refused while the first lives ==\n'
printf ' working on it\n' > "$SCREEN"
bash "$here/peer-answer.sh" --interval 1 --max-rounds 4 "$PANE" >/dev/null 2>&1 &
first=$!; sleep 1
run --max-rounds 1 "$PANE"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'another instance' "$WORK/err.txt" && ok "duplicate instance refused (exit 2)" || bad "rc=$rc err: $(cat "$WORK/err.txt")"
wait "$first"
run --max-rounds 1 "$PANE"; rc=$?
[ "$rc" -eq 3 ] && ok "lock released when the first instance exited" || bad "rc=$rc err: $(cat "$WORK/err.txt")"


printf '== allow-class panel: pressed once, reported ==\n'
menu "git status --short"; : > "$KEYS"
run --max-rounds 1 "$PANE"; rc=$?
[ "$rc" -eq 3 ] && ok "exit 3 (budget spent, pane still live)" || bad "exit $rc; err: $(cat "$WORK/err.txt")"
[ "$(keys_pressed)" = "1" ] && ok "exactly one key pressed" || bad "keys pressed=$(keys_pressed)"
grep -q 'approved' "$WORK/out.txt" && ok "approval reported" || bad "no approval line: $(cat "$WORK/out.txt")"

printf '== reserved panel (gh pr merge): refused, NO key, reported ONCE across rounds ==\n'
menu "gh pr merge 5 --squash"; : > "$KEYS"
run --max-rounds 3 "$PANE"; rc=$?
[ "$rc" -eq 3 ] && ok "exit 3 (pane still live)" || bad "exit $rc"
[ "$(keys_pressed)" = "0" ] && ok "NO KEY PRESSED on a reserved prompt" || bad "keys pressed=$(keys_pressed)!"
n=$(grep -c 'left for a human' "$WORK/out.txt")
[ "$n" = "1" ] && ok "refused once, not nagged (3 rounds, 1 line)" || bad "refusal lines=$n"
grep -q 'human-only' "$WORK/out.txt" && ok "reservation named" || bad "reason missing: $(cat "$WORK/out.txt")"

printf '== escalate-class panel (rm -rf): refused, NO key ==\n'
menu "rm -rf /tmp/scratch"; : > "$KEYS"
run --max-rounds 1 "$PANE"
[ "$(keys_pressed)" = "0" ] && ok "NO KEY PRESSED on an escalate prompt" || bad "keys pressed=$(keys_pressed)!"

printf '== no panel on screen: nothing pressed, keeps watching ==\n'
printf ' working on it\n' > "$SCREEN"; : > "$KEYS"
run --max-rounds 1 "$PANE"; rc=$?
[ "$rc" -eq 3 ] && [ "$(keys_pressed)" = "0" ] && ok "idle pane: no key, still live" || bad "rc=$rc keys=$(keys_pressed)"

printf '== pane is a bare shell again: exit 0 ==\n'
touch "$AGENT_GONE"
run "$PANE"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 when no watched agent pane remains" || bad "exit $rc"
rm -f "$AGENT_GONE"

printf '== --cwd-prefix picks agent panes under the directory ==\n'
menu "pwd"; : > "$KEYS"
run --max-rounds 1 --cwd-prefix /tmp; rc=$?
[ "$(keys_pressed)" = "1" ] && ok "pane under /tmp was watched and answered" || bad "keys=$(keys_pressed) rc=$rc err: $(cat "$WORK/err.txt")"
: > "$KEYS"
run --max-rounds 1 --cwd-prefix /nowhere; rc=$?
[ "$rc" -eq 0 ] && [ "$(keys_pressed)" = "0" ] && ok "no pane under /nowhere: exit 0, nothing pressed" || bad "rc=$rc keys=$(keys_pressed)"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
