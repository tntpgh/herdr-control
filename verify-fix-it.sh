#!/usr/bin/env bash
# verify-fix-it.sh — proves "Fix it" (fix-it.sh) does what .handoffs/DESIGN.md
# says: wakes a live conductor pane with the alert context, queues instead of
# sending when there is no live conductor pane, is idempotent (one Fix it per
# alert), and respects its kill switch — plus that attention-tick.sh's served
# form carries a "Fix it" control distinct from "Acknowledge" which, when
# answered, routes to fix-it.sh exactly once, while an Acknowledge answer
# routes to nothing (negatives stay manual) — and that stall-watchdog.sh's
# alert text names fix-it.sh beside stall-ack.sh on every surface it builds a
# message for (the pane wake and the Slack-bound escalation).
#
# Hermetic: stub `herdr` bash function (same pattern verify-attention-tick.sh
# and verify-omp-hooks.sh use), no live herdr, no live panes, no network.
#
#   bash verify-fix-it.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_PROMPT_SETTLE_WAIT_S=0
export SENT="$WORK/sent.log"
: > "$SENT"

CND="w2:p1"; CNDB="w2term"      # a live, agent-shaped conductor pane
DEADCND="w7:p1"                 # registered, but not agent-shaped (recycled)
W1="w1:p1"; W1B="w1term"
export CND CNDB DEADCND W1 W1B
SC="$WORK/cnd.txt"
export SC
clean_screen() { printf ' $ \n ready\n'; }
clean_screen > "$SC"

# herdr stub: process-info reports CND as an agent, everything else (unlisted
# pane ids, including DEADCND) as a bare shell — pane_is_agent's own "no
# foreground process = shell prompt" fail-closed default (lib/pane-guard.sh).
# send-text/send-keys mirror verify-attention-tick.sh's proven stub exactly
# (same arg positions send-to-agent.sh actually uses), so a submitted wake is
# confirmed the same way.
herdr() {
  local sub="$1 $2" pane
  case "$sub" in
    "pane process-info")
      pane="$4"
      if [ "$pane" = "$CND" ]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n'
      else
        printf '{"result":{"process_info":{"foreground_processes":[]}}}\n'
      fi ;;
    "pane read")
      pane="$3"
      [ "$pane" = "$CND" ] && cat "$SC" 2>/dev/null || printf '\n' ;;
    "pane send-text")
      printf 'send-text %s\n' "$3" >> "$SENT"
      printf '%s' "$4" > "$WORK/wake_${3//[:\/]/_}.txt" ;;
    "pane send-keys")
      printf 'send-keys %s %s\n' "$3" "$4" >> "$SENT"
      if [ "$4" = "Enter" ] && [ "$3" = "$CND" ]; then
        { printf ' %s\n' "$(cat "$WORK/wake_${3//[:\/]/_}.txt" 2>/dev/null)"
          printf '\n submitted\n $ \n ready\n'; } > "$SC"
      fi ;;
    *) return 0 ;;
  esac
}
export -f herdr

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

_q() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$1" 2>/dev/null; }
_wait_for_count() {  # <sql> <expected> <timeout-s>
  local sql="$1" want="$2" t="${3:-3}" i=0 n
  while [ "$i" -lt $((t * 10)) ]; do
    n="$(_q "$sql")"
    [ "${n:-0}" = "$want" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

. "$here/lib/run-registry.sh"

printf '== a live, agent-shaped conductor pane: fix-it.sh wakes it and records both events ==\n'
register_task runA taskA wA condA "$CND" "$CNDB" "$W1" "$W1B" /repo /wtA "impl:a" >/dev/null 2>&1
out="$(bash "$here/fix-it.sh" taskA attention 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "fix-it.sh exits 0 for a live conductor" || bad "exit $rc: $out"
n=$(_q "SELECT count(*) FROM events WHERE task_id='taskA' AND type='fix_it_requested';")
[ "$n" = "1" ] && ok "exactly one fix_it_requested claim" || bad "fix_it_requested count: $n"
n=$(_q "SELECT count(*) FROM events WHERE task_id='taskA' AND type='fix_it_result' AND json_extract(payload,'\$.outcome')='submitted';")
[ "$n" = "1" ] && ok "fix_it_result records outcome=submitted" || bad "submitted fix_it_result count: $n"
 sends=$(grep -c "^send-text ${CND}$" "$SENT" 2>/dev/null || true)
 [ "${sends:-0}" = "1" ] && ok "exactly one wake sent to the conductor pane" || bad "sends to $CND: ${sends:-0}: $(cat "$SENT")"
 printf '%s' "$(cat "$WORK/wake_${CND//[:\/]/_}.txt" 2>/dev/null)" | grep -q "a human asked for this alert to be handed to the owning lane" && \
   ok "the pane message carries the alert context" || bad "message missing context: $(cat "$WORK/wake_${CND//[:\/]/_}.txt" 2>/dev/null)"

printf '== idempotent: a second Fix it for the SAME (task, signal) sends nothing new ==\n'
out2="$(bash "$here/fix-it.sh" taskA attention 2>&1)"; rc2=$?
[ "$rc2" -eq 0 ] && ok "a repeat Fix it is not an error (exit 0)" || bad "repeat exit $rc2: $out2"
sends2=$(grep -c "^send-text ${CND}$" "$SENT" 2>/dev/null || true)
[ "${sends2:-0}" = "1" ] && ok "still exactly one send — the repeat sent nothing new" || bad "sends after repeat: ${sends2:-0}"
n=$(_q "SELECT count(*) FROM events WHERE task_id='taskA' AND type='fix_it_result';")
[ "$n" = "1" ] && ok "still exactly one fix_it_result row — the repeat recorded nothing new" || bad "fix_it_result rows after repeat: $n"
printf '%s' "$out2" | grep -q "already handled" && ok "the repeat reports it was already handled" || bad "repeat output: $out2"

printf '== a DIFFERENT signal on the same task is an independent alert, not deduped ==\n'
out3="$(bash "$here/fix-it.sh" taskA artifact 2>&1)"; rc3=$?
[ "$rc3" -eq 0 ] && ok "a different signal on the same task succeeds" || bad "exit $rc3: $out3"
sends3=$(grep -c "^send-text ${CND}$" "$SENT" 2>/dev/null || true)
[ "${sends3:-0}" = "2" ] && ok "a second, genuinely different alert sends a second wake" || bad "sends after new signal: ${sends3:-0}"

printf '== no conductor registered at all: queued, nothing sent, nothing crosses a human-only gate ==\n'
register_task runB taskB wB condB "" "" "$W1" "$W1B" /repo /wtB "impl:b" >/dev/null 2>&1
outB="$(bash "$here/fix-it.sh" taskB attention 2>&1)"; rcB=$?
[ "$rcB" -eq 0 ] && ok "no-conductor task still exits 0 (queued is success, not failure)" || bad "exit $rcB: $outB"
n=$(_q "SELECT count(*) FROM events WHERE task_id='taskB' AND type='fix_it_result' AND json_extract(payload,'\$.outcome')='queued';")
[ "$n" = "1" ] && ok "fix_it_result records outcome=queued" || bad "queued fix_it_result count: $n"
sendsB=$(grep -c "send-text" "$SENT" 2>/dev/null || true)
[ "${sendsB:-0}" = "2" ] && ok "nothing at all was sent for the unregistered-conductor task (send count unchanged)" || bad "unexpected send count: ${sendsB:-0}"

printf '== a registered but NOT agent-shaped (recycled) conductor pane: also queued, never sent to a stranger ==\n'
register_task runC taskC wC condC "$DEADCND" "deadbirth" "$W1" "$W1B" /repo /wtC "impl:c" >/dev/null 2>&1
outC="$(bash "$here/fix-it.sh" taskC attention 2>&1)"; rcC=$?
n=$(_q "SELECT count(*) FROM events WHERE task_id='taskC' AND type='fix_it_result' AND json_extract(payload,'\$.outcome')='queued';")
[ "$n" = "1" ] && ok "a non-agent conductor pane also queues rather than sending" || bad "taskC outcome: $(_q "SELECT json_extract(payload,'\$.outcome') FROM events WHERE task_id='taskC' AND type='fix_it_result';")"
sendsC=$(grep -c "send-text ${DEADCND}" "$SENT" 2>/dev/null || true)
[ "${sendsC:-0}" = "0" ] && ok "nothing was ever typed into the recycled pane" || bad "a send landed on a non-agent pane: ${sendsC:-0}"

printf '== unknown task_id: refuses, never touches the registry as if it were real ==\n'
outD="$(bash "$here/fix-it.sh" no-such-task 2>&1)"; rcD=$?
[ "$rcD" -eq 1 ] && ok "an unknown task_id exits 1" || bad "exit $rcD (expected 1): $outD"
printf '%s' "$outD" | grep -q "no such task" && ok "explains the miss" || bad "no explanation: $outD"

printf '== kill switch: HERDR_FIX_IT_DISABLE=1 refuses outright, sends nothing, records nothing ==\n'
register_task runE taskE wE condE "$CND" "$CNDB" "$W1" "$W1B" /repo /wtE "impl:e" >/dev/null 2>&1
sendsBefore=$(grep -c "send-text" "$SENT" 2>/dev/null || true)
outE="$(HERDR_FIX_IT_DISABLE=1 bash "$here/fix-it.sh" taskE attention 2>&1)"; rcE=$?
[ "$rcE" -eq 3 ] && ok "the kill switch refuses with a distinct exit code (3)" || bad "exit $rcE (expected 3): $outE"
printf '%s' "$outE" | grep -q "HERDR_FIX_IT_DISABLE" && ok "it names the exact switch" || bad "no explanation: $outE"
 n=$(_q "SELECT count(*) FROM events WHERE task_id='taskE' AND type LIKE 'fix_it_%';")
 [ "$n" = "0" ] && ok "a disabled call writes NO Fix-it event for the task" || bad "taskE Fix-it event count after disabled call: $n"
sendsAfter=$(grep -c "send-text" "$SENT" 2>/dev/null || true)
[ "$sendsAfter" = "$sendsBefore" ] && ok "a disabled call sent nothing" || bad "send count changed while disabled: $sendsBefore -> $sendsAfter"

printf '== attention-tick.sh: the served form carries a Fix it control distinct from Acknowledge ==\n'
export HERDR_ATTENTION_FORM_DIR="$WORK/forms"
FORMLOG_G="$WORK/formserve-g.calls"
export FORMLOG_G
cat > "$WORK/fake-python-g" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FORMLOG_G"
# attention-tick.sh invokes us as: fake-python-g <formserve.py-path> <form>
# --timeout N --no-open --title <title> — the form HTML path is $2, not the
# last arg (that's --title's value). Grab it before "answering", so the
# HTML-shape assertions below are against the EXACT file attention-tick.sh
# wrote, not a hand-built fixture.
form="$2"
cp "$form" "$WORK/last-form.html" 2>/dev/null || true
printf '%s' "${FAKE_FORM_ANSWER:-}"
exit 0
EOS
chmod +x "$WORK/fake-python-g"
export HERDR_ATTENTION_PYTHON="$WORK/fake-python-g"
export HERDR_ATTENTION_FORMSERVE="unused-logged-only"
export HERDR_MAIN_PANE_ID="w9:p1"
. "$here/attention-tick.sh"

register_task runF taskF wF condF "$CND" "$CNDB" "$W1" "$W1B" /repo /wtF "impl:f" >/dev/null 2>&1
export FAKE_FORM_ANSWER='{"acknowledged":true,"pane":"w1:p1","task_id":"taskF"}'
_attn_serve_form runF taskF "$W1" "blocked a while" "impl:f" "git status"
i=0; while [ ! -f "$WORK/last-form.html" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
if [ -f "$WORK/last-form.html" ]; then
  grep -q 'id=fixit' "$WORK/last-form.html" && ok "the served form has a Fix it control" || bad "no id=fixit in served form"
  grep -q '>Acknowledge<' "$WORK/last-form.html" && ok "...right beside Acknowledge" || bad "no Acknowledge button in served form"
  grep -q 'type=button class=secondary id=fixit' "$WORK/last-form.html" && \
    ok "Fix it is its own button, NOT the form's submit control (mutually exclusive with Acknowledge)" \
    || bad "Fix it is not a distinct type=button control"
else
  bad "formserve was never invoked — cannot inspect the served HTML"
fi

printf '== negatives stay manual: answering Acknowledge never calls fix-it.sh ==\n'
i=0; while [ "$(_q "SELECT count(*) FROM events WHERE task_id='taskF';")" = "0" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
sleep 0.3   # no further async work is expected; a short settle, not a race to beat
n=$(_q "SELECT count(*) FROM events WHERE task_id='taskF' AND type='fix_it_requested';")
[ "$n" = "0" ] && ok "an Acknowledge-only answer never invokes fix-it.sh" || bad "fix_it_requested fired for a plain Ack: $n"

printf '== the Fix it button DOES route to fix-it.sh, idempotently, when answered ==\n'
rm -f "$WORK/last-form.html"
export FAKE_FORM_ANSWER='{"fix_it":true,"pane":"w1:p1","task_id":"taskF"}'
_attn_serve_form runF taskF "$W1" "blocked a while" "impl:f" "git status"
_wait_for_count "SELECT count(*) FROM events WHERE task_id='taskF' AND type='fix_it_requested';" "1" 5 \
  && ok "answering Fix it invokes fix-it.sh for this exact task" \
  || bad "fix_it_requested never appeared for taskF: $(_q "SELECT type FROM events WHERE task_id='taskF';")"

printf '== stall-watchdog.sh: every alert message it builds names fix-it.sh beside stall-ack.sh ==\n'
n=$(grep -c 'Ack once handled: \$here/stall-ack\.sh \${task_id} \${signal}.*Fix it (hand it to the owning lane): \$here/fix-it\.sh \${task_id} \${signal}' "$here/stall-watchdog.sh")
[ "$n" = "3" ] && ok "all 3 alert-message constructions (2 pane-wake + 1 Slack-bound escalation) name fix-it.sh beside stall-ack.sh" \
  || bad "expected 3 messages naming both, found $n"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
