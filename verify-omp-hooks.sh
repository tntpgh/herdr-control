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
# Where the herdr stub records its RPCs. Exported for the same reason WAKE is:
# the stub runs inside child shells.
export HERDR_CALLS="$WORK/herdr.calls"

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
  # Record every RPC when a test asks: "how many pane reads did that cost?" is
  # a real assertion, because a per-entry RPC inside a budgeted loop turns an
  # O(MAX) run into an O(queue) one that outlives its hook timeout.
  [ -n "${HERDR_CALLS:-}" ] && printf '%s\n' "$sub" >> "$HERDR_CALLS"
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
      printf 'send-keys %s %s\n' "$3" "$4" >> "$SENT"
      # send-to-agent.sh now CONFIRMS a submit by diffing the composer
      # before/after Enter (see send-to-agent.sh's header, 2026-08-06) rather
      # than assuming success whenever no paste-placeholder is present — so a
      # stub pane must actually CHANGE after Enter, the way a real one does,
      # or every wake in this suite would read back as UNSUBMITTED.
      if [ "$3" = "$CPANE" ] && [ "$4" = "Enter" ]; then
        { printf ' %s\n' "$(cat "$WAKE" 2>/dev/null)"; printf '\n submitted\n $ \n ready\n'; } > "$COND_SCREEN"
      fi
      ;;
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

. "$here/lib/prompt-parse.sh"
printf '== current boxed omp menu: command details are not choices ==\n'
printf '╭─ Allow tool: bash ─╮\n│\n│ Command: printf smoke │\n│\n│ \033[48;2;42;47;65m  Approve\033[0m │\n│ Deny │\n│\n│ up/down navigate  enter select  esc cancel │\n╰──╯\n' > "$WORKER_SCREEN"
[ "$(prompt_menu_options "$WPANE")" = "$(printf '1\tApprove\n2\tDeny')" ] \
  && ok "only actual choices are offered" || bad "command detail parsed as an option"
[ "$(prompt_menu_selected "$WPANE")" = 1 ] \
  && ok "Approve is selected as option 1" || bad "highlight points to wrong option"
printf '%s' "$(prompt_menu_question "$WPANE")" | grep -q 'Command: printf smoke' \
  && ok "command remains in the prompt identity" || bad "command omitted from question"
: > "$SENT"
bash "$here/herdr-select.sh" "$WPANE" 1 --authority peer >"$WORK/select.out" 2>"$WORK/select.err"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$SENT")" = "send-keys $WPANE Enter" ] \
  && ok "boxed approval selects once without bogus arrow navigation" \
  || bad "selection failed: $(cat "$WORK/select.err") $(cat "$SENT")"
printf '╭─ Allow tool: bash ─╮\n│ Command: printf smoke │\n│ Approve │\n│ Deny │\n' > "$WORKER_SCREEN"
[ -z "$(prompt_menu_options "$WPANE")" ] \
  && ok "truncated menu offers no actionable choices" || bad "accepted incomplete menu"
printf 'Allow tool: bash\n\nApprove\nAlways allow\nDeny\nup/down navigate  enter select  esc cancel\n' > "$WORKER_SCREEN"
[ -z "$(prompt_menu_options "$WPANE")" ] \
  && ok "unknown additional permission choice fails closed" || bad "accepted unknown menu"
prompt_menu_visible "$WPANE" && ok "unknown menu still requires attention" || bad "unknown menu hidden from notifier"
omp_menu_screen "printf 'enter select'" > "$WORKER_SCREEN"
[ "$(prompt_menu_selected "$WPANE")" = 1 ] \
  && ok "footer words inside a command do not hide its menu" || bad "command text mistaken for navigation footer"
printf 'Task complete.\n' >> "$WORKER_SCREEN"
[ -z "$(prompt_menu_options "$WPANE")" ] && ! prompt_menu_visible "$WPANE" \
  && ok "dismissed menu above new output is not actionable" || bad "stale menu still active"


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

printf '== the alert LIFECYCLE: an answered alert is retracted, a live one is not ==\n'
# The failure this pins, observed 2026-09-06: 85 alerts from two overnight
# workers still sat in Slack the next morning with live Approve/Deny buttons,
# every one already answered in the terminal (approvals.decided_by='cli') and
# both panes long closed. herdr-select untracked each alert from pending.jsonl
# the moment it pressed a key, and herdr-resolve only ever looks at
# pending.jsonl — so the retraction it exists to perform could never happen.
LC="$WORK/lifecycle"; mkdir -p "$LC"
lc_pending() { printf '%s\n' "$@" > "$LC/pending.jsonl"; }
lc_ts() { jq -r .ts < "$LC/pending.jsonl" | tr '\n' ' '; }
# Slack message ts values are epoch-seconds.micros, and herdr-resolve gives up
# on an alert older than HERDR_RESOLVE_MAX_AGE_D — so fixtures must be dated
# like the real thing or every one of them ages out mid-test.
NOW=$(date +%s)
T1="$NOW.1"; T2="$NOW.2"; TG="$NOW.3"; T5="$NOW.5"
# An alert older than the age cap, for the give-up test further down.
TOLD=$(( NOW - 30 * 86400 )).9
A1='{"ts":"'"$T1"'","pane":"'"$WPANE"'"}'
A2='{"ts":"'"$T2"'","pane":"'"$WPANE"'"}'
GONE='{"ts":"'"$TG"'","pane":"wZ:p9"}'

omp_menu_screen "printf smoke" > "$WORKER_SCREEN"
lc_pending "$A1" "$GONE"
dry="$(HERDR_BRIDGE_STATE="$LC" bash "$here/herdr-resolve.sh" --dry-run 2>&1)"
printf '%s' "$dry" | grep -q "$T1" \
  && bad "retracted an alert whose omp menu is still on screen: $dry" \
  || ok "a live menu-shape prompt keeps its alert"
printf '%s' "$dry" | grep -q "ts=$TG pane=wZ:p9 (pane gone)" \
  && ok "an alert for a pane herdr no longer lists is retracted" \
  || bad "orphaned alert kept forever: $dry"
[ "$(lc_ts)" = "$T1 $TG " ] \
  && ok "a dry run reports without rewriting the queue" || bad "dry run mutated pending.jsonl"

clean_screen > "$WORKER_SCREEN"
dry="$(HERDR_BRIDGE_STATE="$LC" bash "$here/herdr-resolve.sh" --dry-run 2>&1)"
printf '%s' "$dry" | grep -q "ts=$T1 .* (prompt answered)" \
  && ok "the prompt going away retracts its alert" || bad "answered alert kept: $dry"

# What Slack ANSWERED decides whether the entry may leave the queue. Provoked
# for real 2026-09-06: sweeping the 85-alert backlog at ~5/s, the last two
# deletes came back `ratelimited` and were dropped as though they had
# succeeded — both messages were still sitting in Slack afterwards.
CURLSTUB="$WORK/curl-stub.sh"
cat > "$CURLSTUB" <<'EOS'
#!/usr/bin/env bash
cat >/dev/null                      # swallow the --config token on stdin
printf 'stub\n' >> "$CURL_CALLS"
# Simulate herdr-notify appending a NEW alert while the sweep is mid-flight:
# this runs at exactly the moment the real curl would be talking to Slack.
[ -n "${CURL_APPEND:-}" ] && printf '%s\n' "$CURL_APPEND" >> "$HERDR_BRIDGE_STATE/pending.jsonl"
printf '%s' "$CURL_REPLY"
EOS
chmod +x "$CURLSTUB"
export CURL_CALLS="$WORK/curl.calls"
resolve_stubbed() {                 # <reply-json> [max] -> run with a fake Slack
  : > "$CURL_CALLS"
  CURL_REPLY="$1" HERDR_RESOLVE_CURL="$CURLSTUB" HERDR_RESOLVE_PACE_S=0 \
    HERDR_RESOLVE_MAX_PER_RUN="${2:-8}" HERDR_BRIDGE_STATE="$LC" \
    bash "$here/herdr-resolve.sh" >/dev/null 2>&1
}
resolve_stubbed_appending() {       # <reply-json> -> ... and append CURL_APPEND mid-sweep
  : > "$CURL_CALLS"
  CURL_REPLY="$1" HERDR_RESOLVE_CURL="$CURLSTUB" HERDR_RESOLVE_PACE_S=0 \
    HERDR_RESOLVE_MAX_PER_RUN=8 HERDR_BRIDGE_STATE="$LC" CURL_APPEND="${CURL_APPEND:-}" \
    bash "$here/herdr-resolve.sh" >/dev/null 2>&1
}

lc_pending "$GONE"
resolve_stubbed '{"ok":false,"error":"ratelimited"}'
[ "$(lc_ts)" = "$TG " ] \
  && ok "a rate-limited delete stays queued (retried next pass)" \
  || bad "rate-limited retraction dropped: $(lc_ts)"

lc_pending "$GONE"
resolve_stubbed ''
[ "$(lc_ts)" = "$TG " ] \
  && ok "an unreachable Slack stays queued" || bad "lost the alert offline: $(lc_ts)"

lc_pending "$GONE"
resolve_stubbed '{"ok":false,"error":"message_not_found"}'
[ -z "$(lc_ts)" ] \
  && ok "a refusal that will refuse again leaves the queue" \
  || bad "definitive error kept forever: $(lc_ts)"

lc_pending "$GONE"
resolve_stubbed '{"ok":true}'
[ -z "$(lc_ts)" ] && ok "a deleted alert leaves the queue" || bad "deleted alert still queued"

# A hook has ~10s. A backlog must drain across passes, not be cut off mid-sweep.
lc_pending '{"ts":"'"$NOW"'.901","pane":"wZ:p9"}' '{"ts":"'"$NOW"'.902","pane":"wZ:p9"}' \
           '{"ts":"'"$NOW"'.903","pane":"wZ:p9"}' '{"ts":"'"$NOW"'.904","pane":"wZ:p9"}'
resolve_stubbed '{"ok":true}' 2
[ "$(grep -c stub "$CURL_CALLS")" = 2 ] && [ "$(lc_ts)" = "$NOW.903 $NOW.904 " ] \
  && ok "the per-run delete budget is honoured and the rest stays queued" \
  || bad "budget ignored: calls=$(grep -c stub "$CURL_CALLS") left=$(lc_ts)"

# --- the three defects an independent review pass found in the first draft ---

# 1. The retryable list was an ALLOWLIST, so every unlisted `ok:false` dropped
#    the entry with the message still in Slack. `invalid_auth` is the one that
#    matters: rotate the bot token with a backlog queued and the hook (which
#    fires on every tool call in every session) would drain the whole queue in
#    seconds, leaving armed alerts with no ts->pane record — un-retractable
#    forever. The rule is now "keep unless the answer is definitive".
lc_pending "$GONE"
resolve_stubbed '{"ok":false,"error":"invalid_auth"}'
[ "$(lc_ts)" = "$TG " ] \
  && ok "a rejected token keeps the alert queued (re-auth fixes it, dropping does not)" \
  || bad "auth failure dropped the alert: $(lc_ts)"

# 2. The sweep used to end in `cat snapshot > pending.jsonl`. With paced deletes
#    that window is seconds long, and herdr-notify appends the moment any worker
#    hits a prompt — so a live alert arriving mid-sweep was erased, leaving an
#    armed Slack message with no record. Settling by ts against the LIVE file
#    makes concurrent appends survive by construction.
lc_pending "$GONE"
CURL_APPEND='{"ts":"'"$T5"'","pane":"wZ:p9"}' resolve_stubbed_appending '{"ok":true}'
printf '%s' "$(lc_ts)" | grep -q "$T5" \
  && ok "an alert appended mid-sweep survives the sweep" \
  || bad "concurrent alert erased by the sweep: $(lc_ts)"
printf '%s' "$(lc_ts)" | grep -q "$TG" \
  && bad "the settled alert was not removed: $(lc_ts)" \
  || ok "the settled alert is still removed"

# 3. Two hooks firing together would both snapshot and both delete. All three
#    writers take one mutex, with a bounded wait — see 4-7 for why the first
#    draft's non-blocking version was a live defect.
lc_pending "$GONE"
mkdir -p "$LC/.pending.lock"
PENDING_LOCK_WAIT_S=0 resolve_stubbed '{"ok":true}'
# wc, not `grep -c`: grep exits 1 on zero matches, so a `|| echo 0` fallback
# emits a SECOND zero and the comparison never matches.
[ "$(wc -l < "$CURL_CALLS" | tr -d ' ')" = 0 ] && [ "$(lc_ts)" = "$TG " ] \
  && ok "a second concurrent sweep does nothing while the lock is held" \
  || bad "lock ignored: calls=$(wc -l < "$CURL_CALLS" | tr -d ' ') left=$(lc_ts)"
rmdir "$LC/.pending.lock"

# --- and the four the RE-review found in the fix itself ---------------------

# 4. THE defect: herdr-select took the lock non-blocking and skipped its untrack
#    when the sweep held it, on the theory that "retracted later" is safe. It is
#    not: that message carries the operator's choice and the bridge's
#    confirmation. Worse, the collision is caused BY the keypress — the Enter
#    unblocks the worker, whose next tool call starts a sweep microseconds
#    later. So the untrack must WAIT for the lock.
omp_menu_screen "printf smoke" > "$WORKER_SCREEN"
lc_pending "$A1" "$A2"
mkdir -p "$LC/.pending.lock"
( sleep 1; rmdir "$LC/.pending.lock" ) &        # a sweep holding it, then done
HERDR_BRIDGE_STATE="$LC" HERDR_SELECT_VIA=slack-button HERDR_SELECT_TS="$T1" \
  PENDING_LOCK_WAIT_S=5 bash "$here/herdr-select.sh" "$WPANE" 1 --authority peer \
  >/dev/null 2>&1
wait
[ "$(lc_ts)" = "$T2 " ] \
  && ok "a Slack answer waits for the lock instead of leaving its own message retractable" \
  || bad "untrack skipped under contention: $(lc_ts)"

# 5. A SIGKILL at the hook timeout leaves the lockdir with no trap to remove it.
#    Without reclaim that disables retraction permanently and silently.
lc_pending "$GONE"
mkdir -p "$LC/.pending.lock"
touch -t 202001010000 "$LC/.pending.lock"       # ancient => stale
PENDING_LOCK_STALE_S=60 resolve_stubbed '{"ok":true}'
[ -z "$(lc_ts)" ] \
  && ok "a stale lock is reclaimed rather than blocking retraction forever" \
  || bad "stale lock not reclaimed: $(lc_ts)"
rmdir "$LC/.pending.lock" 2>/dev/null

# 6. Slack has permanent refusals this cannot enumerate (missing_scope,
#    compliance_exports_prevent_deletion, ...). Keeping on uncertain is right,
#    but unbounded: nothing trims this file, and a pinned entry burns the
#    per-run budget on every pass forever.
lc_pending '{"ts":"'"$TOLD"'","pane":"wZ:p9"}'
resolve_stubbed '{"ok":false,"error":"missing_scope"}'
[ -z "$(lc_ts)" ] \
  && ok "an alert Slack has refused for weeks is finally given up on" \
  || bad "queue grows without bound: $(lc_ts)"

# 7. The budget was checked AFTER the per-entry pane RPCs, so a run cost
#    O(queue) rather than O(MAX) — and a stuck queue then pushed every hook
#    past the same 10s timeout the lock's safety depends on. One entry
#    legitimately costs several reads (the explicit probe plus both prompt
#    parsers), so the property is that the cost tracks the BUDGET: a queue of
#    three must cost no more than a queue of one at the same budget.
clean_screen > "$WORKER_SCREEN"
: > "$HERDR_CALLS"
lc_pending "$A1"
resolve_stubbed '{"ok":true}' 1
one=$(grep -c 'pane read' "$HERDR_CALLS")
: > "$HERDR_CALLS"
lc_pending "$A1" "$A2" '{"ts":"'"$NOW"'.7","pane":"'"$WPANE"'"}'
resolve_stubbed '{"ok":true}' 1
three=$(grep -c 'pane read' "$HERDR_CALLS")
[ "$three" = "$one" ] \
  && ok "per-run RPC cost tracks the delete budget, not the queue length" \
  || bad "run cost is O(queue): $one pane reads for 1 queued, $three for 3, same budget"

# Answered in the TERMINAL: nothing is posted to Slack, so the alert must stay
# TRACKED for herdr-resolve to delete. This is the exact line that produced the
# 85-alert backlog.
omp_menu_screen "printf smoke" > "$WORKER_SCREEN"
lc_pending "$A1" "$A2"
HERDR_BRIDGE_STATE="$LC" bash "$here/herdr-select.sh" "$WPANE" 1 --authority peer \
  >/dev/null 2>&1
[ "$(lc_ts)" = "$T1 $T2 " ] \
  && ok "a terminal answer leaves the alert tracked for retraction" \
  || bad "terminal answer orphaned the alert: $(lc_ts)"

# Answered in SLACK: the bridge posts the confirmation under that message, so
# retracting it would delete the operator's own decision. Untrack THAT alert —
# and only that one, because a pane can have several queued.
HERDR_BRIDGE_STATE="$LC" HERDR_SELECT_VIA=slack-button HERDR_SELECT_TS="$T1" \
  bash "$here/herdr-select.sh" "$WPANE" 1 --authority peer >/dev/null 2>&1
[ "$(lc_ts)" = "$T2 " ] \
  && ok "a Slack answer untracks only the alert that carried it" \
  || bad "wrong alerts untracked: $(lc_ts)"

# A Slack message is permanent, so its buttons are too. The value must pin the
# QUESTION, not just the pane: herdr recycles pane ids, and a click on last
# night's alert would otherwise land on whatever prompt lives there now.
omp_menu_screen "printf smoke" > "$WORKER_SCREEN"
want_pid="$(prompt_id "$WPANE")"
vals="$(HERDR_BRIDGE_STATE="$WORK/nb2" bash "$here/slack-bridge/herdr-notify.sh" \
  --dry-run --choices --pane "$WPANE" "omp needs your permission" 2>&1 \
  | sed -n '/--- button values ---/,$p')"
printf '%s' "$vals" | grep -qxF "$WPANE|1|$want_pid" \
  && ok "button value pins pane, option AND prompt fingerprint" \
  || bad "button value cannot survive pane reuse: $vals"
: > "$SENT"
bash "$here/herdr-select.sh" "$WPANE" 1 --authority peer \
  --expect-prompt-id "deadbeef-not-this-question" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ ! -s "$SENT" ] \
  && ok "a click for a different question presses nothing" \
  || bad "stale fingerprint answered the wrong prompt (rc=$rc sent=$(cat "$SENT"))"

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
set_task_state run1 task1 running >/dev/null 2>&1
CBIRTH="cterm-DIFFERENT"
run_notify bash
[ ! -s "$SENT" ] && ok "nothing delivered into a recycled conductor pane" || bad "delivered anyway: $(cat "$SENT")"
[ "$(q_event push_wake_refused)" -ge 1 ] && ok "push_wake_refused recorded" || bad "no push_wake_refused event"
[ "$(q_state)" = blocked ] && ok "blocked state survives unreachable conductor" || bad "worker hidden by failed conductor delivery"
CBIRTH="cterm-1"

printf '== conductorless worker still persists its verified input request ==\n'
set_task_state run1 task1 running >/dev/null 2>&1
CPANE=""
: > "$SENT"
run_notify bash
[ "$(q_state)" = blocked ] && [ ! -s "$SENT" ] \
  && ok "conductorless prompt is blocked without injecting anywhere" || bad "conductorless input request lost"
CPANE="w2:p1"

printf '== unknown menu remains alertable but not auto-selectable ==\n'
printf 'Allow tool: bash\n\nApprove\nAlways allow\nDeny\nup/down navigate  enter select  esc cancel\n' > "$WORKER_SCREEN"
clean_screen > "$COND_SCREEN"
: > "$NOTIFIED"
run_notify bash
[ -s "$NOTIFIED" ] && ok "unrecognized choices still produce an alert" || bad "strict selection parser hid a real prompt"

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

printf '== envelope contract: undelivered session report replays until acked ==\n'
# The session pass above emitted its envelope and nobody acked it — exactly a
# consumer that died between delivery and ack. The report must REPLAY.
env_s1="$(bash "$here/agent-hooks/omp-reconcile.sh" session 2>/dev/null)"
printf '%s' "$env_s1" | jq -e '.ack_required == true' >/dev/null 2>&1 \
  && ok "session envelope demands an ack" || bad "no ack-demanding envelope: $env_s1"
printf '%s' "$env_s1" | jq -r '.report' | grep -q 'wake-persistence' \
  && ok "unacked report replays across passes" || bad "unacked report lost: $env_s1"
printf '%s' "$env_s1" | bash "$here/agent-hooks/omp-reconcile.sh" ack 2>/dev/null
env_s2="$(bash "$here/agent-hooks/omp-reconcile.sh" session 2>/dev/null)"
printf '%s' "$env_s2" | jq -e '.ack_required == false' >/dev/null 2>&1 \
  && ok "acked report stops replaying (ack committed states + cursor)" || bad "still pending after ack: $env_s2"
printf 'garbage not json' | bash "$here/agent-hooks/omp-reconcile.sh" ack 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "garbage ack is a no-op, never a crash" || bad "garbage ack exit $rc"

printf '== terminal task: hook rejected BEFORE state change or actionable event ==\n'
# A recycled pane's next occupant inherits stale HERDR_RUN_ID/TASK_ID env; a
# hook already in flight can fire after the sweep buried its task. Neither
# may resurrect state OR append a fresh "needs input" fact for a dead task.
set_task_state run1 task1 running >/dev/null 2>&1
set_task_state run1 task1 completed >/dev/null 2>&1
omp_menu_screen "stale-test-cmd" > "$WORKER_SCREEN"
clean_screen > "$COND_SCREEN"
: > "$SENT"
n_input_before=$(q_event input_required)
run_notify bash
[ "$(q_state)" = "completed" ] && ok "terminal state not resurrected to blocked" || bad "state=$(q_state)"
[ "$(q_event input_required)" = "$n_input_before" ] \
  && ok "no input_required appended for a dead task" || bad "dead task generated an actionable event"
[ "$(q_event stale_worker_hook_refused)" -ge 1 ] \
  && ok "refusal recorded (reconciliation surfaces it)" || bad "stale hook refused silently"
printf '%s' "$(q_payload stale_worker_hook_refused)" | grep -q '"reason":"task_terminal"' \
  && ok "refusal names the reason" || bad "refusal payload: $(q_payload stale_worker_hook_refused)"
[ ! -s "$SENT" ] && ok "no wake typed for a terminal task" || bad "woke the conductor about a dead task: $(cat "$SENT")"

printf '== repeated wake attempts: every outcome recorded, first result not frozen ==\n'
# The old constant event ids ("<base>_result") + INSERT OR IGNORE preserved
# the FIRST transport outcome forever: a wake that succeeded then failed on
# re-prompt (or vice versa) was unrecordable. Two attempts at the SAME
# logical prompt must yield two correlated, individually identifiable rows.
register_task run3 task3 w3 cond3 "$CPANE" "$CBIRTH" "$WPANE" "$WBIRTH" /repo /wt3 "impl:attempts" >/dev/null 2>&1
run_notify_for() {                      # <run> <task> <tool>
  printf '{"tool":"%s","message":"omp needs permission","cwd":"/tmp/repo"}' "$3" \
    | ( export HERDR_PANE_ID="$WPANE" HERDR_CONDUCTOR_PANE_ID="$CPANE" \
               HERDR_RUN_ID="$1" HERDR_TASK_ID="$2" HERDR_TASK_LABEL="impl:attempts"
        bash "$here/agent-hooks/omp-notify.sh" >/dev/null 2>&1 )
}
omp_menu_screen "attempt-cmd-A" > "$WORKER_SCREEN"
clean_screen > "$COND_SCREEN"
run_notify_for run3 task3 bash          # conductor clean -> submitted
omp_menu_screen "attempt-cmd-A" > "$WORKER_SCREEN"   # SAME logical prompt again
omp_menu_screen "busy" > "$COND_SCREEN"              # conductor mid-prompt -> refused
run_notify_for run3 task3 bash
n_res=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "SELECT count(*) FROM events WHERE type='wake_result' AND task_id='task3';")
[ "$n_res" = "2" ] && ok "both attempts recorded ($n_res rows)" || bad "wake_result rows for task3: $n_res"
outcomes=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "SELECT json_extract(payload,'\$.outcome') FROM events WHERE type='wake_result' AND task_id='task3' ORDER BY sequence;")
printf '%s' "$outcomes" | head -1 | grep -q 'submitted' \
  && ok "first attempt's outcome preserved (submitted)" || bad "outcomes: $outcomes"
printf '%s' "$outcomes" | tail -1 | grep -qE 'refused|unsubmitted' \
  && ok "second attempt's DIFFERENT outcome recorded, not swallowed by dedup" || bad "outcomes: $outcomes"
n_keys=$(sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" \
  "SELECT count(DISTINCT json_extract(payload,'\$.wake_key')) FROM events WHERE type='wake_result' AND task_id='task3';")
[ "$n_keys" = "1" ] && ok "both rows correlate to the same logical prompt (wake_key)" || bad "wake_key count: $n_keys"

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
console.log("INJECTED:" + (bas && bas.message ? bas.message.content : "none"));
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
  # #37 moved the reconciliation report to the hub page and left AT MOST a
  # one-line hub summary in the prompt; 0fbece0's report-injection contract is
  # gone. What must hold now is that nothing else leaks into context — a raw
  # envelope or a 20-line report in the first turn is the failure.
  printf '%s' "$shim_out" | grep -qE 'INJECTED:(none|hub: )' \
    && ok "the first turn gets a hub one-liner at most, never the report" \
    || bad "reconcile output leaked into context: $shim_out"
  grep -q '"tool":"bash"' "$REC.notify" \
    && ok "omp-notify.sh received the documented stdin JSON" || bad "notify stdin wrong: $(cat "$REC.notify" 2>/dev/null)"
  grep -q 'RECONCILE mode=session'  "$REC" && ok "session reconcile invoked"  || bad "no session reconcile"
  grep -q 'RECONCILE mode=interval' "$REC" && ok "interval reconcile invoked" || bad "no interval reconcile"
  grep -q 'RESOLVE' "$REC" && ok "alert retraction invoked" || bad "no retraction"

  printf '== TS shim: every envelope is ACKED, and no report enters the prompt ==\n'
  # History matters here, because these assertions were pointed the wrong way
  # for two releases. 0fbece0 delivered the report through pi.sendMessage and
  # acked only on delivery; #37 moved reports to the hub page and left at most
  # a one-line hub summary in the prompt, deleting sendMessage entirely. The
  # tests kept asserting the deleted design and failed on main from then on —
  # a red suite nobody could act on. The contract that IS current:
  #   * the reconcile report NEVER reaches the conversation, session or interval
  #   * both envelopes are still acked exactly once, carried back verbatim, so
  #     the registry cursor advances and the page picks the history up
  #   * acking no longer depends on a delivery channel that no longer exists
  SHIM2="$WORK/shim2"; mkdir -p "$SHIM2/agent-hooks"
  cat > "$SHIM2/agent-hooks/omp-notify.sh" <<'EOS'
#!/usr/bin/env bash
cat >/dev/null
EOS
  cat > "$SHIM2/agent-hooks/omp-reconcile.sh" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  session)  printf '{"report":"wake-persistence: session hello","ack_required":true,"conductor_id":"condZ","task_states":{},"last_event_seq":4}\n' ;;
  interval) printf '{"report":"wake-persistence: deferred hello","ack_required":true,"conductor_id":"condZ","task_states":{},"last_event_seq":9}\n' ;;
  ack)      cat >> "$REC2.ack"; printf 'ACK\n' >> "$REC2" ;;
esac
exit 0
EOS
  cat > "$SHIM2/herdr-resolve.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "$SHIM2/agent-hooks/"*.sh "$SHIM2/herdr-resolve.sh"
  export REC2="$SHIM2/rec.log"; : > "$REC2"; : > "$REC2.ack"
  shim2_out="$(HERDR_CONTROL_DIR="$SHIM2" bun -e '
const mod = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const handlers = {};
const sent = [];
mod.default({ on: (ev, fn) => { handlers[ev] = fn; }, sendMessage: (m) => { sent.push(m); } });
const bas = handlers["before_agent_start"]({});
console.log("SESSION_INJECT:" + (bas && bas.message ? bas.message.content : "none"));
handlers["tool_result"]({ toolName: "bash", isError: false, content: [] });
await new Promise(r => setTimeout(r, 800));
console.log("SENT:" + sent.length + ":" + (sent[0] ? sent[0].content : ""));
' 2>&1)"
  printf '%s' "$shim2_out" | grep -q 'SESSION_INJECT:wake-persistence' \
    && bad "the session report was injected into the prompt: $shim2_out" \
    || ok "session report stays out of the prompt"
  printf '%s' "$shim2_out" | grep -q 'SESSION_INJECT:{' \
    && bad "raw envelope JSON injected: $shim2_out" || ok "no raw envelope in context"
  printf '%s' "$shim2_out" | grep -q 'SENT:0:' \
    && ok "the interval report is not pushed into the conversation" \
    || bad "mid-session report reached the agent: $shim2_out"
  ack_n=$(grep -c 'ACK' "$REC2" 2>/dev/null || true)
  [ "${ack_n:-0}" = "2" ] && ok "both envelopes acked exactly once each" || bad "ack count: ${ack_n:-0} ($(cat "$REC2" 2>/dev/null))"
  grep -q '"last_event_seq":9' "$REC2.ack" && grep -q '"last_event_seq":4' "$REC2.ack" \
    && ok "acks carry the original envelopes back verbatim" || bad "ack stdin: $(cat "$REC2.ack" 2>/dev/null)"

  # No sendMessage on the API at all: the ack must still happen. Under the old
  # design this was the redelivery guard; under #37 there is nothing to deliver,
  # and withholding the ack here would replay the same envelope forever.
  : > "$REC2"; : > "$REC2.ack"
  HERDR_CONTROL_DIR="$SHIM2" bun -e '
const mod = await import("'"$here"'/agent-hooks/omp-herdr-control.ts");
const handlers = {};
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
handlers["tool_result"]({ toolName: "bash", isError: false, content: [] });
await new Promise(r => setTimeout(r, 800));
' >/dev/null 2>&1
  grep -q 'ACK' "$REC2" \
    && ok "the interval envelope is acked without any delivery channel" \
    || bad "envelope left unacked — it will replay forever: $(cat "$REC2" 2>/dev/null)"
  grep -q '"last_event_seq":9' "$REC2.ack" \
    && ok "that ack still carries the envelope verbatim" \
    || bad "ack stdin: $(cat "$REC2.ack" 2>/dev/null)"
fi

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
