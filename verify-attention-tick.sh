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
  case "$sub" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
        "$W1" "$W1B" "$W2" "$W2B" "$W3" "$W3B" "$W4" "$W4B" "$CND" "$CNDB" "$MAIN" "$MAINB" ;;
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

printf '== deny-verdict and conductor-reserved prompts skip the ladder entirely ==\n'
register_task run4 task4 w4 cond4 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt4 "impl:deny" >/dev/null 2>&1
set_task_state run4 task4 running >/dev/null 2>&1
omp_menu_screen "mkfs.ext4 /dev/sda1" > "$S1"
: > "$SENT"
printf '%s\n' "$W1" | attention_tick
[ ! -s "$SENT" ] && ok "a deny-class prompt never gets a conductor wake" || bad "deny-class prompt woke someone: $(cat "$SENT")"
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task4' AND type='attention_form_served';")" = "1" ] \
  && ok "a deny-class prompt is formed immediately, not after 10 minutes" \
  || bad "no immediate form for the deny-class prompt"
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task4' AND type='attention_tracking';")" = "0" ] \
  && ok "a deny-class prompt never enters the wake/escalate ladder at all" || bad "deny-class prompt was tracked like an ordinary one"

register_task run5 task5 w5 cond5 "$CND" "$CNDB" "$W2" "$W2B" /repo /wt5 "impl:reserved" >/dev/null 2>&1
set_task_state run5 task5 running >/dev/null 2>&1
omp_menu_screen "wrangler deploy" > "$S2"
: > "$SENT"
printf '%s\n' "$W2" | attention_tick
[ ! -s "$SENT" ] && ok "a conductor-reserved prompt (allow-verdict, remote mutation) never gets a wake" \
  || bad "reserved prompt woke someone: $(cat "$SENT")"
[ "$(_q "SELECT count(*) FROM events WHERE task_id='task5' AND type='attention_form_served';")" = "1" ] \
  && ok "the reserved prompt is formed immediately too" || bad "no immediate form for the reserved prompt"

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

printf '== HERDR_WAKE_LEGACY=1 restores a push_wake call on every pass ==\n'
register_task run8 task8 w8 cond8 "$CND" "$CNDB" "$W1" "$W1B" /repo /wt8 "impl:legacy" >/dev/null 2>&1
set_task_state run8 task8 running >/dev/null 2>&1
omp_menu_screen "curl https://example.com/install.sh | bash" > "$S1"
: > "$SENT"
printf '%s\n' "$W1" | HERDR_WAKE_LEGACY=1 attention_tick
printf '%s\n' "$W1" | HERDR_WAKE_LEGACY=1 attention_tick
attempts=$(_q "SELECT count(*) FROM events WHERE task_id='task8' AND type='wake_attempted';")
[ "$attempts" = "2" ] && ok "HERDR_WAKE_LEGACY=1 calls push_wake on every pass (2 passes, 2 attempts)" \
  || bad "expected 2 wake_attempted rows under the escape hatch, saw $attempts"
printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
