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

. "$here/lib/pane-guard.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/alert-gate.sh"
. "$here/lib/push-wake.sh"

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

printf '== change 3 (fix/peer-waits-for-record): an early release claiming the grace key stops the LATE timer from double-waking ==\n'
# herdr-select.sh's release_wake_hold claims grace_realert_${run}_${task}_${pid}
# via claim_once the moment a peer refuses a prompt push_wake already HELD,
# then delivers immediately itself. The 90s grace_realert timer already
# running for that SAME hold claims the identical key when it wakes — this
# proves the race the other way: the early release wins the claim FIRST
# (simulated here by claiming it directly, well inside the grace window), so
# the late timer's own claim_once finds it already taken and never calls its
# delivery command at all.
menu "git status --short"
grace_pid=$(prompt_id "$PANE")
grace_run="runGrace"; grace_task="taskGrace"
: > "$SENT"
HERDR_ALERT_GRACE_S=2 grace_realert "$PANE" "$grace_pid" "$grace_run" "$grace_task" fake_alert
claim_once "grace_realert_${grace_run}_${grace_task}_${grace_pid}" "$grace_run" "$grace_task" \
  grace_realert_claim '{}' >/dev/null 2>&1
sleep 4
[ ! -s "$SENT" ] && ok "the late grace timer no-ops once the early release already claimed the key" \
  || bad "the grace timer delivered a SECOND wake despite the early release: $(cat "$SENT")"

printf '== LOW-2 (PR #158 review): release_wake_hold itself (not a simulated claim) delivers once; the late timer delivers no second time ==\n'
menu "git push origin main"
rel_run="runRel"; rel_task="taskRel"
rel_pid=$(prompt_id "$PANE")
append_event "$rel_run" "$rel_task" wake_held \
  "$(jq -nc --arg p w9:p9 --arg pid "$rel_pid" --arg k "wake_${rel_run}_${rel_task}_${rel_pid}" \
     '{conductor_pane:$p, prompt_id:$pid, wake_key:$k, reason:"allow-class and unreserved; a peer may answer it"}')" >/dev/null 2>&1
RELNOTIFY="$WORK/rel-notify.sh"; RELLOG="$WORK/rel-notify.log"
cat > "$RELNOTIFY" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RELLOG"
exit 0
EOS
chmod +x "$RELNOTIFY"
export RELLOG
: > "$RELLOG"
# cpane deliberately empty: this pins the Slack-notify half of release_wake_hold
# (MEDIUM-1), which is unconditional on the conductor-wake delivery — no
# conductor pane is registered in this file, and the notify call must still
# fire exactly once regardless.
HERDR_NOTIFY="$RELNOTIFY" release_wake_hold "$PANE" "$rel_pid" "$rel_run" "$rel_task" "" "" "test msg" "" "" "peer refused: reserved"
rel_calls=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$RELLOG" ] && { rel_calls=$(wc -l < "$RELLOG" | tr -d ' '); break; }
  sleep 0.2
done
[ "$rel_calls" = "1" ] && ok "release_wake_hold delivered the Slack alert exactly once" || bad "notify calls after release: $rel_calls"
# The would-be duplicate: omp-notify.sh's OWN Slack grace_realert call site
# (agent-hooks/omp-notify.sh) uses this SAME run/task/pid, hence the SAME
# key, and would have spawned concurrently with the hold. It must find the
# key already claimed and deliver nothing more.
HERDR_ALERT_GRACE_S=1 HERDR_NOTIFY="$RELNOTIFY" grace_realert "$PANE" "$rel_pid" "$rel_run" "$rel_task" \
  bash "$RELNOTIFY" --choices --pane "$PANE" "test msg"
sleep 3
rel_calls2="$(wc -l < "$RELLOG" | tr -d ' ')"
[ "$rel_calls2" = "1" ] && ok "the late grace timer found the key already claimed and delivered nothing more" \
  || bad "grace timer delivered again after release_wake_hold: $rel_calls2 total calls"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
