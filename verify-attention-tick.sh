#!/usr/bin/env bash
# verify-attention-tick.sh — the level-triggered attention controller
# (thurber-os docs/project-contract-plan.md §3a): hermetic, no live herdr, no
# live panes, no network, no 20-minute sleep. A stub `herdr` bash function
# (same pattern as verify-omp-hooks.sh / verify-select-policy.sh) stands in
# for the fleet; HERDR_ATTENTION_NOW stands in for the clock the T+10/T+20
# minute checks would otherwise need to actually wait out.
#
#   bash verify-attention-tick.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

# Exported (not just set): the herdr stub below is an exported bash FUNCTION,
# but it runs inside CHILD shells too (send-to-agent.sh is invoked as
# `bash <script>`), and a plain shell variable does not cross that boundary —
# under that child's own `set -u` an unreferenced $WORK aborts it silently
# (exit 1, no message point-of-failure legible without -x tracing).
WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_ATTENTION_FORM_DIR="$WORK/forms"
export SENT="$WORK/sent.log"
export HERDR_CALLS="$WORK/herdr.calls"
: > "$SENT"

# Two workers reused across most scenarios, one shared conductor, one Main.
# W3/W4 are dedicated to the "identical prompt text, two panes" check below —
# reusing W1/W2 there would collide with prompt fingerprints those panes
# already claimed earlier in this file, which is a test-fixture hazard, not
# something the dedupe key is wrong to catch (same pane_id + same live birth
# + same prompt fingerprint IS the same logical event by design).
# Per-pane screen FILES, not a shared one — a shared screen would make
# send-to-agent.sh see one pane's prompt on another.
W1="w1:p1"; W1B="w1term"
W2="w3:p1"; W2B="w3term"
W3="w4:p1"; W3B="w4term"
W4="w5:p1"; W4B="w5term"
CND="w2:p1"; CNDB="w2term"
MAIN="w9:p1"; MAINB="w9term"
export W1 W1B W2 W2B W3 W3B W4 W4B CND CNDB MAIN MAINB
S1="$WORK/w1.txt"; S2="$WORK/w2.txt"; S3="$WORK/w4.txt"; S4="$WORK/w5.txt"
SC="$WORK/cnd.txt"; SM="$WORK/main.txt"
export S1 S2 S3 S4 SC SM

herdr() {
  local sub="$1 $2" pane
  [ -n "${HERDR_CALLS:-}" ] && printf '%s %s\n' "$sub" "${3:-}" >> "$HERDR_CALLS"
  case "$sub" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    "pane list")
      # STUB_HIDE_W1: omit W1 from the live roster, so pane_birth_now("$W1")
      # comes back empty — the transient herdr-CLI-hiccup case item 2's key
      # fix has to survive without drifting.
      if [ -n "${STUB_HIDE_W1:-}" ]; then
        printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
          "$W2" "$W2B" "$W3" "$W3B" "$W4" "$W4B" "$CND" "$CNDB" "$MAIN" "$MAINB"
      else
        printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
          "$W1" "$W1B" "$W2" "$W2B" "$W3" "$W3B" "$W4" "$W4B" "$CND" "$CNDB" "$MAIN" "$MAINB"
      fi ;;
    "pane read")
      pane="$3"
      case "$pane" in
        "$W1") cat "$S1" 2>/dev/null ;;
        "$W2") cat "$S2" 2>/dev/null ;;
        "$W3") cat "$S3" 2>/dev/null ;;
        "$W4") cat "$S4" 2>/dev/null ;;
        "$CND") cat "$SC" 2>/dev/null ;;
        "$MAIN") cat "$SM" 2>/dev/null ;;
        *) printf '\n' ;;
      esac ;;
    "pane send-text")
      printf 'send-text %s\n' "$3" >> "$SENT"
      printf '%s' "$4" > "$WORK/wake_${3//[:\/]/_}.txt" ;;
    "pane send-keys")
      printf 'send-keys %s %s\n' "$3" "$4" >> "$SENT"
      # send-to-agent.sh confirms a submit by diffing the composer before/after
      # Enter (see its own header) — a stub target must actually CHANGE, or
      # every wake in this suite reads back UNSUBMITTED.
      if [ "$4" = "Enter" ]; then
        local target="$3" f=""
        case "$target" in "$CND") f="$SC" ;; "$MAIN") f="$SM" ;; esac
        if [ -n "$f" ]; then
          { printf ' %s\n' "$(cat "$WORK/wake_${target//[:\/]/_}.txt" 2>/dev/null)"
            printf '\n submitted\n $ \n ready\n'; } > "$f"
        fi
      fi
      ;;
    *) return 0 ;;
  esac
}
export -f herdr

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# omp's approval menu: header, blank, rows (highlighted row carries an SGR
# background), blank, footer — same shape verify-omp-hooks.sh's fixtures use.
omp_menu_screen() {  # <command>
  printf ' Allow tool: bash\n   run: %s\n\n\033[48;2;40;40;40m  Approve\033[0m\n   Deny\n\n up/down navigate  enter select  esc cancel\n' "$1"
}
clean_screen() { printf ' $ \n ready\n'; }

_q() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "$1" 2>/dev/null; }
_wait_for() {  # <file> <grep-pattern> <timeout-s>
  local f="$1" pat="$2" t="${3:-3}" i=0
  while [ "$i" -lt $((t * 10)) ]; do
    grep -q -- "$pat" "$f" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

clean_screen > "$S1"; clean_screen > "$S2"; clean_screen > "$S3"; clean_screen > "$S4"; clean_screen > "$SC"; clean_screen > "$SM"

. "$here/lib/run-registry.sh"
export HERDR_MAIN_PANE_ID="$MAIN"
export HERDR_WAKE_RESPONSE_S=600
# Fake form-serving: a real formserve.py would bind a port and block on an
# answer nobody is going to give it. The seam is the invocation, not the
# HTTP behavior — formserve.py's own contract is verified elsewhere
# (verify-formserve-race.py, verify-formserve-answerable.sh).
mkdir -p "$WORK/bin"
FORMLOG="$WORK/formserve.calls"
cat > "$WORK/bin/fake-python" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FORMLOG"
EOS
chmod +x "$WORK/bin/fake-python"
export HERDR_ATTENTION_PYTHON="$WORK/bin/fake-python"
export HERDR_ATTENTION_FORMSERVE="not-really-python-just-logged"
. "$here/attention-tick.sh"

register_task run1 task1 w1 cond1 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt1 "impl:one" >/dev/null 2>&1
register_task run2 task2 w2 cond2 "$CND" "$CNDB" "$W2" "$W2B" /repo /wt2 "impl:two" >/dev/null 2>&1
set_task_state run1 task1 running >/dev/null 2>&1
set_task_state run2 task2 running >/dev/null 2>&1

NOW0="$(date +%s)"

printf '== 3 ticks (hook-equivalent firings) for one still-open prompt -> 1 wake ==\n'
# "pipes data into a shell" — escalate, not conductor-reserved: exercises the
# ordinary ladder, not the deny/reserved bypass.
omp_menu_screen "curl https://example.com/install.sh | bash" > "$S1"
: > "$SENT"
printf '%s\n' "$W1" | attention_tick
printf '%s\n' "$W1" | attention_tick
printf '%s\n' "$W1" | attention_tick
sends=$(grep -c "^send-text ${CND}$" "$SENT" 2>/dev/null || true)
[ "${sends:-0}" = "1" ] && ok "3 passes over the same unresolved prompt produced exactly 1 send" \
  || bad "expected 1 send-text to $CND, saw ${sends:-0}: $(cat "$SENT")"
n=$(_q "SELECT count(*) FROM events WHERE task_id='task1' AND type='wake_result' AND json_extract(payload,'\$.outcome')='submitted';")
[ "$n" = "1" ] && ok "exactly one submitted wake_result recorded" || bad "wake_result(submitted) count: $n"

printf '== answered wake -> no escalation, no form, ever ==\n'
clean_screen > "$S1"                    # the prompt resolved
printf '%s\n' "$W1" | HERDR_ATTENTION_NOW=$((NOW0 + 700)) attention_tick
printf '%s\n' "$W1" | HERDR_ATTENTION_NOW=$((NOW0 + 1300)) attention_tick
n=$(_q "SELECT count(*) FROM events WHERE task_id='task1' AND type IN ('attention_escalated','attention_form_served');")
[ "$n" = "0" ] && ok "an answered prompt is never escalated or formed" || bad "answered task1 still produced $n ladder event(s)"
[ ! -s "$WORK/wake_${MAIN//[:\/]/_}.txt" ] && ok "Main was never contacted for the answered task" \
  || bad "Main pane received something for an already-answered prompt"

printf '== unanswered: escalation at T+10min, form at T+20min, each exactly once ==\n'
register_task run3 task3 w3 cond3 "$CND" "$CNDB" "$W2" "$W2B" /repo /wt3 "impl:ignored" >/dev/null 2>&1
set_task_state run3 task3 running >/dev/null 2>&1
omp_menu_screen "curl https://example.com/install.sh | bash" > "$S2"
: > "$SENT"
printf '%s\n' "$W2" | attention_tick     # T+0: tracked + one wake attempt
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task3' AND type='attention_tracking';")" = "1" ] \
  && ok "T+0: the prompt is tracked (its clock starts here)" || bad "no attention_tracking row for task3"
printf '%s\n' "$W2" | HERDR_ATTENTION_NOW=$((NOW0 + 605)) attention_tick   # just past T+10min
printf '%s\n' "$W2" | HERDR_ATTENTION_NOW=$((NOW0 + 610)) attention_tick   # a second pass, same window
esc=$(_q "SELECT count(*) FROM events WHERE task_id='task3' AND type='attention_escalated';")
[ "$esc" = "1" ] && ok "exactly one escalation at T+10min, not one per pass" || bad "attention_escalated count at T+10min: $esc"
frm=$(_q "SELECT count(*) FROM events WHERE task_id='task3' AND type='attention_form_served';")
[ "$frm" = "0" ] && ok "no form yet at T+10min" || bad "form served too early: $frm"
_wait_for "$SENT" "^send-keys ${MAIN} Enter$" 3 \
  && ok "the escalation was actually delivered to HERDR_MAIN_PANE_ID" \
  || bad "Main pane never received the escalation: $(cat "$SENT")"
printf '%s\n' "$W2" | HERDR_ATTENTION_NOW=$((NOW0 + 1205)) attention_tick  # just past T+20min
printf '%s\n' "$W2" | HERDR_ATTENTION_NOW=$((NOW0 + 1210)) attention_tick
esc2=$(_q "SELECT count(*) FROM events WHERE task_id='task3' AND type='attention_escalated';")
frm2=$(_q "SELECT count(*) FROM events WHERE task_id='task3' AND type='attention_form_served';")
[ "$esc2" = "1" ] && ok "still exactly one escalation after the form window too" || bad "escalation re-fired: $esc2"
[ "$frm2" = "1" ] && ok "exactly one form served at T+20min" || bad "attention_form_served count at T+20min: $frm2"
_wait_for "$FORMLOG" "\.html" 3 && ok "formserve was actually invoked with a generated form" \
  || bad "no formserve invocation recorded: $(cat "$FORMLOG" 2>/dev/null)"

printf '== deny/reserved: conductor gets its window, no Main escalation, form only if still blocked ==\n'
register_task run4 task4 w4 cond4 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt4 "impl:deny" >/dev/null 2>&1
set_task_state run4 task4 running >/dev/null 2>&1
omp_menu_screen "mkfs.ext4 /dev/sda1" > "$S1"
: > "$SENT"
printf '%s\n' "$W1" | attention_tick
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task4' AND type='attention_form_served';")" = "0" ] \
  && ok "a deny-class prompt is NOT formed on first sight (its conductor may still deny it)" \
  || bad "deny-class prompt was formed before its conductor had a chance"
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task4' AND type='attention_tracking';")" = "1" ] \
  && ok "a deny-class prompt is tracked so its window has a clock" || bad "deny-class prompt not tracked"
printf '%s\n' "$W1" | HERDR_ATTENTION_NOW=$((NOW0 + 605)) attention_tick
printf '%s\n' "$W1" | HERDR_ATTENTION_NOW=$((NOW0 + 610)) attention_tick
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task4' AND type='attention_form_served';")" = "1" ] \
  && ok "still blocked after the owner's window -> exactly one form" || bad "deny-class form count after window wrong"
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task4' AND type='attention_escalated';")" = "0" ] \
  && ok "a deny-class prompt never escalates to Main (only a human can approve it)" || bad "deny-class prompt escalated to Main"
f=$(ls -t "$WORK"/forms/*.html 2>/dev/null | head -1)
if [ -n "$f" ] && grep -q '<style>' "$f" && grep -q 'mkfs.ext4 /dev/sda1' "$f"; then
  ok "the served form is styled and shows the exact blocked command"
else
  bad "served form unstyled or missing the command: ${f:-no file}"
fi

register_task run5 task5 w5 cond5 "$CND" "$CNDB" "$W2" "$W2B" /repo /wt5 "impl:reserved" >/dev/null 2>&1
set_task_state run5 task5 running >/dev/null 2>&1
omp_menu_screen "wrangler deploy" > "$S2"
: > "$SENT"
printf '%s\n' "$W2" | attention_tick
clean_screen > "$S2"                    # conductor denied/redirected; the prompt cleared
printf '%s\n' "$W2" | HERDR_ATTENTION_NOW=$((NOW0 + 700)) attention_tick
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task5' AND type='attention_form_served';")" = "0" ] \
  && ok "a reserved prompt its conductor already handled is never formed" \
  || bad "reserved prompt formed after the conductor handled it (the w1Q:p6 dead form)"

printf '== same prompt_id on two DIFFERENT panes -> two independent keys ==\n'
register_task run6 task6 w6 cond6 "$CND" "$CNDB" "$W3" "$W3B" /repo /wt6 "impl:six" >/dev/null 2>&1
register_task run7 task7 w7 cond7 "$CND" "$CNDB" "$W4" "$W4B" /repo /wt7 "impl:seven" >/dev/null 2>&1
set_task_state run6 task6 running >/dev/null 2>&1
set_task_state run7 task7 running >/dev/null 2>&1
SAME_CMD="curl https://example.com/install.sh | bash"
omp_menu_screen "$SAME_CMD" > "$S3"
omp_menu_screen "$SAME_CMD" > "$S4"
: > "$SENT"
{ printf '%s\n%s\n' "$W3" "$W4"; } | attention_tick
sends6=$(_q "SELECT count(*) FROM events WHERE task_id='task6' AND type='wake_result' AND json_extract(payload,'\$.outcome')='submitted';")
sends7=$(_q "SELECT count(*) FROM events WHERE task_id='task7' AND type='wake_result' AND json_extract(payload,'\$.outcome')='submitted';")
[ "$sends6" = "1" ] && [ "$sends7" = "1" ] \
  && ok "identical prompt text on two panes still delivers a wake for EACH task" \
  || bad "task6=$sends6 task7=$sends7 (the two panes' identical prompt collided)"
key6=$(_q "SELECT json_extract(payload,'\$.key') FROM events WHERE task_id='task6' AND type='attention_tracking' LIMIT 1;")
key7=$(_q "SELECT json_extract(payload,'\$.key') FROM events WHERE task_id='task7' AND type='attention_tracking' LIMIT 1;")
[ -n "$key6" ] && [ -n "$key7" ] && [ "$key6" != "$key7" ] \
  && ok "the two panes hashed to different dedupe keys ($key6 vs $key7)" \
  || bad "dedupe keys collided or missing: key6=$key6 key7=$key7"
printf '%s\n%s\n' "$W3" "$W4" | HERDR_ATTENTION_NOW=$((NOW0 + 1210)) attention_tick
esc6=$(_q "SELECT count(*) FROM events WHERE task_id='task6' AND type='attention_escalated';")
esc7=$(_q "SELECT count(*) FROM events WHERE task_id='task7' AND type='attention_escalated';")
[ "$esc6" = "1" ] && [ "$esc7" = "1" ] && ok "both panes escalate independently" || bad "esc6=$esc6 esc7=$esc7"

printf '== PR #132 re-review item 2: under HERDR_WAKE_LEGACY=1 the controller itself never push_wakes ==\n'
register_task run8 task8 w8 cond8 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt8 "impl:legacy" >/dev/null 2>&1
set_task_state run8 task8 running >/dev/null 2>&1
omp_menu_screen "curl https://example.com/legacy-test.sh | bash" > "$S1"
: > "$SENT"
printf '%s\n' "$W1" | HERDR_WAKE_LEGACY=1 attention_tick
printf '%s\n' "$W1" | HERDR_WAKE_LEGACY=1 attention_tick
attempts=$(_q "SELECT count(*) FROM events WHERE task_id='task8' AND type='wake_attempted';")
[ "$attempts" -le 1 ] && ok "the controller makes at most 1 push_wake attempt under the escape hatch (measured: $attempts)" \
  || bad "expected <=1 wake_attempted from the controller under HERDR_WAKE_LEGACY=1, saw $attempts"
n_track=$(_q "SELECT count(*) FROM events WHERE task_id='task8' AND type='attention_tracking';")
[ "$n_track" = "1" ] && ok "the controller still tracks 'since' under the escape hatch (the ladder still needs it)" \
  || bad "attention_tracking rows for task8: $n_track"
[ ! -s "$SENT" ] && ok "nothing was sent by the controller — delivery is the hooks' job under LEGACY" \
  || bad "controller sent something under LEGACY: $(cat "$SENT")"

printf '== PR #132 review, P1: a hook-held allow-class prompt is never double-woken ==\n'
register_task run9 task9 w9 cond9 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt9 "impl:allow" >/dev/null 2>&1
set_task_state run9 task9 running >/dev/null 2>&1
omp_menu_screen "git status --short" > "$S1"
clean_screen > "$SC"
: > "$SENT"
# Simulate a HOOK firing independently of the controller: push_wake direct,
# fast grace window so the suite does not wait out the real 90s default.
( HERDR_RUN_ID=run9 HERDR_TASK_ID=task9 HERDR_PANE_ID="$W1" HERDR_CONDUCTOR_PANE_ID="$CND" \
  HERDR_TASK_LABEL="impl:allow" HERDR_ALERT_GRACE_S=1 push_wake "impl:allow needs input" "hook" >/dev/null 2>&1 )
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task9' AND type='wake_held';")" = "1" ] \
  && ok "the hook's own call HELD the allow-class prompt (its grace timer is now running)" \
  || bad "hook call did not hold as expected"
# The controller ticks 3 times while the SAME prompt sits held. It must see
# the wake as already OWNED and never call push_wake itself — a redundant
# call here would spawn a SECOND grace timer and double-deliver when it
# expires, which is exactly the bug this fix closes.
printf '%s\n' "$W1" | attention_tick
printf '%s\n' "$W1" | attention_tick
printf '%s\n' "$W1" | attention_tick
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task9' AND type='attention_tracking';")" = "1" ] \
  && ok "the controller still tracks the prompt exactly once" || bad "attention_tracking count wrong"
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task9' AND type='wake_attempted';")" = "0" ] \
  && ok "the controller never called push_wake itself (already owned by the hook)" \
  || bad "controller called push_wake anyway — the double-wake this fix exists to prevent"
sleep 2   # let the hook's OWN grace_realert timer (1s) fire and force-deliver
n_res=$(_q "SELECT count(*) FROM events WHERE task_id='task9' AND type='wake_result';")
[ "$n_res" = "1" ] && ok "exactly one delivered wake once the hook's own grace window expired" \
  || bad "wake_result rows for task9: $n_res"
n_grace=$(_q "SELECT count(*) FROM events WHERE task_id='task9' AND type='alert_grace_expired';")
[ "$n_grace" = "1" ] && ok "exactly one alert_grace_expired, not one per controller tick" \
  || bad "alert_grace_expired rows: $n_grace"

printf '== PR #132 review, P2 item 2: an empty live birth, and a repaint, both keep one key ==\n'
register_task run10 task10 w10 cond10 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt10 "impl:stability" >/dev/null 2>&1
set_task_state run10 task10 running >/dev/null 2>&1
omp_menu_screen "systemctl restart myservice" > "$S1"
: > "$SENT"
printf '%s\n' "$W1" | attention_tick                              # live birth resolves normally
printf '%s\n' "$W1" | STUB_HIDE_W1=1 attention_tick                # herdr "pane list" omits W1 -> empty live birth
n_track=$(_q "SELECT count(*) FROM events WHERE task_id='task10' AND type='attention_tracking';")
[ "$n_track" = "1" ] && ok "an empty live-birth read reuses the SAME key (registered birth, not live)" \
  || bad "attention_tracking rows for task10: $n_track (key drifted when the live read failed)"
# A repaint: same command, cosmetically different padding/highlight redraw.
printf ' Allow tool: bash\n   run:   systemctl restart myservice   \n\n\033[48;2;40;40;40m  Approve\033[0m\n   Deny\n\n up/down navigate  enter select  esc cancel\n' > "$S1"
printf '%s\n' "$W1" | attention_tick
n_track2=$(_q "SELECT count(*) FROM events WHERE task_id='task10' AND type='attention_tracking';")
[ "$n_track2" = "1" ] && ok "a repaint of the identical command also keeps the same key" \
  || bad "attention_tracking rows for task10 after repaint: $n_track2"
n_wakes=$(_q "SELECT count(*) FROM events WHERE task_id='task10' AND type='wake_attempted';")
[ "$n_wakes" = "1" ] && ok "neither the empty-birth pass nor the repaint triggered a second wake attempt" \
  || bad "wake_attempted rows for task10: $n_wakes"

printf '== PR #132 review, P2 item 3: Main unreachable never burns the escalation claim ==\n'
register_task run11 task11 w11 cond11 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt11 "impl:escalate-order" >/dev/null 2>&1
set_task_state run11 task11 running >/dev/null 2>&1
clean_screen > "$SM"
omp_menu_screen "curl https://example.com/setup.sh | bash" > "$S1"
: > "$SENT"
NB="$(date +%s)"          # a FRESH baseline: NOW0 is real minutes stale by this point in the suite
printf '%s\n' "$W1" | attention_tick
printf '%s\n' "$W1" | HERDR_MAIN_PANE_ID="" HERDR_ATTENTION_NOW=$((NB + 700)) attention_tick
n_esc=$(_q "SELECT count(*) FROM events WHERE task_id='task11' AND type='attention_escalated';")
[ "$n_esc" = "0" ] && ok "an unreachable Main never claims the escalation slot" || bad "escalation claimed anyway: $n_esc"
n_skip=$(_q "SELECT count(*) FROM events WHERE task_id='task11' AND type='attention_escalation_skipped';")
[ "$n_skip" -ge 1 ] && ok "the unreachable attempt is recorded, not silent" || bad "no attention_escalation_skipped recorded"
printf '%s\n' "$W1" | HERDR_ATTENTION_NOW=$((NB + 710)) attention_tick   # Main (HERDR_MAIN_PANE_ID) is back
n_esc2=$(_q "SELECT count(*) FROM events WHERE task_id='task11' AND type='attention_escalated';")
[ "$n_esc2" = "1" ] && ok "escalation succeeds once Main is reachable — the earlier miss did not burn it" \
  || bad "escalation count after Main returned: $n_esc2"
_wait_for "$SENT" "^send-keys ${MAIN} Enter$" 3 && ok "and it actually delivered" || bad "no delivery to Main: $(cat "$SENT")"
outcome=$(_q "SELECT json_extract(payload,'\$.outcome') FROM events WHERE task_id='task11' AND type='attention_escalation_result' ORDER BY sequence LIMIT 1;")
[ "$outcome" = "submitted" ] && ok "attention_escalation_result records the mapped outcome" || bad "escalation_result outcome: $outcome"

printf '== PR #132 review, P2 item 4: a Main birth mismatch refuses, never sends ==\n'
register_task run12 task12 w12 cond12 "$CND" "$CNDB" "$W2" "$W2B" /repo /wt12 "impl:escalate-birth" >/dev/null 2>&1
set_task_state run12 task12 running >/dev/null 2>&1
clean_screen > "$SM"
omp_menu_screen "curl https://example.com/other.sh | bash" > "$S2"
: > "$SENT"
NB="$(date +%s)"
printf '%s\n' "$W2" | attention_tick
: > "$SENT"          # clear the FIRST tick's legitimate wake-to-conductor before checking "nothing sent"
printf '%s\n' "$W2" | HERDR_MAIN_PANE_BIRTH="expected-birth-XYZ" HERDR_ATTENTION_NOW=$((NB + 700)) attention_tick
n_esc=$(_q "SELECT count(*) FROM events WHERE task_id='task12' AND type='attention_escalated';")
[ "$n_esc" = "0" ] && ok "a Main birth mismatch never claims the escalation" || bad "escalated despite birth mismatch: $n_esc"
n_ref=$(_q "SELECT count(*) FROM events WHERE task_id='task12' AND type='attention_escalation_refused';")
[ "$n_ref" = "1" ] && ok "the refusal is recorded" || bad "no attention_escalation_refused recorded"
[ ! -s "$SENT" ] && ok "nothing was sent to Main on a birth mismatch" || bad "sent anyway: $(cat "$SENT")"

printf '== PR #132 review, P2 item 3: exactly one retry after a failed first attempt ==\n'
register_task run13 task13 w13 cond13 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt13 "impl:escalate-retry" >/dev/null 2>&1
set_task_state run13 task13 running >/dev/null 2>&1
clean_screen > "$SM"
omp_menu_screen "curl https://example.com/retry.sh | bash" > "$S1"
: > "$SENT"
NB="$(date +%s)"
printf '%s\n' "$W1" | attention_tick
omp_menu_screen "busy" > "$SM"          # Main looks mid-prompt -> send-to-agent.sh refuses (exit 5)
printf '%s\n' "$W1" | HERDR_ATTENTION_NOW=$((NB + 700)) attention_tick
outcome1=$(_q "SELECT json_extract(payload,'\$.outcome') FROM events WHERE task_id='task13' AND type='attention_escalation_result' ORDER BY sequence LIMIT 1;")
[ "$outcome1" = "refused" ] && ok "first attempt recorded as refused (Main mid-prompt)" || bad "first outcome: $outcome1"
clean_screen > "$SM"                    # Main clears
printf '%s\n' "$W1" | HERDR_ATTENTION_NOW=$((NB + 715)) attention_tick
n_esc2=$(_q "SELECT count(*) FROM events WHERE task_id='task13' AND type='attention_escalated';")
[ "$n_esc2" = "2" ] && ok "exactly one retry attempted after the failed first" || bad "escalation attempts for task13: $n_esc2"
outcomes=$(_q "SELECT json_extract(payload,'\$.outcome') FROM events WHERE task_id='task13' AND type='attention_escalation_result' ORDER BY sequence;")
printf '%s' "$outcomes" | tail -1 | grep -q submitted && ok "the retry landed (submitted)" || bad "retry outcomes: $outcomes"
printf '%s\n' "$W1" | HERDR_ATTENTION_NOW=$((NB + 730)) attention_tick
n_esc3=$(_q "SELECT count(*) FROM events WHERE task_id='task13' AND type='attention_escalated';")
[ "$n_esc3" = "2" ] && ok "no third attempt once one has landed" || bad "escalation attempts kept growing: $n_esc3"
clean_screen > "$SM"

printf '== PR #132 review, P2 item 5: an owner_acted row after the claim counts as answered ==\n'
register_task run14 task14 w14 cond14 "$CND" "$CNDB" "$W2" "$W2B" /repo /wt14 "impl:owner-acted" >/dev/null 2>&1
set_task_state run14 task14 running >/dev/null 2>&1
omp_menu_screen "curl https://example.com/owner.sh | bash" > "$S2"
: > "$SENT"
NB="$(date +%s)"
printf '%s\n' "$W2" | attention_tick
pid14="$(prompt_id "$W2")"
sleep 1   # cross a real ISO-second boundary so occurred_at genuinely sorts after the claim
append_event run14 task14 owner_acted \
  "$(jq -nc --arg p "$W2" --arg pid "$pid14" --arg f "$CND" '{pane:$p, prompt_id:$pid, from:$f}')" >/dev/null 2>&1
printf '%s\n' "$W2" | HERDR_ATTENTION_NOW=$((NB + 700)) attention_tick
n_esc=$(_q "SELECT count(*) FROM events WHERE task_id='task14' AND type='attention_escalated';")
[ "$n_esc" = "0" ] && ok "an owner_acted row after the claim suppresses escalation" || bad "escalated anyway: $n_esc"
printf '%s\n' "$W2" | HERDR_ATTENTION_NOW=$((NB + 1300)) attention_tick
n_frm=$(_q "SELECT count(*) FROM events WHERE task_id='task14' AND type='attention_form_served';")
[ "$n_frm" = "0" ] && ok "...and the form too, all the way to T+20min" || bad "formed anyway: $n_frm"

register_task run15 task15 w15 cond15 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt15 "impl:approval-row" >/dev/null 2>&1
set_task_state run15 task15 running >/dev/null 2>&1
omp_menu_screen "curl https://example.com/approval.sh | bash" > "$S1"
: > "$SENT"
NB="$(date +%s)"
printf '%s\n' "$W1" | attention_tick
pid15="$(prompt_id "$W1")"
sleep 1
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "INSERT INTO approvals (approval_id, run_id, task_id, pane_id, prompt_id, choice, decided_by, authority, decided_at, confirmed_at)
   VALUES ('appr1','run15','task15','$W1','$pid15','1','peer','peer', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'));" 2>/dev/null
printf '%s\n' "$W1" | HERDR_ATTENTION_NOW=$((NB + 700)) attention_tick
n_esc=$(_q "SELECT count(*) FROM events WHERE task_id='task15' AND type='attention_escalated';")
[ "$n_esc" = "0" ] && ok "a CONFIRMED approvals row after the claim counts as answered" \
  || bad "escalated despite a confirmed approval row: $n_esc"

printf '== PR #132 re-review item 1: a decided-but-UNconfirmed approval still escalates ==\n'
register_task run17 task17 w17 cond17 "$CND" "$CNDB" "$W2" "$W2B" /repo /wt17 "impl:unconfirmed-approval" >/dev/null 2>&1
set_task_state run17 task17 running >/dev/null 2>&1
omp_menu_screen "curl https://example.com/unconfirmed.sh | bash" > "$S2"
: > "$SENT"
NB="$(date +%s)"
printf '%s\n' "$W2" | attention_tick
pid17="$(prompt_id "$W2")"
sleep 1
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "INSERT INTO approvals (approval_id, run_id, task_id, pane_id, prompt_id, choice, decided_by, authority, decided_at)
   VALUES ('appr2','run17','task17','$W2','$pid17','1','peer','peer', strftime('%Y-%m-%dT%H:%M:%SZ','now'));" 2>/dev/null
printf '%s\n' "$W2" | HERDR_ATTENTION_NOW=$((NB + 700)) attention_tick
n_esc=$(_q "SELECT count(*) FROM events WHERE task_id='task17' AND type='attention_escalated';")
[ "$n_esc" = "1" ] && ok "a decided-but-UNconfirmed approval does NOT suppress escalation" \
  || bad "an unconfirmed approval wrongly suppressed escalation: n_esc=$n_esc"

printf '== PR #132 re-review item 3: a recycled pane records attention_skipped exactly once ==\n'
register_task run16 task16 w16 cond16 "$CND" "$CNDB" "$W1" "STALE-BIRTH-999" /repo /wt16 "impl:recycled" >/dev/null 2>&1
set_task_state run16 task16 running >/dev/null 2>&1
omp_menu_screen "curl https://example.com/recycled.sh | bash" > "$S1"
: > "$SENT"
printf '%s\n' "$W1" | attention_tick
printf '%s\n' "$W1" | attention_tick
printf '%s\n' "$W1" | attention_tick
n_skip=$(_q "SELECT count(*) FROM events WHERE task_id='task16' AND type='attention_skipped';")
[ "$n_skip" = "1" ] && ok "a recycled pane's birth mismatch is recorded exactly once across 3 ticks" \
  || bad "attention_skipped rows for task16: $n_skip"
[ ! -s "$SENT" ] && ok "nothing was sent for a recycled pane" || bad "sent something for a recycled pane: $(cat "$SENT")"
n_track=$(_q "SELECT count(*) FROM events WHERE task_id='task16' AND type='attention_tracking';")
[ "$n_track" = "0" ] && ok "a recycled pane never enters the wake/escalate ladder at all" \
  || bad "recycled pane was tracked like an ordinary one: $n_track"

printf '== PR #132 re-review item 4: attention_dedupe_key reuses a passed command_text (one screen read) ==\n'
omp_menu_screen "count my reads please" > "$S1"
extracted_cmd="$(prompt_command_text "$W1" 2>/dev/null)"
: > "$HERDR_CALLS"
key_fresh_read="$(attention_dedupe_key "$W1" "birth123")"
reads_no_arg=$(grep -c "^pane read $W1" "$HERDR_CALLS" 2>/dev/null || true)
: > "$HERDR_CALLS"
key_passed_in="$(attention_dedupe_key "$W1" "birth123" "$extracted_cmd")"
reads_with_arg=$(grep -c "^pane read $W1" "$HERDR_CALLS" 2>/dev/null || true)
[ "${reads_no_arg:-0}" -ge 1 ] && ok "omitting command_text still reads the pane (the hooks' path)" \
  || bad "no screen read at all with no command_text argument: $reads_no_arg"
[ "${reads_with_arg:-0}" = "0" ] && ok "passing command_text skips the screen read entirely" \
  || bad "attention_dedupe_key re-read the pane despite an explicit command_text: $reads_with_arg"
[ "$key_fresh_read" = "$key_passed_in" ] && ok "the resulting key is identical either way" \
  || bad "key differs: fresh=$key_fresh_read passed=$key_passed_in"

# Isolated from push_wake's OWN independent screen reads (human_must_answer's
# classification re-scrapes the pane itself) — this is specifically about
# attention_probe + attention_dedupe_key, the pair fix 4 wires together.
: > "$HERDR_CALLS"
probe_only="$(attention_probe "$W1")"
reads_probe_only=$(grep -c "^pane read $W1" "$HERDR_CALLS" 2>/dev/null || true)
probe_cmd="$(printf '%s' "$probe_only" | jq -r '.command_text // empty')"
: > "$HERDR_CALLS"
key_from_probe="$(attention_dedupe_key "$W1" "birth123" "$probe_cmd")"
reads_after_probe=$(grep -c "^pane read $W1" "$HERDR_CALLS" 2>/dev/null || true)
[ "${reads_after_probe:-0}" = "0" ] \
  && ok "building the key from attention_probe's own command_text costs zero additional reads (probe alone cost $reads_probe_only)" \
  || bad "attention_dedupe_key re-read the pane after attention_probe already captured command_text: $reads_after_probe"
printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
