#!/usr/bin/env bash
# verify-approval-friction.sh — proves the fix in
# lib/prompt-parse.sh (prompt_id_settled) / lib/push-wake.sh for
# .handoffs/SPEC.md "approval friction fix" (2026-10-16).
#
# Both measured defects (~/.config/herdr-bridge/selections.jsonl, 2026-10-16:
# 40 "overflowed one panel line" + 10 "parallel calls/no hook record"
# administrative cancels in one day) share ONE root cause: lib/push-wake.sh
# used to capture `prompt_id` with a SINGLE screen read at the instant its
# hook fired. When that instant lands before omp has repainted past a prior
# queued call's panel (defect a: two bash tool calls in one turn), or while a
# command long enough to overflow one panel line is still wrapping/settling
# on screen (defect b), that single read fingerprints the WRONG or EMPTY
# prompt. The input_required row then gets written keyed to that wrong/empty
# id, and herdr-select.sh's later lookup against the REAL, settled prompt_id
# (lib/run-registry.sh task_input_required_tool) never finds it — refused as
# "hook recorded <none>" (herdr-select.sh:811-813).
#
# This suite calls push_wake directly against a MUTATING screen fixture (a
# counter-driven herdr stub: the first N reads return the stale/unreadable
# panel, later reads return the real, settled one) -- the exact shape the
# live canary and the conductor's live repro both showed -- and proves:
#   1. parallel queued calls: push_wake settles onto the LATER (real) panel
#      instead of permanently mis-recording the earlier one
#   2. overflow: an unreadable-then-parseable panel settles the same way
#   3. a PERSISTENT mismatch (never settles) still degrades exactly as
#      before -- fail-closed is never weakened, only the race is closed
#   4. HERDR_EXPECT_PROMPT_ID / stale-task refusal paths stay INSTANT (no
#      waiting) -- the settle retry sits strictly after them
#   5. an oversized full_cmd does not hang or crash the settle loop
#   6. HERDR_PROMPT_SETTLE_WAIT_S=0 reproduces today's exact single-shot
#      behavior (used by every OTHER suite's fixtures, which are static)
#
#   bash verify-approval-friction.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_RUN_STATE_DIR="$WORK/runs"
WPANE="w1:p1"; WBIRTH="wterm-1"
export WPANE WBIRTH

. "$here/lib/pane-guard.sh"
. "$here/lib/prompt-parse.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/push-wake.sh"

# omp's approval menu: header, blank, highlighted row, blank, footer.
omp_menu_screen() {
  printf ' Allow tool: bash\n'
  printf '   run: %s\n' "$1"
  printf '\n'
  printf '\033[48;2;40;40;40m  Approve\033[0m\n'
  printf '   Deny\n'
  printf '\n'
  printf ' up/down navigate  enter select  esc cancel\n'
}
# A command long enough to overflow one panel line: terminal is still
# painting/wrapping the "run:" row when the hook fires, so the strict
# parser sees a TRUNCATED command row inside an otherwise well-formed,
# recognizable omp menu (not pure garbage) -- the real defect(b) shape,
# not "no menu at all".
torn_menu_screen() {
  printf ' Allow tool: bash\n'
  printf '   run: %s\n' "${1:0:20}"
  printf '\n'
  printf '\033[48;2;40;40;40m  Approve\033[0m\n'
  printf '   Deny\n'
  printf '\n'
  printf ' up/down navigate  enter select  esc cancel\n'
}

SETTLE_AT_NS=0   # 0 == always settled; set by arm_settle()
NEVER_SETTLE=0   # 1 == always stale, regardless of SETTLE_AT_NS
STALE_SCREEN_FILE="$WORK/stale.txt"
SETTLED_SCREEN_FILE="$WORK/settled.txt"
# Exported (not just set): section 8 drives the real agent-hooks/omp-notify.sh
# as a SEPARATE `bash` process. A plain (non-exported) shell variable never
# reaches that process's environment, so its own `herdr()` -- inherited fine
# via `export -f` -- would reference an unbound $NEVER_SETTLE/$SETTLE_AT_NS
# under omp-notify.sh's `set -uo pipefail` and crash instantly (observed:
# "line 3: NEVER_SETTLE: unbound variable", silently swallowed by
# _prompt_is_up's own 2>/dev/null, with no further trace -- sections 1-7
# never hit this because they call push_wake directly in THIS shell).
export SETTLE_AT_NS NEVER_SETTLE STALE_SCREEN_FILE SETTLED_SCREEN_FILE
# arm_settle <delay_s>: from THIS instant, `herdr pane read` returns the
# STALE/torn screen for <delay_s> seconds (a real terminal repaint race is a
# TIMING race, not a fixed number of reads — a single logical "capture"
# routinely costs 2-3 herdr calls of its own, so counting reads conflated a
# capture's OWN internal reads with the retry this fix adds). After the
# delay, every read returns the settled screen.
arm_settle() {
  local delay_s="${1:-0}"
  NEVER_SETTLE=0
  SETTLE_AT_NS=$(( $(date +%s%N) + $(awk -v d="$delay_s" 'BEGIN{printf "%d", d*1000000000}') ))
}
herdr() {
  local sub="$1 $2"
  case "$sub" in
    "pane read")
      if [ "$NEVER_SETTLE" = 1 ] || [ "$(date +%s%N)" -lt "$SETTLE_AT_NS" ]; then
        cat "$STALE_SCREEN_FILE"
      else
        cat "$SETTLED_SCREEN_FILE"
      fi
      ;;
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    *) return 0 ;;
  esac
}
export -f herdr

register_task run1 task1 w1 cond1 "" "" "$WPANE" "$WBIRTH" /repo /wt "impl:friction" >/dev/null 2>&1
set_task_state run1 task1 running >/dev/null 2>&1
export HERDR_RUN_ID=run1 HERDR_TASK_ID=task1 HERDR_PANE_ID="$WPANE" \
  HERDR_CONDUCTOR_PANE_ID=cond1 HERDR_TASK_LABEL="impl:friction"

q_payload() { _sql "SELECT payload FROM events WHERE run_id='run1' AND task_id='task1' AND type='$1' ORDER BY sequence DESC LIMIT 1;"; }
clear_events() { _sql "DELETE FROM events WHERE run_id='run1' AND task_id='task1';" >/dev/null 2>&1; set_task_state run1 task1 running >/dev/null 2>&1; }

printf '== 1. parallel queued calls: settles onto the LATER (real) panel, not the still-painted prior one ==\n'
# tool call A's panel is still painted when this hook (for tool call B)
# fires; B's panel paints once omp catches up, ~0.3s later.
omp_menu_screen "git log --oneline -3" > "$STALE_SCREEN_FILE"     # call A, still on screen
omp_menu_screen "git fetch --all --prune" > "$SETTLED_SCREEN_FILE" # call B, the real one
arm_settle 0.3; clear_events
( export HERDR_PROMPT_SETTLE_WAIT_S=2
  push_wake "impl:friction needs input" "hook" "git fetch --all --prune" bash >/dev/null 2>&1 )
payload="$(q_payload input_required)"
printf '%s' "$payload" | jq -e '.command == "git fetch --all --prune"' >/dev/null 2>&1 \
  && ok "settled onto call B's real command, not call A's still-painted one" \
  || bad "did not settle: $payload"
printf '%s' "$payload" | jq -e '.command_uncorroborated == true' >/dev/null 2>&1 \
  && bad "flagged uncorroborated despite settling" \
  || ok "no uncorroborated flag once settled"
printf '%s' "$payload" | jq -r '.prompt_id' | grep -qE '^[0-9a-f]{64}$' \
  && ok "a real, well-formed prompt_id was recorded" \
  || bad "prompt_id missing/malformed: $(printf '%s' "$payload" | jq -r '.prompt_id')"

printf '== 2. overflow: a torn command row (still wrapping) settles once painting finishes ==\n'
torn_menu_screen "wrangler deploy --env prod --minify --keep-vars --compatibility-date=2026-10-16" > "$STALE_SCREEN_FILE"
omp_menu_screen "wrangler deploy --env prod --minify --keep-vars --compatibility-date=2026-10-16" > "$SETTLED_SCREEN_FILE"
# 2a. wait=0 (today's single-shot capture, matching base behavior): the
# hook fires while the row is still torn -- reproduces the base defect,
# dropped/uncorroborated command, exactly "hook recorded <none>".
arm_settle 5; clear_events
( export HERDR_PROMPT_SETTLE_WAIT_S=0
  push_wake "impl:friction needs input" "hook" "wrangler deploy --env prod --minify --keep-vars --compatibility-date=2026-10-16" bash >/dev/null 2>&1 )
payload="$(q_payload input_required)"
printf '%s' "$payload" | jq -e '.command_uncorroborated == true' >/dev/null 2>&1 \
  && ok "wait=0 (base-equivalent single read) reproduces the defect: torn row never corroborates" \
  || bad "base-equivalent single read unexpectedly corroborated: $payload"
# 2b. with the settle budget: the SAME torn-then-settled sequence succeeds.
arm_settle 0.3; clear_events
( export HERDR_PROMPT_SETTLE_WAIT_S=2
  push_wake "impl:friction needs input" "hook" "wrangler deploy --env prod --minify --keep-vars --compatibility-date=2026-10-16" bash >/dev/null 2>&1 )
payload="$(q_payload input_required)"
printf '%s' "$payload" | jq -e '.command == "wrangler deploy --env prod --minify --keep-vars --compatibility-date=2026-10-16"' >/dev/null 2>&1 \
  && ok "settled onto the parseable panel once the overflow/wrap finished" \
  || bad "did not settle past the torn frame: $payload"
printf '%s' "$payload" | jq -r '.prompt_id' | grep -qE '^[0-9a-f]{64}$' \
  && ok "a real (non-empty) prompt_id was recorded, not the torn frame's" \
  || bad "prompt_id missing/malformed: $(printf '%s' "$payload" | jq -r '.prompt_id')"

printf '== 3. a PERSISTENT mismatch never settles -- fail-closed is unchanged, only the race is closed ==\n'
omp_menu_screen "git status --short" > "$STALE_SCREEN_FILE"
cp "$STALE_SCREEN_FILE" "$SETTLED_SCREEN_FILE"   # never changes: genuinely a different, permanent command
NEVER_SETTLE=1; clear_events
before=$(date +%s%N)
( export HERDR_PROMPT_SETTLE_WAIT_S=1
  push_wake "impl:friction needs input" "hook" "rm -rf /tmp/nowhere-near-the-panel" bash >/dev/null 2>&1 )
after=$(date +%s%N)
elapsed_ms=$(( (after - before) / 1000000 ))
payload="$(q_payload input_required)"
printf '%s' "$payload" | jq -e '.command == ""' >/dev/null 2>&1 \
  && ok "the permanently-mismatched command is still dropped, never trusted" \
  || bad "mismatched command leaked through: $payload"
printf '%s' "$payload" | jq -e '.command_uncorroborated == true' >/dev/null 2>&1 \
  && ok "still flagged command_uncorroborated after the budget ran out" \
  || bad "no command_uncorroborated flag: $payload"
[ "$elapsed_ms" -ge 900 ] \
  && ok "spent roughly the full settle budget retrying before giving up (${elapsed_ms}ms)" \
  || bad "gave up too fast for a budget=1s case: ${elapsed_ms}ms"

printf '== 4. HERDR_EXPECT_PROMPT_ID / stale-task refusal paths stay INSTANT -- settle never runs for them ==\n'
omp_menu_screen "git status --short" > "$STALE_SCREEN_FILE"
cp "$STALE_SCREEN_FILE" "$SETTLED_SCREEN_FILE"
arm_settle 0; clear_events
before=$(date +%s%N)
( export HERDR_PROMPT_SETTLE_WAIT_S=3 HERDR_EXPECT_PROMPT_ID=not-the-real-id
  push_wake "impl:friction needs input" "hook" "" bash >/dev/null 2>&1 )
rc=$?
after=$(date +%s%N)
elapsed_ms=$(( (after - before) / 1000000 ))
[ "$rc" = 1 ] && ok "a stale HERDR_EXPECT_PROMPT_ID still returns 1 (nothing written)" \
  || bad "unexpected rc=$rc"
[ "$elapsed_ms" -lt 500 ] \
  && ok "refused in ${elapsed_ms}ms -- the 3s settle budget never ran for this gate" \
  || bad "took ${elapsed_ms}ms -- settle retry leaked into the EXPECT_PROMPT_ID gate"
set_task_state run1 task1 completed >/dev/null 2>&1
before=$(date +%s%N)
( export HERDR_PROMPT_SETTLE_WAIT_S=3
  push_wake "impl:friction needs input" "hook" "" bash >/dev/null 2>&1 )
rc=$?
after=$(date +%s%N)
elapsed_ms=$(( (after - before) / 1000000 ))
[ "$rc" = 1 ] && ok "a terminal task still refuses (nothing written)" || bad "unexpected rc=$rc"
[ "$elapsed_ms" -lt 500 ] \
  && ok "refused in ${elapsed_ms}ms -- a dead task's hook never waits on a settling screen" \
  || bad "took ${elapsed_ms}ms -- settle retry leaked into the stale/terminal check"
set_task_state run1 task1 running >/dev/null 2>&1

printf '== 5. an oversized full_cmd does not hang or crash the settle loop ==\n'
BIG_CMD="$(head -c 50000 /dev/zero | tr '\0' 'x')"
omp_menu_screen "git status --short" > "$STALE_SCREEN_FILE"
cp "$STALE_SCREEN_FILE" "$SETTLED_SCREEN_FILE"
arm_settle 0; clear_events
before=$(date +%s%N)
( export HERDR_PROMPT_SETTLE_WAIT_S=1
  push_wake "impl:friction needs input" "hook" "$BIG_CMD" bash >/dev/null 2>&1 )
rc=$?
after=$(date +%s%N)
elapsed_ms=$(( (after - before) / 1000000 ))
[ "$rc" = 0 ] || [ "$rc" = 1 ] \
  && ok "oversized (50KB) full_cmd returns cleanly, rc=$rc, in ${elapsed_ms}ms" \
  || bad "oversized full_cmd misbehaved: rc=$rc ${elapsed_ms}ms"
payload="$(q_payload input_required)"
printf '%s' "$payload" | jq -e '.command_uncorroborated == true' >/dev/null 2>&1 \
  && ok "oversized mismatched command still degrades, never crashes into a trusted write" \
  || bad "oversized full_cmd payload unexpected: $(printf '%s' "$payload" | jq -c '.command | length')"

printf '== 6. HERDR_PROMPT_SETTLE_WAIT_S=0 reproduces single-shot behavior (every other suite pins this) ==\n'
omp_menu_screen "git log --oneline -3" > "$STALE_SCREEN_FILE"
omp_menu_screen "git fetch --all --prune" > "$SETTLED_SCREEN_FILE"
arm_settle 5; clear_events
( export HERDR_PROMPT_SETTLE_WAIT_S=0
  push_wake "impl:friction needs input" "hook" "git fetch --all --prune" bash >/dev/null 2>&1 )
payload="$(q_payload input_required)"
printf '%s' "$payload" | jq -e '.command_uncorroborated == true' >/dev/null 2>&1 \
  && ok "wait=0: a still-stale first read degrades immediately, no retry spent (matches pre-fix suites)" \
  || bad "wait=0 unexpectedly settled: $payload"

printf '== 7. HERDR_PROMPT_SETTLE_TRACE proves retries actually happened, not just elapsed time ==\n'
omp_menu_screen "git log --oneline -3" > "$STALE_SCREEN_FILE"
omp_menu_screen "git fetch --all --prune" > "$SETTLED_SCREEN_FILE"
arm_settle 0.3; clear_events
TRACE="$WORK/trace.log"; : > "$TRACE"
( export HERDR_PROMPT_SETTLE_WAIT_S=2 HERDR_PROMPT_SETTLE_TRACE="$TRACE"
  push_wake "impl:friction needs input" "hook" "git fetch --all --prune" bash >/dev/null 2>&1 )
grep -c '^poll ' "$TRACE" | grep -qE '^[2-9]|^[1-9][0-9]+$' \
  && ok "at least 2 polls were recorded before settling ($(grep -c '^poll ' "$TRACE") polls)" \
  || bad "trace shows too few polls: $(cat "$TRACE")"
grep -q '^settled$' "$TRACE" && ok "trace ends with 'settled'" || bad "trace missing 'settled': $(cat "$TRACE")"

printf '== 8. REVIEW finding 1 (HIGH): the real omp-notify.sh chain stays bound after a settle that advances the identity ==\n'
# agent-hooks/omp-notify.sh binds _bound_pid BEFORE calling push_wake
# (:384), then re-checks it in _still_bound() (:391-402) to gate the
# outbound Slack alert (:524ish). In the exact race this fix targets,
# push_wake's prompt_id_settled can settle onto a DIFFERENT, LATER prompt
# than the one _bound_pid named before the call (the screen genuinely
# repainted mid-call, including the case where push_wake's own quick gate
# already sees the settled screen and refuses the write outright) --
# without the caller refreshing _bound_pid afterward from
# PROMPT_SETTLE_PID, _still_bound's post-call re-read (now correctly
# showing the settled prompt) no longer matches the STALE _bound_pid,
# silently skipping the Slack alert. Drives the REAL
# agent-hooks/omp-notify.sh script end to end (stubbed herdr), not
# push_wake directly -- sections 1-7 already prove push_wake's own settle
# mechanism; this section's unique job is the CALLER-side refresh.
NOTIFIED8="$WORK/notified8.log"; : > "$NOTIFIED8"
cat > "$WORK/notify8.sh" <<EOS
#!/usr/bin/env bash
printf 'notified %s\n' "\$*" >> "$NOTIFIED8"
exit 0
EOS
chmod +x "$WORK/notify8.sh"
omp_menu_screen "git log --oneline -3" > "$STALE_SCREEN_FILE"      # the call this hook's fire first sees
omp_menu_screen "git fetch --all --prune" > "$SETTLED_SCREEN_FILE" # the real, later panel it settles onto
# A wall-clock arm_settle is unreliable here: the real omp-notify.sh chain
# costs several of its OWN `herdr pane read` calls (found-loop, _bound_pid's
# capture, the pre-push _still_bound check) before push_wake's own quick
# gate even runs. A fixed per-process READ COUNT instead makes the first 4
# reads (everything up through push_wake's own quick gate) land stale --
# matching the _bound_pid captured from those same early reads -- and every
# read after that land on the real, later panel, so the SLACK GATE's
# post-push_wake re-read (lib/attention-key.sh _still_bound, called fresh
# from agent-hooks/omp-notify.sh:535) is the first one to see the identity
# has moved: exactly the drift finding 1 is about.
PANE_READ_COUNT_FILE="$WORK/pane_read_count"; printf '0' > "$PANE_READ_COUNT_FILE"
export PANE_READ_COUNT_FILE
herdr() {
  local sub="$1 $2"
  case "$sub" in
    "pane read")
      local n
      n=$(( $(cat "$PANE_READ_COUNT_FILE" 2>/dev/null || printf 0) + 1 ))
      printf '%s' "$n" > "$PANE_READ_COUNT_FILE"
      if [ "$n" -le 4 ]; then cat "$STALE_SCREEN_FILE"; else cat "$SETTLED_SCREEN_FILE"; fi
      ;;
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    *) return 0 ;;
  esac
}
export -f herdr
clear_events
printf '{"tool":"bash","message":"needs review","cwd":"/tmp","command":"git fetch --all --prune"}' \
  | ( export HERDR_PROMPT_SETTLE_WAIT_S=2 HERDR_NOTIFY="$WORK/notify8.sh"
      bash "$here/agent-hooks/omp-notify.sh" ) >/dev/null 2>&1
[ -s "$NOTIFIED8" ] \
  && ok "Slack alert fired despite the identity advancing mid-call (finding 1: _bound_pid was refreshed)" \
  || bad "Slack alert silently skipped — _bound_pid was NOT refreshed after push_wake's identity advanced (finding 1 regressed)"

printf '== 9. fix/offline-launch-profile (2026-10-17): EXPECT_PROMPT_ID + full_cmd settles instead of refusing on a still-painting SAME prompt ==\n'
# herdr-select.sh "the hook recorded '<none>' for this prompt" (observed
# 2026-10-17, review workers w7Y:p7/p8 in ~/Code/tourguide, both long
# multi-line python3 -c/node -e bash commands, both --no-secrets spawns):
# agent-hooks/omp-notify.sh's _still_bound() already confirmed the SAME
# prompt on ITS OWN read and passed HERDR_EXPECT_PROMPT_ID in as that exact
# identity, but push_wake's own quick read a few lines later can still land
# on the terminal mid-repaint for a long/tall panel -- before this fix that
# single disagreeing read refused instantly (rc=1, nothing written at all,
# not even an uncorroborated row), discarding a real hook record for a
# prompt that was never actually different, only not finished painting yet.
# Restore the original arm_settle-driven herdr() stub (section 8 above
# replaced it with its own read-counting one).
herdr() {
  local sub="$1 $2"
  case "$sub" in
    "pane read")
      if [ "$NEVER_SETTLE" = 1 ] || [ "$(date +%s%N)" -lt "$SETTLE_AT_NS" ]; then
        cat "$STALE_SCREEN_FILE"
      else
        cat "$SETTLED_SCREEN_FILE"
      fi
      ;;
    "pane process-info")
      printf '{"result":{"process_info":{"foreground_processes":[{"name":"omp","cmdline":"omp --model sonnet"}]}}}\n' ;;
    *) return 0 ;;
  esac
}
export -f herdr
LONGCMD='python3 -c "import sys; print(sys.version)"'
omp_menu_screen "git log --oneline -3" > "$STALE_SCREEN_FILE"
omp_menu_screen "$LONGCMD" > "$SETTLED_SCREEN_FILE"
# The caller's own bound pid (agent-hooks/omp-notify.sh's _bound_pid) is the
# REAL prompt's identity, read once against the settled screen -- exactly
# like a caller whose own earlier read already saw the fully-painted panel.
arm_settle 0; clear_events
EXPECT_PID="$(prompt_id "$WPANE")"
arm_settle 0.3
before=$(date +%s%N)
( export HERDR_PROMPT_SETTLE_WAIT_S=2 HERDR_EXPECT_PROMPT_ID="$EXPECT_PID"
  push_wake "impl:friction needs input" "hook" "$LONGCMD" bash >/dev/null 2>&1 )
rc=$?
after=$(date +%s%N)
elapsed_ms=$(( (after - before) / 1000000 ))
payload="$(q_payload input_required)"
printf '%s' "$payload" | jq -e --arg c "$LONGCMD" '.command == $c and (.command_uncorroborated // false) == false and .tool == "bash"' >/dev/null 2>&1 \
  && ok "the hook recorded the real tool/command for this prompt -- herdr-select.sh will not see '<none>'" \
  || bad "no corroborated record landed: $payload"
[ "$elapsed_ms" -ge 250 ] \
  && ok "took ${elapsed_ms}ms -- genuinely retried past the first disagreeing read, not an accidental instant match" \
  || bad "resolved in ${elapsed_ms}ms -- suspiciously instant for a read that started disagreeing with EXPECT_PROMPT_ID"
printf '== 10. regression guard: EXPECT_PROMPT_ID with NO full_cmd still refuses instantly even when the screen would settle ==\n'
# Same settling fixture as section 9, but full_cmd="" (a non-bash approval,
# or an older caller) -- nothing to corroborate against, so this must still
# take the ORIGINAL instant-refuse path (section 4's guarantee), never pay
# the settle budget just because a screen happens to be mid-repaint.
arm_settle 0; clear_events
EXPECT_PID2="$(prompt_id "$WPANE")"
arm_settle 0.3
before=$(date +%s%N)
( export HERDR_PROMPT_SETTLE_WAIT_S=2 HERDR_EXPECT_PROMPT_ID="$EXPECT_PID2"
  push_wake "impl:friction needs input" "hook" "" bash >/dev/null 2>&1 )
rc=$?
after=$(date +%s%N)
elapsed_ms=$(( (after - before) / 1000000 ))
[ "$rc" = 1 ] && ok "no full_cmd: still refuses (rc=1) rather than guessing" \
  || bad "unexpected rc=$rc with no full_cmd to corroborate against"
[ "$elapsed_ms" -lt 500 ] \
  && ok "refused in ${elapsed_ms}ms -- no full_cmd never pays the settle budget" \
  || bad "took ${elapsed_ms}ms -- a full_cmd-less call is now waiting on the settle budget (regression)"
printf -- '-----\npassed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then echo PASS; exit 0; else echo FAIL; exit 1; fi
