#!/usr/bin/env bash
# verify-project-wake.sh — project-wake.sh (thurber-os docs/
# project-contract-plan.md item 3, "carry to completion"): hermetic, no live
# herdr, no live panes, no network. Same stub-herdr pattern as
# verify-attention-tick.sh / verify-select-policy.sh.
#
# Proves the real negative the brief asks for: a stalled project's wake
# reaches Main exactly once for a given next-step, and does NOT repeat once
# the state is unchanged on a second tick (the project's own version of
# "answer it and the wake stops") — while a genuinely NEW next-step (the
# project moved) fires again, because that IS a new thing to carry forward.
#
#   bash verify-project-wake.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export SENT="$WORK/sent.log"
: > "$SENT"

MAIN="w9:p1"; MAINB="w9term"
export MAIN MAINB
SM="$WORK/main.txt"
export SM
printf ' $ \n ready\n' > "$SM"

herdr() {
  case "$1 $2" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"}]}}\n' "$MAIN" "$MAINB" ;;
    "pane read")
      cat "$SM" 2>/dev/null ;;
    "pane send-text")
      printf 'send-text %s\n' "$3" >> "$SENT"
      printf '%s' "$4" > "$WORK/wake_pending.txt" ;;
    "pane send-keys")
      printf 'send-keys %s %s\n' "$3" "$4" >> "$SENT"
      if [ "$4" = "Enter" ]; then
        { printf ' %s\n' "$(cat "$WORK/wake_pending.txt" 2>/dev/null)"
          printf '\n submitted\n $ \n ready\n'; } > "$SM"
      fi
      ;;
    *) return 0 ;;
  esac
}
export -f herdr

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

. "$here/lib/run-registry.sh"
export HERDR_MAIN_PANE_ID="$MAIN"
export HERDR_MAIN_PANE_BIRTH="$MAINB"
registry_init

_q() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$1" 2>/dev/null; }

echo "== first call for a project with a next step: wakes Main =="
bash "$here/project-wake.sh" scratch-project "first thing" "scratch-project: next — first thing"
n_sent=$(grep -c "send-text $MAIN" "$SENT" || true)
[ "$n_sent" = "1" ] && ok "one send-text to Main" || bad "expected 1 send-text, got $n_sent"
n_wake=$(_q "SELECT count(*) FROM events WHERE type='project_wake' AND task_id='scratch-project';")
[ "$n_wake" = "1" ] && ok "one project_wake event claimed" || bad "expected 1 project_wake event, got $n_wake"

echo "== identical next-step again: does NOT repeat (already answered/still open, same key) =="
: > "$SENT"
bash "$here/project-wake.sh" scratch-project "first thing" "scratch-project: next — first thing"
n_sent2=$(grep -c "send-text $MAIN" "$SENT" || true)
[ "$n_sent2" = "0" ] && ok "no second send for the same next-step (dedupe holds)" \
  || bad "sent again for an unchanged next-step: $n_sent2"

echo "== the project moved (a genuinely new next step): fires again =="
: > "$SENT"
bash "$here/project-wake.sh" scratch-project "second thing" "scratch-project: next — second thing"
n_sent3=$(grep -c "send-text $MAIN" "$SENT" || true)
[ "$n_sent3" = "1" ] && ok "a new next-step gets its own wake" || bad "expected 1 send for a new next-step, got $n_sent3"

echo "== Main unreachable: records the skip, never errors, never sends =="
: > "$SENT"
HERDR_MAIN_PANE_ID="" bash "$here/project-wake.sh" scratch-project "third thing" "scratch-project: next — third thing"
n_sent4=$(grep -c "send-text" "$SENT" || true)
[ "$n_sent4" = "0" ] && ok "nothing sent when Main is unreachable" || bad "sent with no reachable Main: $n_sent4"
n_skip=$(_q "SELECT count(*) FROM events WHERE type='project_wake_skipped' AND task_id='scratch-project';")
[ "$n_skip" = "1" ] && ok "the skip is recorded" || bad "expected 1 project_wake_skipped event, got $n_skip"

echo "== Main mid-turn on a permission prompt: first attempt REFUSED, retried on the next tick =="
# thurber-os docs/project-contract-plan.md #146 review finding 5: claim only
# after a successful send, or retry once next tick — same ladder
# attention-tick.sh's own _attn_maybe_escalate uses.
: > "$SENT"
printf ' Allow tool: bash\n   run: rm -rf /tmp/x\n\n\033[48;2;40;40;40m  Approve\033[0m\n   Deny\n\n up/down navigate  enter select  esc cancel\n' > "$SM"
bash "$here/project-wake.sh" retry-project "the next step" "retry-project: next — the next step"
n_sent_r1=$(grep -c "send-text $MAIN" "$SENT" || true)
[ "$n_sent_r1" = "0" ] && ok "send-to-agent.sh refuses on a permission prompt before ever typing" \
  || bad "expected 0 send-text calls on the refused attempt, got $n_sent_r1"
outcome1=$(_q "SELECT json_extract(payload,'\$.outcome') FROM events WHERE type='project_wake_result' AND task_id='retry-project' ORDER BY sequence ASC LIMIT 1;")
[ "$outcome1" != "submitted" ] && [ -n "$outcome1" ] && ok "first attempt outcome recorded as non-submitted ($outcome1)" \
  || bad "expected a non-submitted first outcome, got '$outcome1'"
printf ' $ \n ready\n' > "$SM"
bash "$here/project-wake.sh" retry-project "the next step" "retry-project: next — the next step"
n_sent_r2=$(grep -c "send-text $MAIN" "$SENT" || true)
[ "$n_sent_r2" = "1" ] && ok "the retry on a clear pane sends" || bad "expected 1 send on retry, got $n_sent_r2"
n_results=$(_q "SELECT count(*) FROM events WHERE type='project_wake_result' AND task_id='retry-project';")
[ "$n_results" = "2" ] && ok "exactly two attempts recorded (no unbounded retry)" || bad "expected 2 project_wake_result events, got $n_results"
: > "$SENT"
bash "$here/project-wake.sh" retry-project "the next step" "retry-project: next — the next step"
n_sent_r3=$(grep -c "send-text $MAIN" "$SENT" || true)
[ "$n_sent_r3" = "0" ] && ok "a third call after a submitted retry sends nothing (retry budget spent)" \
  || bad "sent a third time after the retry already landed: $n_sent_r3"


echo
echo "===== VERIFY ====="
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
