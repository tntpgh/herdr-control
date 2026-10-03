#!/usr/bin/env bash
# verify-remote-research-answer-approval.sh — regression coverage for the fix
# (SPEC.md, task_20261002T213729Z_47591_13203): a remote research/explore
# task could not write .handoffs/ANSWER.md because the one supported
# approval path (menu) judges a SCRAPED terminal panel, which a narrow herdr
# pane truncates ("approval arguments are clipped" — the symptom seen on
# task_20261002T191316Z_54877_5893), and the remote-mcp publisher's own
# spawns had no conductor pane to escalate to in the first place.
#
# Three independent fixes, three sections below:
#   A. _ps_plain_write_verdict (lib/pretool-shadow.sh) judges the STRUCTURED
#      input.path a hook-mode write call carries — never a scraped panel —
#      so switching research/explore to --approval hook (remote-mcp/tasks.py)
#      removes the truncation failure mode entirely rather than papering
#      over it.
#   B. herdr-action.sh distinguishes conductor_unconfigured (no pane was
#      ever registered — a remote-mcp spawn with no HERDR_PANE_ID) from
#      conductor_unreachable (a recycled pane) and skips the normal
#      HA_STALE_S wait only for the former, since there is no pane that
#      could ever come back.
#   C. spawn-task.sh's HERDR_MCP_CONDUCTOR_PANE fallback gives such a spawn a
#      real, live-validated conductor pane when the publisher's own
#      environment names a standing one, without ever overriding an
#      interactive HERDR_PANE_ID.
#
#   bash verify-remote-research-answer-approval.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export HERDR_RUN_STATE_DIR="$work/runs" HERDR_STATE_ROOT="$work/state"
export PANE='w1:p1' BIRTH='gen-1' CPANE='w9:p9' CBIRTH='cgen-1'
export HERDR_PANE_ID="$PANE" HERDR_RUN_ID='run1' HERDR_TASK_ID='task_ans'
wt="$work/worktree"; mkdir -p "$wt/.handoffs" "$wt/src" "$HERDR_STATE_ROOT/forms" "$work/bin"
cat > "$work/bin/herdr" <<'EOF'
#!/bin/bash
[ "$1 $2" = "pane list" ] || exit 0
printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"%s"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
  "$PANE" "${FAKE_BIRTH:-$BIRTH}" "$CPANE" "${FAKE_CBIRTH:-$CBIRTH}"
EOF
cat > "$work/bin/send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$work/sent"
exit \${FAKE_SEND_RC:-0}
EOF
cat > "$work/bin/notify" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$work/notified"
EOF
cat > "$work/bin/formserve" <<EOF
#!/bin/bash
id="\$(date -u +%Y%m%dT%H%M%S)-\$RANDOM\$RANDOM"
jq -nc --arg f "\$1" '{form_path:\$f, status:"open"}' > "$HERDR_STATE_ROOT/forms/\$id.json"
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
export HERDR_ACTION_SEND="$work/bin/send" HERDR_ACTION_NOTIFY="$work/bin/notify"
export HERDR_ACTION_FORMSERVE="$work/bin/formserve" HERDR_ACTION_PYTHON=bash
export HERDR_ACTION_NO_SURFACE=1       # surfacing is exercised explicitly in section B

. "$here/lib/run-registry.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
field() { jq -r ".$1"; }
enf() {                                  # tool input-json task_id -> {decision,reason,request_id,verdict}
  HERDR_TASK_ID="${3:-$HERDR_TASK_ID}" \
  jq -nc --arg t "$1" --argjson i "$2" --arg c "$wt" '{tool:$t, input:$i, call_id:("c"+($i|tostring|length|tostring)), cwd:$c}' \
    | HERDR_TASK_ID="${3:-$HERDR_TASK_ID}" bash "$here/lib/pretool-shadow.sh" --enforce --record
}

manifest='{"handoffs_write":"ANSWER.md"}'
register_task run1 task_ans worker1 cond1 "$CPANE" "$CBIRTH" "$PANE" "$BIRTH" /repo "$wt" impl:task_ans feat/x main "" "$manifest" hook >/dev/null
set_task_state run1 task_ans running

printf '== A: _ps_plain_write_verdict judges the structured input.path, not a scraped panel ==\n'
rm -f "$wt/.handoffs/ANSWER.md"
out="$(enf write '{"path":".handoffs/ANSWER.md","content":"the answer"}')"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] \
  && ok "exact .handoffs/ANSWER.md write (no prior file): allowed with no human in the loop" \
  || not_ok "expected allow rc=0, got rc=$rc: $out"

printf 'already here\n' > "$wt/.handoffs/ANSWER.md"
out="$(enf write '{"path":".handoffs/ANSWER.md","content":"a second answer"}')"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] \
  && ok "a second write to an existing REGULAR ANSWER.md still allows" \
  || not_ok "expected allow rc=0, got rc=$rc: $out"

out="$(enf write "$(jq -nc --arg p "$wt/.handoffs/ANSWER.md" '{path:$p, content:"abs path form"}')")"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] \
  && ok "the absolute-path form of the same file also allows" \
  || not_ok "expected allow rc=0, got rc=$rc: $out"

out="$(enf write '{"path":".handoffs/OTHER.md","content":"not the deliverable"}')"; rc=$?
rid="$(printf '%s' "$out" | field request_id)"
[ "$rc" = 8 ] && [ -n "$rid" ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "a write to a DIFFERENT .handoffs file escalates to the conductor: $rid" \
  || not_ok "expected escalate (block+request), got rc=$rc: $out"
[ "$(_sql "SELECT route||'/'||status FROM action_requests WHERE request_id=$(_sq "$rid");")" = conductor/pending ] \
  && ok "the escalation left a real pending/conductor action_requests row" \
  || not_ok "request row: $(_sql "SELECT * FROM action_requests WHERE request_id=$(_sq "$rid");")"

rm -f "$wt/.handoffs/ANSWER.md"; ln -s ../src/x "$wt/.handoffs/ANSWER.md"
out="$(enf write '{"path":".handoffs/ANSWER.md","content":"escape via symlink"}')"; rc=$?
[ "$rc" = 8 ] && [ -n "$(printf '%s' "$out" | field request_id)" ] && printf '%s' "$out" | field reason | grep -q 'symlink to somewhere else' \
  && ok "ANSWER.md replaced with a symlink escaping to src/: escalates, never writes through" \
  || not_ok "expected escalate (symlink), got rc=$rc: $out"

rm -f "$wt/.handoffs/ANSWER.md"; ln -s ../src/does-not-exist-yet "$wt/.handoffs/ANSWER.md"
out="$(enf write '{"path":".handoffs/ANSWER.md","content":"escape via broken symlink"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'symlink to somewhere else' \
  && ok "a broken symlink at the same path also escalates" \
  || not_ok "expected escalate (broken symlink), got rc=$rc: $out"
rm -f "$wt/.handoffs/ANSWER.md"

out="$(enf write '{"path":"../outside-the-worktree.txt","content":"traversal"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "a .. path traversing out of the worktree escalates (lexical abspath lands outside wt, never matches)" \
  || not_ok "expected escalate (..), got rc=$rc: $out"

out="$(enf write '{"path":"/etc/passwd","content":"elsewhere"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "an absolute path elsewhere on disk escalates" \
  || not_ok "expected escalate (absolute elsewhere), got rc=$rc: $out"

out="$(enf write '{"path":"~/not-the-worktree","content":"tilde"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "a ~-relative path escalates" \
  || not_ok "expected escalate (tilde), got rc=$rc: $out"

out="$(enf write '{"content":"no path field at all"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'no usable structured path' \
  && ok "a write call with NO structured path escalates (never falls through to the broad containment-159 allow)" \
  || not_ok "expected escalate (no path), got rc=$rc: $out"

out="$(enf write '{"path":"","content":"empty path"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'no usable structured path' \
  && ok "a write call with an EMPTY structured path escalates" \
  || not_ok "expected escalate (empty path), got rc=$rc: $out"

register_task run1 task_nomanifest worker1 cond1 "$CPANE" "$CBIRTH" "$PANE" "$BIRTH" /repo "$wt" impl:task_nomanifest feat/y main "" "" hook >/dev/null
set_task_state run1 task_nomanifest running
out="$(enf write '{"path":"src/other.txt","content":"unrestricted"}' task_nomanifest)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] \
  && ok "no handoffs_write manifest: an ordinary worktree write still allows (containment-159, unaffected by this fix)" \
  || not_ok "expected allow rc=0, got rc=$rc: $out"

printf '== B: herdr-action.sh distinguishes conductor_unconfigured from conductor_unreachable ==\n'
export HERDR_ACTION_STALE_S=999999      # proves the unconfigured path bypasses the wait, not that it merely expired fast
register_task run1 task_unconf worker1 cond_x "" "" "$PANE" "$BIRTH" /repo "$wt" impl:task_unconf feat/u1 main "" "$manifest" hook >/dev/null
set_task_state run1 task_unconf running
register_task run1 task_unreach worker1 cond_x "$CPANE" other "$PANE" "$BIRTH" /repo "$wt" impl:task_unreach feat/u2 main "" "$manifest" hook >/dev/null
set_task_state run1 task_unreach running

out="$(enf write '{"path":".handoffs/OTHER.md","content":"x"}' task_unconf)"
rid_unconf="$(printf '%s' "$out" | field request_id)"
out="$(enf write '{"path":".handoffs/OTHER.md","content":"x"}' task_unreach)"
rid_unreach="$(printf '%s' "$out" | field request_id)"
[ -n "$rid_unconf" ] && [ -n "$rid_unreach" ] && ok "setup: both tasks have a pending conductor-routed request" \
  || not_ok "setup failed: unconf=$rid_unconf unreach=$rid_unreach"

bash "$here/herdr-action.sh" tick
[ "$(_sql "SELECT json_extract(payload,'\$.outcome') FROM events WHERE type='action_surfaced' AND json_extract(payload,'\$.request_id')=$(_sq "$rid_unconf") ORDER BY sequence DESC LIMIT 1;")" = conductor_unconfigured ] \
  && ok "task with no conductor pane ever registered: outcome=conductor_unconfigured" \
  || not_ok "unconf outcome: $(_sql "SELECT payload FROM events WHERE type='action_surfaced' AND json_extract(payload,'\$.request_id')=$(_sq "$rid_unconf");")"
[ "$(_sql "SELECT json_extract(payload,'\$.outcome') FROM events WHERE type='action_surfaced' AND json_extract(payload,'\$.request_id')=$(_sq "$rid_unreach") ORDER BY sequence DESC LIMIT 1;")" = conductor_unreachable ] \
  && ok "task with a recycled conductor pane: outcome=conductor_unreachable (unchanged, not folded into the new case)" \
  || not_ok "unreach outcome: $(_sql "SELECT payload FROM events WHERE type='action_surfaced' AND json_extract(payload,'\$.request_id')=$(_sq "$rid_unreach");")"

[ "$(_sql "SELECT count(*) FROM events WHERE task_id='task_unconf' AND type='action_form_served';")" = 1 ] \
  && ok "conductor_unconfigured: a hub decision form was served on this SAME tick (age ~0s, HA_STALE_S=999999 — the bypass, not a fast expiry)" \
  || not_ok "no action_form_served for task_unconf after one tick"
grep -q 'needs YOUR OK' "$work/notified" 2>/dev/null \
  && ok "conductor_unconfigured: the blocker reached the human notify channel on the same tick" \
  || not_ok "no human notify for task_unconf: $(cat "$work/notified" 2>/dev/null)"
[ "$(_sql "SELECT count(*) FROM events WHERE task_id='task_unreach' AND type='action_form_served';")" = 0 ] \
  && ok "conductor_unreachable: still waiting out HA_STALE_S (unchanged pinned behaviour) — no form served yet" \
  || not_ok "task_unreach got a form served despite HA_STALE_S=999999 and age~0s (regression: bypass leaked to the recycled-pane case)"
unset HERDR_ACTION_STALE_S

printf '== C: spawn-task.sh HERDR_MCP_CONDUCTOR_PANE — a validated fallback, never overriding a real pane ==\n'
repo="$work/repo"; git init -q "$repo" && git -C "$repo" commit -q --allow-empty -m init
AGENT_PANE='w5:p5'
cat > "$work/bin/herdr" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "pane list")
    printf '{"result":{"panes":[{"pane_id":"%s","terminal_id":"gen-agent"},{"pane_id":"%s","terminal_id":"%s"}]}}\n' \
      "$AGENT_PANE" "\$PANE" "\${FAKE_BIRTH:-\$BIRTH}" ;;
  "pane process-info")
    [ "\$4" = "$AGENT_PANE" ] && echo '{"result":{"process_info":{"foreground_processes":[{"name":"bun","cmdline":"bun run omp index.ts"}]}}}' || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/herdr"
# config.sh puts HERDR_EXTRA_PATH ahead of PATH, so an ambient real herdr
# install would otherwise shadow this stub inside spawn-task.sh itself.
dryc() { env -u HERDR_TASK_ID -u HERDR_RUN_ID -u HERDR_PANE_ID HERDR_EXTRA_PATH="$work/bin" "$@" bash "$here/spawn-task.sh" --dry-run --no-secrets "$repo" fix/mcp-fallback implement omp 2>&1; }

out="$(HERDR_MCP_CONDUCTOR_PANE="$AGENT_PANE" dryc)"
printf '%s' "$out" | grep -q "conductor_pane=$AGENT_PANE " \
  && ok "no HERDR_PANE_ID, a live agent pane named by HERDR_MCP_CONDUCTOR_PANE: adopted as the fallback conductor" \
  || not_ok "fallback not adopted: $(printf '%s' "$out" | grep registry)"

out="$(HERDR_MCP_CONDUCTOR_PANE='w6:p6' dryc)"    # not in the fake herdr's pane list at all
printf '%s' "$out" | grep -q 'conductor_pane=<none' \
  && ok "HERDR_MCP_CONDUCTOR_PANE naming a dead/unknown pane: left empty exactly as before, task still starts" \
  || not_ok "dead pane was adopted anyway: $(printf '%s' "$out" | grep registry)"

out="$(env -u HERDR_TASK_ID -u HERDR_RUN_ID HERDR_PANE_ID="$PANE" HERDR_MCP_CONDUCTOR_PANE="$AGENT_PANE" HERDR_EXTRA_PATH="$work/bin" bash "$here/spawn-task.sh" --dry-run --no-secrets "$repo" fix/mcp-fallback2 implement omp 2>&1)"
printf '%s' "$out" | grep -q "conductor_pane=$PANE " \
  && ok "an interactive HERDR_PANE_ID is never overridden by HERDR_MCP_CONDUCTOR_PANE" \
  || not_ok "interactive pane was overridden: $(printf '%s' "$out" | grep registry)"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
