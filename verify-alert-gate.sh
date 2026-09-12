#!/usr/bin/env bash
# verify-alert-gate.sh — proof that an alert fires when a HUMAN is being waited
# for, is HELD when an automated peer may take the prompt, and fires LATE rather
# than never when a held prompt outlives its grace window.
#
# The property that matters most is the last one: holding an alert is only safe
# because nothing is dropped. A pass here that skipped the grace case would be
# testing the bug, not the fix.
#
#   bash verify-alert-gate.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SCREEN="$WORK/screen.txt"
export HERDR_RUN_STATE_DIR="$WORK/runs"
PANE="w1:p1"

herdr() {
  case "$1 $2" in
    "pane read") cat "$SCREEN" ;;
    "pane list") printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"t1","cwd":"/tmp","agent":"omp"}]}}\n' "$PANE" ;;
    *) return 0 ;;
  esac
}
export -f herdr

. "$here/lib/run-registry.sh"
. "$here/lib/alert-gate.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

menu() {  # <command>
  printf 'Allow tool: bash\nCommand: %s\n\n\033[48;2;42;47;65m Approve\033[0m\n Deny\n\nup/down navigate  enter select  esc cancel\n' "$1" > "$SCREEN"
}

printf '== a prompt a PEER may take is held (no alert now) ==\n'
for allowed in "git status --short" "pwd" "bash scripts/ci.sh" "gh pr create --base main --fill"; do
  menu "$allowed"
  human_must_answer "$PANE" && bad "'$allowed' would alert a human" || ok "'$allowed' held"
done

printf '== a prompt only a HUMAN may answer still alerts ==\n'
for human in "gh pr merge 5 --squash" "git push origin main" "rm -rf /tmp/scratch" "op read op://secrets/x/credential" "wrangler deploy" "cat ~/.aws/credentials"; do
  menu "$human"
  human_must_answer "$PANE" && ok "'$human' alerts" || bad "'$human' was HELD — a human is genuinely waiting!"
done

printf '== unreadable, empty, or clipped is treated as needing a human ==\n'
printf '' > "$SCREEN"
human_must_answer "$PANE" && ok "empty screen alerts" || bad "empty screen held"
printf ' just some transcript output\n' > "$SCREEN"
human_must_answer "$PANE" && ok "no prompt alerts (nothing to classify)" || bad "no-prompt held"
menu "git commit -m ...457ch elided..."
human_must_answer "$PANE" && ok "clipped arguments alert" || bad "clipped arguments held"

printf '== grace: a prompt that CLEARS is never alerted ==\n'
menu "git status --short"
pid=$(prompt_id "$PANE")
SENT="$WORK/sent.txt"; : > "$SENT"
fake_alert() { printf 'ALERTED\n' >> "$SENT"; }
HERDR_ALERT_GRACE_S=1 grace_realert "$PANE" "$pid" "" "" fake_alert
printf ' the prompt is gone now\n' > "$SCREEN"     # answered during the window
sleep 3
[ ! -s "$SENT" ] && ok "cleared prompt produced no alert" || bad "alerted on a cleared prompt"

printf '== grace: a prompt STILL UP after the window alerts LATE, not never ==\n'
menu "git status --short"
pid=$(prompt_id "$PANE")
: > "$SENT"
HERDR_ALERT_GRACE_S=1 grace_realert "$PANE" "$pid" "" "" fake_alert
sleep 3                                            # nobody answered it
[ -s "$SENT" ] && ok "unanswered held prompt alerted after the grace window" || bad "HELD FOREVER — the alert was dropped, not delayed"

printf '== grace: a DIFFERENT prompt in the window is not alerted under the old id ==\n'
menu "git status --short"
pid=$(prompt_id "$PANE")
: > "$SENT"
HERDR_ALERT_GRACE_S=1 grace_realert "$PANE" "$pid" "" "" fake_alert
menu "ls -la /tmp"                                  # answered, then a new prompt painted
sleep 3
[ ! -s "$SENT" ] && ok "a new prompt is not alerted under the old fingerprint" || bad "stale fingerprint alerted"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
