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

printf '== grace: a prompt whose TEXT MOVED is still alerted (the AG-01 silent-failure) ==\n'
# This assertion used to say the opposite, and the opposite was the bug: a
# repaint, a tmux resize rewrapping a long Command: row, or a scroll changes the
# fingerprint of a prompt nobody answered, and the timer exited quietly. No
# further hook fires for that prompt, so that was permanent silence. The
# re-check now asks only "is a prompt still up?".
menu "git status --short"
pid=$(prompt_id "$PANE")
: > "$SENT"
HERDR_ALERT_GRACE_S=1 grace_realert "$PANE" "$pid" "" "" fake_alert
menu "git status --short --branch"        # same pending question, repainted wider
sleep 3
[ -s "$SENT" ] && ok "moved fingerprint still alerts (late, not never)" || bad "SILENT — a changed fingerprint dropped the alert"

printf '== grace: the window is sanitized (asserted directly, not by waiting) ==\n'
# Unvalidated, this value reaches `sleep`: a non-numeric one makes the timer
# exit instantly and an absurd one is unbounded silence. Asserted through
# _ag_grace_seconds so the clamp is actually covered - a test that had to sleep
# 900s to check it would never have been written.
[ "$(HERDR_ALERT_GRACE_S=45 _ag_grace_seconds)" = 45 ]        && ok "a sane window is honoured"        || bad "45 -> $(HERDR_ALERT_GRACE_S=45 _ag_grace_seconds)"
[ "$(HERDR_ALERT_GRACE_S=not-a-number _ag_grace_seconds)" = 90 ] && ok "non-numeric falls back to 90"  || bad "non-numeric -> $(HERDR_ALERT_GRACE_S=not-a-number _ag_grace_seconds)"
[ "$(HERDR_ALERT_GRACE_S= _ag_grace_seconds)" = 90 ]          && ok "empty falls back to 90"           || bad "empty -> $(HERDR_ALERT_GRACE_S= _ag_grace_seconds)"
[ "$(HERDR_ALERT_GRACE_S=99999 _ag_grace_seconds)" = 900 ]    && ok "absurd window clamped to 900"     || bad "99999 -> $(HERDR_ALERT_GRACE_S=99999 _ag_grace_seconds)"
[ "$(HERDR_ALERT_GRACE_S=0 _ag_grace_seconds)" = 1 ]          && ok "zero floored to 1"                || bad "0 -> $(HERDR_ALERT_GRACE_S=0 _ag_grace_seconds)"

printf '== AG-06: an omp steering queue does not satisfy the shape gate ==\n'
# The numbered extractor matches `1. Conductor: …`. Accepting it would hold an
# alert for an UNRECOGNIZED panel that no peer can answer — silence for a
# prompt that is nobody's.
printf 'Allow tool: bash\n\nApprove\nAlways allow\nDeny\n\n Steering · 2\n   1. Conductor: do the thing\n   2. Conductor: and the other\n' > "$SCREEN"
human_must_answer "$PANE" && ok "unrecognized panel + queue alerts a human" || bad "held a panel no peer can answer"

printf '== a genuine numbered prompt (no omp furniture) is still classified ==\n'
cat > "$SCREEN" <<'EOF'
 Bash command
   git status --short

 Do you want to proceed?
 ❯ 1. Yes
   2. No
EOF
human_must_answer "$PANE" && bad "a plain allow-class numbered prompt should be held" || ok "numbered Claude/Codex prompt still gated normally"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
