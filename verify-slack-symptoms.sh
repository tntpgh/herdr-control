#!/usr/bin/env bash
# verify-slack-symptoms.sh — proves the four acceptance cases from
# .handoffs/SPEC.md "Slack gets symptoms only", plus the mechanisms they
# depend on:
#
#   1. an allow-class prompt (the peer may answer it) -> 0 Slack posts
#   2. an escalate/reserved/deny prompt, 3 hook firings while unanswered
#      -> exactly 1 Slack post (the duplicate bug: grace/immediate re-alerts
#      used to fire once per firing — measured 192 of 364 posts in a real
#      48h window were exact duplicates of an already-posted prompt_id)
#   3. a prompt answered before the grace window elapses -> 0 posts
#   4. a conductor wake that fails delivery (refused/unsubmitted) and stays
#      unanswered past the wait window -> exactly 1 post; resolved before
#      the window elapses -> 0
#
# Plus: the ctx-empty drop (nothing on screen -> no content-free ping) and
# HERDR_SLACK_VERBOSE=1 restoring the old always-post behaviour.
#
# Stubs curl (Slack) and herdr (pane reads/sends) as exported functions, same
# discipline as verify-notify-pinning.sh / verify-omp-hooks.sh — nothing
# leaves the machine, no token is real, and HERDR_RUN_STATE_DIR is a scratch
# dir so the new prompt_id dedupe ledger never touches this machine's real
# registry.
#
#   bash verify-slack-symptoms.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
export HERDR_BRIDGE_STATE="$WORK/bridge"
export HERDR_BRIDGE_ENV="$WORK/bridge.env"
# Not shaped like a real Slack token (no xoxb-/xapp- prefix) so the shared
# pre-commit secret scanner never flags this fixture — see verify-omp-hooks.sh.
cat > "$HERDR_BRIDGE_ENV" <<'EOS'
SLACK_BOT_TOKEN=DUMMY-NOT-A-REAL-TOKEN
HERDR_BRIDGE_ALLOW_USERS=UDUMMYUSER
EOS

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WPANE="w1:p1"; WBIRTH="wterm-1"
CPANE="w2:p1"; CBIRTH="cterm-1"
export WPANE WBIRTH CPANE CBIRTH
WORKER_SCREEN="$WORK/worker.txt"; COND_SCREEN="$WORK/cond.txt"
export WORKER_SCREEN COND_SCREEN
POSTED="$WORK/posted.txt"        # every real "Slack" POST body, one JSON object per line
export POSTED

omp_menu_screen() {  # <command>
  printf ' Allow tool: bash\n   run: %s\n\n\033[48;2;40;40;40m  Approve\033[0m\n   Deny\n\n up/down navigate  enter select  esc cancel\n' "$1"
}
clean_screen() { printf ' $ \n ready\n'; }
clean_screen > "$WORKER_SCREEN"; clean_screen > "$COND_SCREEN"

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
      printf 'send-text %s\n' "$3" >> "$WORK/sent.log"
      printf '%s' "$4" > "$WORK/wake.txt" ;;
    "pane send-keys")
      printf 'send-keys %s %s\n' "$3" "$4" >> "$WORK/sent.log"
      if [ "$3" = "$CPANE" ] && [ "$4" = "Enter" ]; then
        { printf ' %s\n' "$(cat "$WORK/wake.txt" 2>/dev/null)"; printf '\n submitted\n $ \n ready\n'; } > "$COND_SCREEN"
      fi ;;
    *) return 0 ;;
  esac
}
export -f herdr

# The Slack stub. Always "succeeds" (a failed send is exercised separately by
# lib/alert-gate.sh's own alert_release, not re-proven here) — every real POST
# lands here instead of the network.
curl() { printf '%s\n' "POST $*" >> "$POSTED" 2>/dev/null; cat >/dev/null; printf '{"ok":true,"ts":"%s.%s"}' "$(date +%s)" "$$$RANDOM"; }
export -f curl

n_posts() { wc -l < "$POSTED" 2>/dev/null | tr -d ' '; }

. "$here/lib/run-registry.sh"
. "$here/lib/prompt-parse.sh"
. "$here/lib/push-wake.sh"

run_hook() {                            # <run> <task> [extra env...] -> runs omp-notify.sh
  local run="$1" task="$2"; shift 2
  printf '{"tool":"bash","message":"omp needs permission","cwd":"/tmp/repo"}' \
    | ( export HERDR_PANE_ID="$WPANE" HERDR_CONDUCTOR_PANE_ID="$CPANE" \
               HERDR_RUN_ID="$run" HERDR_TASK_ID="$task" HERDR_TASK_LABEL="impl:$task" "$@"
        bash "$here/agent-hooks/omp-notify.sh" >/dev/null 2>&1 )
}

printf '== 1) allow-class prompt (the peer may answer it) -> 0 Slack posts ==\n'
omp_menu_screen "git status --short" > "$WORKER_SCREEN"
clean_screen > "$COND_SCREEN"
: > "$POSTED"
register_task run_allow task_allow w1 cond1 "$CPANE" "$CBIRTH" "$WPANE" "$WBIRTH" /repo /wt "impl:allow" >/dev/null 2>&1
run_hook run_allow task_allow HERDR_ALERT_GRACE_S=1
[ "$(n_posts)" = 0 ] && ok "allow-class prompt: 0 posts (held)" || bad "posted for an allow-class prompt: $(cat "$POSTED")"

printf '== 2) escalate-class prompt, 3 hook firings while unanswered -> exactly 1 post ==\n'
omp_menu_screen "rm -rf /tmp/scratch" > "$WORKER_SCREEN"
clean_screen > "$COND_SCREEN"
: > "$POSTED"
register_task run_esc task_esc w1 cond1 "$CPANE" "$CBIRTH" "$WPANE" "$WBIRTH" /repo /wt "impl:esc" >/dev/null 2>&1
run_hook run_esc task_esc
run_hook run_esc task_esc
run_hook run_esc task_esc
[ "$(n_posts)" = 1 ] && ok "exactly 1 post despite 3 hook firings ($(n_posts))" \
  || bad "expected 1 post, got $(n_posts): $(cat "$POSTED")"

printf '== 3) allow-class prompt answered before grace elapses -> 0 posts ==\n'
omp_menu_screen "git status --short" > "$WORKER_SCREEN"
clean_screen > "$COND_SCREEN"
: > "$POSTED"
register_task run_cleared task_cleared w1 cond1 "$CPANE" "$CBIRTH" "$WPANE" "$WBIRTH" /repo /wt "impl:cleared" >/dev/null 2>&1
run_hook run_cleared task_cleared HERDR_ALERT_GRACE_S=1
clean_screen > "$WORKER_SCREEN"          # answered in the terminal before the window elapses
sleep 2
[ "$(n_posts)" = 0 ] && ok "answered before grace: 0 posts" || bad "posted despite being answered: $(cat "$POSTED")"

printf '== 4) conductor wake fails repeatedly, unanswered after the wait window -> exactly 1 post ==\n'
omp_menu_screen "wrangler deploy" > "$WORKER_SCREEN"
: > "$POSTED"
register_task run_wf task_wf w1 cond1 "$CPANE" "$CBIRTH" "$WPANE" "$WBIRTH" /repo /wt "impl:wf" >/dev/null 2>&1
set_task_state run_wf task_wf blocked >/dev/null 2>&1
want_pid="$(prompt_id "$WPANE")"
HERDR_WAKE_FAIL_ALERT_S=1 _pw_wake_fail_realert "$WPANE" "$want_pid" run_wf task_wf refused
HERDR_WAKE_FAIL_ALERT_S=1 _pw_wake_fail_realert "$WPANE" "$want_pid" run_wf task_wf unsubmitted   # a second failed attempt, same prompt
sleep 2
[ "$(n_posts)" = 1 ] && ok "exactly 1 post after the wait window despite 2 failed wake attempts" \
  || bad "expected 1 post, got $(n_posts): $(cat "$POSTED")"
grep -qi 'unanswered after' "$POSTED" && ok "post names the wake-failure symptom" || bad "wake-failure wording missing: $(cat "$POSTED")"
q_wf() { sqlite3 "$HERDR_RUN_STATE_DIR/registry.sqlite3" "SELECT count(*) FROM events WHERE type='wake_fail_alerted' AND task_id='task_wf';" 2>/dev/null; }
[ "$(q_wf)" = 1 ] && ok "wake_fail_alerted recorded exactly once (not once per attempt)" || bad "wake_fail_alerted rows: $(q_wf)"

printf '== 4b) task resolved before the wait window elapses -> 0 posts ==\n'
: > "$POSTED"
register_task run_wf2 task_wf2 w1 cond1 "$CPANE" "$CBIRTH" "$WPANE" "$WBIRTH" /repo /wt "impl:wf2" >/dev/null 2>&1
set_task_state run_wf2 task_wf2 blocked >/dev/null 2>&1
pid2="$(prompt_id "$WPANE")"
HERDR_WAKE_FAIL_ALERT_S=2 _pw_wake_fail_realert "$WPANE" "$pid2" run_wf2 task_wf2 refused
set_task_state run_wf2 task_wf2 running >/dev/null 2>&1     # answered elsewhere before the window elapses
sleep 3
[ "$(n_posts)" = 0 ] && ok "resolved before the wait window: 0 posts" || bad "posted for an already-resolved wake failure: $(cat "$POSTED")"

printf '== nothing visible (no menu, no numbered options, no context) -> DROP, no post ==\n'
printf ' \n' > "$WORKER_SCREEN"
: > "$POSTED"
out="$(HERDR_BRIDGE_STATE="$WORK/nb1" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$WPANE" "needs input" 2>&1)"
[ "$(n_posts)" = 0 ] && ok "nothing on screen: dropped, no post" || bad "posted with nothing on screen: $(cat "$POSTED")"
printf '%s' "$out" | grep -qi 'skipping' && ok "explains the skip" || bad "silent skip with no explanation: $out"

printf '== HERDR_SLACK_VERBOSE=1 restores the old always-post behaviour ==\n'
omp_menu_screen "rm -rf /tmp/scratch" > "$WORKER_SCREEN"
: > "$POSTED"
HERDR_SLACK_VERBOSE=1 HERDR_BRIDGE_STATE="$WORK/nbv" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
HERDR_SLACK_VERBOSE=1 HERDR_BRIDGE_STATE="$WORK/nbv" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
HERDR_SLACK_VERBOSE=1 HERDR_BRIDGE_STATE="$WORK/nbv" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
[ "$(n_posts)" = 3 ] && ok "HERDR_SLACK_VERBOSE=1 posts every time again ($(n_posts))" \
  || bad "verbose escape hatch did not restore the old behaviour: $(n_posts) posts"

printf '== a failed Slack send releases its claim so a retry can still land ==\n'
omp_menu_screen "git push origin main" > "$WORKER_SCREEN"
: > "$POSTED"
rc1=0
( curl() { printf '{"ok":false,"error":"rate_limited"}'; }; export -f curl
  HERDR_BRIDGE_STATE="$WORK/nbf" bash "$here/slack-bridge/herdr-notify.sh" \
    --choices --pane "$WPANE" "needs input" >/dev/null 2>&1 ) || rc1=$?
# restore the real (recording) curl stub for the retry
curl() { printf '%s\n' "POST $*" >> "$POSTED" 2>/dev/null; cat >/dev/null; printf '{"ok":true,"ts":"%s.%s"}' "$(date +%s)" "$$$RANDOM"; }
export -f curl
HERDR_BRIDGE_STATE="$WORK/nbf" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
[ "$(n_posts)" = 1 ] && ok "the retry after a failed send still lands (claim was released)" \
  || bad "retry was blocked by a claim from a send that never reached Slack: $(n_posts) posts"

printf '== P1: two panes showing the SAME panel text both post (not silently deduped against each other) ==\n'
OTHER_PANE="w9:p1"
omp_menu_screen "cat ~/.aws/credentials" > "$WORKER_SCREEN"   # herdr() stub: any pane != CPANE reads WORKER_SCREEN; unused elsewhere in this file, so no stale claim from an earlier section
: > "$POSTED"
HERDR_BRIDGE_STATE="$WORK/p1a" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
HERDR_BRIDGE_STATE="$WORK/p1a" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$OTHER_PANE" "needs input" >/dev/null 2>&1
[ "$(n_posts)" = 2 ] && ok "two different panes, identical text: both post ($(n_posts))" \
  || bad "a second pane's identical prompt was silently dropped: $(n_posts) posts"

printf '== P1: a re-ask of the SAME prompt after the dedupe TTL expires posts again ==\n'
omp_menu_screen "op read op://secrets/x/credential" > "$WORKER_SCREEN"   # unused elsewhere in this file
: > "$POSTED"
HERDR_ALERT_DEDUP_TTL_S=1 HERDR_BRIDGE_STATE="$WORK/p1b" bash "$here/slack-bridge/herdr-notify.sh" \
  --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
[ "$(n_posts)" = 1 ] || bad "first ask did not post: $(n_posts) posts"
sleep 2   # outlive the 1s TTL
HERDR_ALERT_DEDUP_TTL_S=1 HERDR_BRIDGE_STATE="$WORK/p1b" bash "$here/slack-bridge/herdr-notify.sh" \
  --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
[ "$(n_posts)" = 2 ] && ok "a re-ask after the TTL expires posts again ($(n_posts))" \
  || bad "a re-ask was silently dropped forever: $(n_posts) posts"

printf '== P2: a plain-context prompt (no numbered options), 3 firings -> exactly 1 post ==\n'
# A genuine plain y/n confirmation: no "Allow tool:"/"Command:" header, no
# Approve/Deny wording, no navigation footer — none of the menu-shape or
# numbered-shape signals prompt_menu_options/prompt_options key on. The
# earlier fixture here ("Continue with this plan?\nApprove\nDeny\n...\nup/down
# navigate...") still parsed as a recognized menu shape (PR #131 review),
# which meant this test exercised the SAME opts-based path as every other
# test in this file rather than the plain-context branch it claimed to.
printf 'Do you want to proceed? (y/n)\n' > "$WORKER_SCREEN"
dry_out="$(HERDR_BRIDGE_STATE="$WORK/p2dry" bash "$here/slack-bridge/herdr-notify.sh" \
  --dry-run --choices --pane "$WPANE" "needs input" 2>&1)"
printf '%s' "$dry_out" | grep -q 'with buttons' \
  && bad "plain y/n screen was rendered as a button menu: $dry_out" \
  || ok "plain y/n screen is not rendered as a button menu (no numbered/menu options)"
: > "$POSTED"
HERDR_BRIDGE_STATE="$WORK/p2" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
HERDR_BRIDGE_STATE="$WORK/p2" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
HERDR_BRIDGE_STATE="$WORK/p2" bash "$here/slack-bridge/herdr-notify.sh" --choices --pane "$WPANE" "needs input" >/dev/null 2>&1
[ "$(n_posts)" = 1 ] && ok "plain-context prompt, 3 firings -> exactly 1 post ($(n_posts))" \
  || bad "plain-context branch is not deduped: $(n_posts) posts"

printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
