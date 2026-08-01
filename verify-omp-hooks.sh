#!/usr/bin/env bash
# verify-omp-hooks.sh — prove the omp hook path: omp-notify.sh only alerts when a
# prompt REALLY appeared, push_wake records the delivery outcome instead of
# discarding it, and omp-reconcile.sh emits the human report without Claude's
# hook-output JSON envelope.
#
# Stubs herdr as an exported bash function (see verify-select-policy.sh for why
# a PATH stub is not good enough) and stubs the Slack notifier via $HERDR_NOTIFY
# so nothing leaves the machine.
#
#   bash verify-omp-hooks.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_BRIDGE_STATE="$WORK/bridge"
export WORKER_SCREEN="$WORK/worker.txt"
export COND_SCREEN="$WORK/cond.txt"
export SENT="$WORK/sent.log"
export NOTIFIED="$WORK/notified.log"
# Must be EXPORTED, not just set: the herdr stub is an exported bash function, but
# it runs inside child shells (send-to-agent.sh is invoked as `bash <script>`), and
# a plain shell variable does not cross that boundary — the redirect would go to
# /wake.txt and fail silently.
export WAKE="$WORK/wake.txt"

# Belt and braces against a biometric prompt. herdr-notify.sh no longer sources
# the bridge env on the --dry-run path, but this suite dry-runs it, and a future
# test could easily reach a path that does. The real ~/.config/herdr-bridge.env
# resolves both tokens through `op read`, which falls back to a 1Password Touch ID
# prompt in any shell without OP_SERVICE_ACCOUNT_TOKEN — so an unguarded suite
# demanded a thumbprint per run. A test suite must never need a human finger.
#
# The values are deliberately NOT shaped like real Slack tokens (no xoxb-/xapp-
# prefix): the shared pre-commit secret scanner matches on those shapes, and a
# realistic-looking dummy would trip it on every commit. Do not "fix" them.
export HERDR_BRIDGE_ENV="$WORK/bridge.env"
cat > "$HERDR_BRIDGE_ENV" <<'EOS'
SLACK_BOT_TOKEN=DUMMY-NOT-A-REAL-TOKEN
SLACK_APP_TOKEN=DUMMY-NOT-A-REAL-TOKEN
HERDR_BRIDGE_ALLOW_USERS=UDUMMYUSER
HERDR_BRIDGE_TEAM=TDUMMYTEAM
EOS
: > "$SENT"; : > "$NOTIFIED"

WPANE="w1:p1"; WBIRTH="wterm-1"
CPANE="w2:p1"; CBIRTH="cterm-1"
export WPANE WBIRTH CPANE CBIRTH

# Per-pane screens: the worker may be showing a prompt while the conductor is
# not. A single shared screen would make send-to-agent.sh see a prompt on the
# CONDUCTOR and refuse every wake, which would pass for the wrong reason.
herdr() {
  local sub="$1 $2" pane
  case "$sub" in
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    "pane list")
      printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"},{"pane_id":"%s","terminal_id":"%s","cwd":"/tmp"}]}}\n' \
        "$WPANE" "$WBIRTH" "$CPANE" "$CBIRTH" ;;
    "pane read")
      pane="$3"
      if [ "$pane" = "$CPANE" ]; then cat "$COND_SCREEN"; else cat "$WORKER_SCREEN"; fi ;;
    "pane send-text")
      # Record the TEXT, not just the target: the wake body is a contract too —
      # it has to carry the commands the receiver needs to act on it.
      printf 'send-text %s\n' "$3" >> "$SENT"
      printf '%s' "$4" > "$WAKE" ;;
    "pane send-keys")
      printf 'send-keys %s %s\n' "$3" "$4" >> "$SENT" ;;
    *) return 0 ;;
  esac
}
export -f herdr

# Slack notifier stub — records that it was called, sends nothing.
cat > "$WORK/notify.sh" <<'EOS'
#!/usr/bin/env bash
printf 'notified %s\n' "$*" >> "$NOTIFIED"
exit 0
EOS
chmod +x "$WORK/notify.sh"
export HERDR_NOTIFY="$WORK/notify.sh"

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# omp's approval menu: header, blank, rows (highlighted row carries an SGR
# 24-bit background), blank, footer. Only the ANSI form reveals the highlight.
omp_menu_screen() {
  printf ' Allow tool: bash\n'
  printf '   run: %s\n' "$1"
  printf '\n'
  printf '\033[48;2;40;40;40m  Approve\033[0m\n'
  printf '   Deny\n'
  printf '\n'
  printf ' up/down navigate  enter select  esc cancel\n'
}

clean_screen() { printf ' $ \n ready\n'; }

. "$here/lib/run-registry.sh"
register_task run1 task1 w1 cond1 "$CPANE" "$CBIRTH" "$WPANE" "$WBIRTH" /repo /wt "impl:omp-test" >/dev/null 2>&1

printf '== spawn-task.sh must stamp the worker its OWN pane id ==\n'
# A static check, and worth one: this omission silently disabled the ENTIRE omp
# push path and nothing caught it, because every other test supplies
# HERDR_PANE_ID itself. omp-notify.sh refuses to alert without knowing which pane
# to read (it cannot verify a prompt painted), so an unstamped worker no-ops on
# every tool call — a feature that is fully wired, fully tested, and completely
# inert in production. Two other things quietly depend on it too:
# lib/push-wake.sh captures prompt_id only when it is set (so --expect-prompt-id
# was unusable from a push wake), and the wake text names the worker's pane.
# Found by running a real omp worker, not by any of the stubbed suites.
if grep -q 'HERDR_PANE_ID=%q' "$here/spawn-task.sh"; then
  ok "spawn-task.sh stamps HERDR_PANE_ID into the worker environment"
else
  bad "spawn-task.sh does NOT stamp HERDR_PANE_ID — the omp push path is inert"
fi

printf '== the Slack alert must be ANSWERABLE for a menu-shape prompt ==\n'
# Reported live: "I see the message, but no buttons show on slack for me to
# select". herdr-notify.sh built its option list with prompt_options only — the
# NUMBERED parser — so for omp (a highlight menu with no numbers on screen) it
# always came back empty, the alert fell through to the plain-context branch, and
# with no options there were no buttons, no "reply with 1/2" line, and no
# pending.jsonl entry for herdr-resolve.sh to retract. The alert arrived and could
# only be read.
omp_menu_screen "rm -rf /tmp/x" > "$WORKER_SCREEN"
alert_body="$(HERDR_BRIDGE_STATE="$WORK/nb" bash "$here/slack-bridge/herdr-notify.sh" \
  --dry-run --choices --pane "$WPANE" "omp needs your permission" 2>&1 || true)"
printf '%s' "$alert_body" | grep -q 'with buttons' \
  && ok "alert carries Slack buttons" || bad "no buttons built: $alert_body"
printf '%s' "$alert_body" | grep -qE '\*1\.\* Approve' \
  && ok "option 1 Approve rendered" || bad "option 1 missing"
printf '%s' "$alert_body" | grep -qE '\*2\.\* Deny' \
  && ok "option 2 Deny rendered" || bad "option 2 missing"
printf '%s' "$alert_body" | grep -q 'Reply in thread with 1, 2' \
  && ok "threaded-number reply hint present (works with no Slack config)" || bad "no reply hint"
# The question must come from the MENU extractor. prompt_question returns "the
# last non-empty line above the first numbered option"; with no numbered option
# on screen it never stops early and yields the pane's last line, which for omp
# is a box-drawing rule — so choosing it by "is prompt_question empty" silently
# led the alert with a row of ─── where the command should be.
printf '%s' "$alert_body" | grep -q 'Allow tool: bash' \
  && ok "question names the tool and command" || bad "question wrong: $alert_body"
printf '%s' "$alert_body" | grep -qE '^[[:space:]]*─+[[:space:]]*$' \
  && bad "a box-drawing rule leaked in as the question" || ok "no TUI furniture as the question"

run_notify() {                          # <tool> -> runs omp-notify.sh
  printf '{"tool":"%s","message":"omp needs permission","cwd":"/tmp/repo"}' "$1" \
    | ( export HERDR_PANE_ID="$WPANE" HERDR_CONDUCTOR_PANE_ID="$CPANE" \
               HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_TASK_LABEL="impl:omp-test"
        bash "$here/agent-hooks/omp-notify.sh" >"$WORK/n.out" 2>"$WORK/n.err" )
}

q_event() {                             # <type> -> count
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT count(*) FROM events WHERE type='$1';" 2>/dev/null
}
q_payload() {                           # <type> -> newest payload
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT payload FROM events WHERE type='$1' ORDER BY sequence DESC LIMIT 1;" 2>/dev/null
}
q_state() {
  sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
    "SELECT state FROM tasks WHERE task_id='task1';" 2>/dev/null
}

printf '== no prompt on screen -> SILENT, no alert, no wake (storm prevention) ==\n'
clean_screen > "$WORKER_SCREEN"
clean_screen > "$COND_SCREEN"
: > "$SENT"; : > "$NOTIFIED"
run_notify bash
[ ! -s "$NOTIFIED" ] && ok "no Slack alert for an auto-approved tool call" || bad "alerted with no prompt on screen"
[ ! -s "$SENT" ] && ok "no wake delivered" || bad "wake sent with no prompt: $(cat "$SENT")"
[ "$(q_event wake_attempted)" = "0" ] && ok "no wake_attempted event" || bad "wake_attempted recorded spuriously"

printf '== prompt visible, conductor clean -> alert + wake, outcome submitted ==\n'
omp_menu_screen "rm -rf /tmp/x" > "$WORKER_SCREEN"
clean_screen > "$COND_SCREEN"
: > "$SENT"; : > "$NOTIFIED"
run_notify bash
grep -q 'notified' "$NOTIFIED" && ok "Slack alert fired" || bad "no Slack alert"
grep -q -- "--pane $WPANE" "$NOTIFIED" && ok "alert tagged the exact worker pane" || bad "alert did not pass --pane: $(cat "$NOTIFIED")"
grep -q 'send-text' "$SENT" && ok "wake text delivered to the conductor" || bad "no wake text sent"
grep -q "send-text $CPANE" "$SENT" && ok "delivered to the CONDUCTOR pane" || bad "wrong target: $(cat "$SENT")"
[ "$(q_event wake_attempted)" -ge 1 ] && ok "wake_attempted recorded BEFORE the send" || bad "no wake_attempted"
[ "$(q_event wake_result)" -ge 1 ] && ok "wake_result recorded" || bad "no wake_result"
printf '%s' "$(q_payload wake_result)" | grep -q '"outcome":"submitted"' \
  && ok "outcome=submitted (exit code was captured, not discarded)" \
  || bad "outcome payload: $(q_payload wake_result)"
[ "$(q_state)" = "blocked" ] && ok "task transitioned to blocked" || bad "task state=$(q_state)"
printf '%s' "$(q_payload input_required)" | grep -q 'prompt_id' && ok "input_required carries a prompt_id" || bad "no prompt_id in input_required"

printf '== the wake must be ACTIONABLE, not just an instruction to verify ==\n'
# Observed live: a conductor received a wake, had no idea herdr even has a CLI,
# concluded the worker "appears to have already disconnected", and told the human
# so — while the worker sat on a live approval prompt. Telling a receiver to
# "verify before acting" without the commands to verify produced a confidently
# wrong answer, which is worse than no wake.
wake_txt="$(cat "$WAKE" 2>/dev/null)"
printf '%s' "$wake_txt" | grep -q 'HERDR-PEER-SIGNAL' \
  && ok "machine-readable peer-signal prefix" || bad "no prefix: $wake_txt"
printf '%s' "$wake_txt" | grep -q 'not an instruction from the operator' \
  && ok "states it is not operator authority" || bad "missing the authority disclaimer"
printf '%s' "$wake_txt" | grep -q "READ IT: herdr pane read $WPANE" \
  && ok "carries the command to inspect the worker" || bad "no read command: $wake_txt"
printf '%s' "$wake_txt" | grep -q "ANSWER IT:.*herdr-select.sh $WPANE" \
  && ok "carries the command to answer it" || bad "no answer command: $wake_txt"
printf '%s' "$wake_txt" | grep -q 'expect-prompt-id' \
  && ok "answer command pins the prompt_id (TOCTOU close is usable)" || bad "no --expect-prompt-id"
# One line only: send-text types this into a TUI composer, where an embedded
# newline reads as Enter and would submit half a message.
[ "$(printf '%s' "$wake_txt" | wc -l | tr -d ' ')" = "0" ] \
  && ok "single line (a newline would submit the composer early)" || bad "wake spans multiple lines"

printf '== conductor itself showing a prompt -> wake REFUSED and recorded as such ==\n'
# This is the item-4 payoff. send-to-agent.sh refuses (exit 5) rather than press
# Enter into a live prompt; the old fire-and-forget `|| true` threw that away, so
# a wake that never landed logged identically to one that did.
omp_menu_screen "ls" > "$WORKER_SCREEN"
omp_menu_screen "something" > "$COND_SCREEN"   # conductor is mid-prompt
: > "$SENT"
sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "DELETE FROM events WHERE type='wake_result';" 2>/dev/null
run_notify bash
res="$(q_payload wake_result)"
printf '%s' "$res" | grep -qE '"outcome":"(refused|unsubmitted)"' \
  && ok "failed wake recorded as $(printf '%s' "$res" | sed -E 's/.*"outcome":"([a-z_]+)".*/\1/')" \
  || bad "failed wake not recorded honestly: $res"

printf '== a recycled conductor pane refuses the wake ==\n'
omp_menu_screen "ls" > "$WORKER_SCREEN"
clean_screen > "$COND_SCREEN"
: > "$SENT"
CBIRTH="cterm-DIFFERENT"
run_notify bash
[ ! -s "$SENT" ] && ok "nothing delivered into a recycled conductor pane" || bad "delivered anyway: $(cat "$SENT")"
[ "$(q_event push_wake_refused)" -ge 1 ] && ok "push_wake_refused recorded" || bad "no push_wake_refused event"
CBIRTH="cterm-1"

printf '== no HERDR_PANE_ID -> silent (cannot verify a prompt, so must not alert) ==\n'
omp_menu_screen "rm -rf /" > "$WORKER_SCREEN"
: > "$SENT"; : > "$NOTIFIED"
printf '{"tool":"bash","message":"x","cwd":"/tmp"}' \
  | ( unset HERDR_PANE_ID; bash "$here/agent-hooks/omp-notify.sh" >/dev/null 2>&1 )
[ ! -s "$NOTIFIED" ] && ok "no alert without a resolvable pane" || bad "alerted blind"

printf '== omp-reconcile.sh session: human report, NO hook-output JSON ==\n'
out="$(bash "$here/agent-hooks/omp-reconcile.sh" session 2>/dev/null)"
printf '%s' "$out" | grep -q 'wake-persistence' && ok "prints the reconciliation report" || bad "no report: $out"
printf '%s' "$out" | grep -q 'hookSpecificOutput' && bad "leaked Claude's hook JSON into an omp session" || ok "no hookSpecificOutput envelope"

printf '== omp-reconcile.sh interval: throttled silent when not due ==\n'
out2="$(bash "$here/agent-hooks/omp-reconcile.sh" interval 2>/dev/null)"
[ -z "$out2" ] && ok "silent immediately after a session pass (throttle holds)" || bad "spoke when not due: $out2"

printf '== omp-reconcile.sh rejects an unknown mode, still exits 0 ==\n'
bash "$here/agent-hooks/omp-reconcile.sh" bogus >/dev/null 2>"$WORK/r.err"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 (never fails the agent's turn)" || bad "exit $rc"
grep -q 'unknown mode' "$WORK/r.err" && ok "unknown mode explained on stderr" || bad "silent on a bad mode"

printf '== the TS extension shim actually drives these scripts (needs bun) ==\n'
# The shim and the shell scripts were verified separately; this proves they
# compose. Without it, a rename or a changed stdin contract on either side would
# pass both halves and break the whole.
if ! command -v bun >/dev/null 2>&1; then
  printf '  skip  bun not on PATH — cannot exercise the omp extension module\n'
else
  SHIM="$WORK/shim"; mkdir -p "$SHIM/agent-hooks"
  cat > "$SHIM/agent-hooks/omp-notify.sh" <<'EOS'
#!/usr/bin/env bash
# Its OWN file: the other stubs append concurrently, and an interleaved write
# would split this JSON across lines and fail the assertion for the wrong reason.
cat > "$REC.notify"
EOS
  cat > "$SHIM/agent-hooks/omp-reconcile.sh" <<'EOS'
#!/usr/bin/env bash
printf 'RECONCILE mode=%s\n' "$1" >> "$REC"
[ "$1" = session ] && printf 'wake-persistence: 1 task changed\n'
exit 0
EOS
  cat > "$SHIM/herdr-resolve.sh" <<'EOS'
#!/usr/bin/env bash
printf 'RESOLVE\n' >> "$REC"
EOS
  chmod +x "$SHIM/agent-hooks/"*.sh "$SHIM/herdr-resolve.sh"
  export REC="$SHIM/rec.log"; : > "$REC"
  shim_out="$(HERDR_CONTROL_DIR="$SHIM" bun -e '
const mod = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
console.log("EVENTS:" + Object.keys(handlers).sort().join(","));
const tc = handlers["tool_call"]({ toolName: "bash", input: { command: "rm -rf /tmp/x" } });
console.log("TOOLCALL_RETURN:" + (tc === undefined ? "undefined" : JSON.stringify(tc)));
const bas = handlers["before_agent_start"]({});
console.log("INJECTED:" + (bas && bas.message ? "yes" : "no"));
handlers["tool_result"]({ toolName: "bash", isError: false, content: [] });
handlers["agent_end"]({});
await new Promise(r => setTimeout(r, 600));
' 2>&1)"
  printf '%s' "$shim_out" | grep -q 'EVENTS:agent_end,before_agent_start,tool_call,tool_result' \
    && ok "all four events registered" || bad "events: $shim_out"
  # The single most important property: a throwing tool_call handler BLOCKS the
  # agent's tool call in omp, so this must return undefined on every path.
  printf '%s' "$shim_out" | grep -q 'TOOLCALL_RETURN:undefined' \
    && ok "tool_call returns undefined (never blocks the agent)" || bad "tool_call returned non-undefined"
  printf '%s' "$shim_out" | grep -q 'INJECTED:yes' \
    && ok "before_agent_start injects the reconciliation report" || bad "nothing injected"
  grep -q '"tool":"bash"' "$REC.notify" \
    && ok "omp-notify.sh received the documented stdin JSON" || bad "notify stdin wrong: $(cat "$REC.notify" 2>/dev/null)"
  grep -q 'RECONCILE mode=session'  "$REC" && ok "session reconcile invoked"  || bad "no session reconcile"
  grep -q 'RECONCILE mode=interval' "$REC" && ok "interval reconcile invoked" || bad "no interval reconcile"
  grep -q 'RESOLVE' "$REC" && ok "alert retraction invoked" || bad "no retraction"
fi

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
