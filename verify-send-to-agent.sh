#!/usr/bin/env bash
# verify-send-to-agent.sh — proof that send-to-agent.sh's submit confirmation
# actually detects whether an Enter did anything, instead of assuming success
# whenever the composer merely lacks a "[Pasted text" placeholder.
#
# Runs the REAL send-to-agent.sh (and the REAL composer_stable_snapshot it now
# sources from lib/prompt-parse.sh) against a stubbed herdr whose "pane read"
# output is state-machine driven: each recorded Enter advances a counter, and
# the stub serves the fixture screen for that step — so a scenario can express
# exactly what a real composer looks like immediately before/after each retry,
# including the case this suite exists to catch (2026-08-06 bug report): an
# Enter that `herdr pane send-keys` reports delivered but that changes nothing
# on screen at all.
#
#   bash verify-send-to-agent.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SCREEN_DIR="$WORK/screens"
export COUNTER="$WORK/enter-count"
export KEYS="$WORK/keys.log"
export SENDTEXT="$WORK/send-text.log"
mkdir -p "$SCREEN_DIR"

PANE="w1:p1"
export PANE

# ---- the stub ---------------------------------------------------------------
# "pane read" replies with $SCREEN_DIR/<n>, where <n> is how many Enters have
# been recorded so far — falling back to $SCREEN_DIR/last once a scenario's
# fixtures run out, so a scenario only needs to define the states that
# actually change and let a steady state repeat.
herdr() {
  case "$1 $2" in
    "pane read")
      local idx f
      idx=$(cat "$COUNTER" 2>/dev/null); idx="${idx:-0}"
      f="$SCREEN_DIR/$idx"
      [ -f "$f" ] || f="$SCREEN_DIR/last"
      cat "$f" 2>/dev/null
      ;;
    "pane send-text")
      printf '%s\n' "$4" >>"$SENDTEXT"
      ;;
    "pane send-keys")
      printf '%s\n' "$4" >>"$KEYS"
      if [ "$4" = "Enter" ]; then
        local idx; idx=$(cat "$COUNTER" 2>/dev/null); idx="${idx:-0}"
        echo $((idx + 1)) >"$COUNTER"
      fi
      ;;
    *) return 0 ;;
  esac
}
export -f herdr

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

reset_state() {
  rm -rf "$SCREEN_DIR"; mkdir -p "$SCREEN_DIR"
  echo 0 >"$COUNTER"; : >"$KEYS"; : >"$SENDTEXT"
}
screen() { cat >"$SCREEN_DIR/$1"; }              # screen <idx>  <<EOF ... EOF
last_as() { cp "$SCREEN_DIR/$1" "$SCREEN_DIR/last"; }
enters_pressed() { grep -c '^Enter$' "$KEYS" 2>/dev/null; }
send() { ( bash "$here/send-to-agent.sh" "$PANE" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" ); }

printf '== ordinary short text still submits on the FIRST Enter (no regression) ==\n'
reset_state
screen 0 <<'EOF'
  Ran 2 shell commands

⏺ Done with the last task.
───────────────────
❯ hello there
───────────────────
  branch:main
  [OMC#4.15.7] | session:100m
  ⏵⏵ accept edits on
EOF
screen 1 <<'EOF'
❯ hello there

✻ Cogitated for 2s

⏺ Working on it now.
───────────────────
❯
───────────────────
  branch:main
  [OMC#4.15.7] | session:101m
  ⏵⏵ accept edits on
EOF
last_as 1
send "hello there"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $(cat "$WORK/err.txt")"
grep -q '^SUBMITTED' "$WORK/out.txt" && ok "reported SUBMITTED" || bad "stdout: $(cat "$WORK/out.txt")"
[ "$(enters_pressed)" = "1" ] && ok "exactly one Enter" || bad "Enters=$(enters_pressed)"
[ "$(cat "$SENDTEXT")" = "hello there" ] && ok "text typed via send-text" || bad "send-text log: $(cat "$SENDTEXT")"

printf '== large-paste debounce: two Enters needed, placeholder clears on the second ==\n'
reset_state
screen 0 <<'EOF'
❯ [Pasted text #1 +40 lines]
───────────────────
  branch:main
  [OMC#4.15.7] | session:200m
EOF
screen 1 <<'EOF'
❯ [Pasted text #1 +40 lines]
───────────────────
  branch:main
  [OMC#4.15.7] | session:200m
EOF
screen 2 <<'EOF'
❯ [Pasted text #1 +40 lines]

✻ Cogitated for 5s

⏺ Got it, reviewing the pasted diff now.
───────────────────
❯
───────────────────
  branch:main
  [OMC#4.15.7] | session:201m
EOF
last_as 2
send "a very large pasted message"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $(cat "$WORK/err.txt")"
[ "$(enters_pressed)" = "2" ] && ok "two Enters (debounce, then submit)" || bad "Enters=$(enters_pressed)"

printf '== status bar ticking every read must NOT be mistaken for a real submit ==\n'
reset_state
for i in 0 1 2 3 4 5 6; do
  screen "$i" <<EOF
❯ stuck message
───────────────────
  branch:main
  [OMC#4.15.7] | session:$((100 + i))m
  ⏵⏵ accept edits on
EOF
done
last_as 6
send "stuck message"; rc=$?
[ "$rc" -eq 4 ] && ok "exit 4 UNSUBMITTED despite the status bar changing every read" || bad "exit $rc: $(cat "$WORK/out.txt")"
grep -q '^UNSUBMITTED' "$WORK/err.txt" && ok "reported UNSUBMITTED, not a false SUBMITTED" || bad "stderr: $(cat "$WORK/err.txt")"
[ "$(enters_pressed)" = "6" ] && ok "retried all 6 attempts before giving up" || bad "Enters=$(enters_pressed)"

printf '== bug reproduction: composer byte-identical every read (herdr Enter silently dropped) ==\n'
reset_state
screen 0 <<'EOF'
❯ push it
───────────────────
  branch:fix/fub-poller-null-dates
  [OMC#4.15.7] | session:2840m
  ⏵⏵ accept edits on
EOF
last_as 0
send "push it"; rc=$?
[ "$rc" -eq 4 ] && ok "exit 4, not a false SUBMITTED, on a truly stuck Enter" || bad "exit $rc: $(cat "$WORK/out.txt")"
[ "$(enters_pressed)" = "6" ] && ok "retried all 6 attempts" || bad "Enters=$(enters_pressed)"

printf '== --submit-only: presses/confirms text ALREADY in the composer, types nothing ==\n'
reset_state
screen 0 <<'EOF'
❯ push it
───────────────────
  branch:fix/fub-poller-null-dates
  [OMC#4.15.7] | session:2840m
EOF
screen 1 <<'EOF'
❯ push it

⏺ Pushed.
───────────────────
❯
───────────────────
  branch:fix/fub-poller-null-dates
  [OMC#4.15.7] | session:2841m
EOF
last_as 1
send --submit-only; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 SUBMITTED" || bad "exit $rc: $(cat "$WORK/err.txt")"
[ ! -s "$SENDTEXT" ] && ok "send-text never called under --submit-only" || bad "send-text called: $(cat "$SENDTEXT")"
[ "$(enters_pressed)" = "1" ] && ok "one Enter" || bad "Enters=$(enters_pressed)"

printf '== permission prompt still refuses, zero keys pressed, text never typed (no regression) ==\n'
reset_state
screen 0 <<'EOF'
 Do you want to proceed?
 ❯ 1. Yes
   2. No
EOF
last_as 0
send "some message"; rc=$?
[ "$rc" -eq 5 ] && ok "exit 5 REFUSED" || bad "exit $rc: $(cat "$WORK/out.txt") / $(cat "$WORK/err.txt")"
[ "$(enters_pressed)" = "0" ] && ok "NO Enter pressed on refusal" || bad "Enters=$(enters_pressed)"
[ ! -s "$SENDTEXT" ] && ok "text never typed into a live prompt" || bad "typed into a prompt: $(cat "$SENDTEXT")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
