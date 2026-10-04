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

printf -- '-- security review PR #220 --\n'
out="$(enf write "$(jq -nc --arg p "file://$wt/.handoffs/ANSWER.md" '{path:$p, content:"via file://"}')")"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] \
  && ok "F1 control: file:// spelling of the exact ANSWER.md still allows" \
  || not_ok "expected allow rc=0, got rc=$rc: $out"

out="$(enf write "$(jq -nc --arg p "file://$wt/.handoffs/OTHER.md" '{path:$p, content:"via file://"}')")"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "F1: a file:// write to a DIFFERENT .handoffs file escalates exactly like the plain-path form (not a blanket containment-159 allow)" \
  || not_ok "expected escalate (file:// bypass), got rc=$rc: $out"

out="$(enf write "$(jq -nc --arg p "FILE://$wt/src/evil.py" '{path:$p, content:"upper-case scheme"}')")"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "F1: an upper-case FILE:// scheme is lowered the same way and still escalates" \
  || not_ok "expected escalate (FILE:// bypass), got rc=$rc: $out"

out="$(enf write '{"path":"xd://retain","content":"{\"content\":\"x\"}"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "F2: a write-restricted task's write xd://retain escalates (no xd:// device is the one allowed file)" \
  || not_ok "expected escalate (xd:// bypass), got rc=$rc: $out"

out="$(enf retain '{"content":"x"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "R2: the bare 'retain' tool name (not routed through write xd://) also escalates under handoffs_write" \
  || not_ok "expected escalate (bare retain), got rc=$rc: $out"

out="$(enf xd_retain '{"content":"x"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "R2: the bare 'xd_retain' tool name also escalates under handoffs_write" \
  || not_ok "expected escalate (xd_retain), got rc=$rc: $out"

out="$(enf write '{"path":"local://note.md","content":"x"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "R2: write local://note.md escalates under handoffs_write (not the one allowed file either)" \
  || not_ok "expected escalate (local://), got rc=$rc: $out"

out="$(enf write '{"path":".handoffs/ANSWER.md\n","content":"x"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'contains a control byte' \
  && ok "F4: a trailing newline in the structured path escalates (a later \$(...) strip would silently hide it from the judge; R4 broadened this to the full control-byte range)" \
  || not_ok "expected escalate (newline), got rc=$rc: $out"

out="$(enf write '{"path":".handoffs/ANSWER\u0000.md","content":"x"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'contains a control byte' \
  && ok "R4: an embedded NUL byte in the structured path also escalates (same \$(...)-strips-the-byte risk as the newline case)" \
  || not_ok "expected escalate (NUL byte), got rc=$rc: $out"

out="$(enf write '{"path":".h*/ANSWER.md","content":"x"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "F4: a glob path component (.h*) is judged LITERALLY, never expanded against the worktree cwd" \
  || not_ok "expected escalate (glob), got rc=$rc: $out"

out="$(enf write '{"path":".handoff[s]/ANSWER.md","content":"x"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'restricts its write tool to .handoffs/ANSWER.md only' \
  && ok "F4: a bracket-glob path component is also judged literally" \
  || not_ok "expected escalate (bracket glob), got rc=$rc: $out"

rm -rf "$wt/.handoffs"; ln -s src "$wt/.handoffs"
out="$(enf write '{"path":".handoffs/ANSWER.md","content":"x"}')"; rc=$?
rm -f "$wt/.handoffs"; mkdir -p "$wt/.handoffs"
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'symlink to somewhere else' \
  && ok "F5: .handoffs itself replaced by a directory symlink, ANSWER.md not yet existing, still escalates (realpath resolves the missing leaf's ancestors)" \
  || not_ok "expected escalate (dir symlink, missing leaf), got rc=$rc: $out"

register_task run1 task_nomanifest worker1 cond1 "$CPANE" "$CBIRTH" "$PANE" "$BIRTH" /repo "$wt" impl:task_nomanifest feat/y main "" "" hook >/dev/null
set_task_state run1 task_nomanifest running
out="$(enf write '{"path":"src/other.txt","content":"unrestricted"}' task_nomanifest)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] \
  && ok "no handoffs_write manifest: an ordinary worktree write still allows (containment-159, unaffected by this fix)" \
  || not_ok "expected allow rc=0, got rc=$rc: $out"

out="$(enf write '{"path":"xd://retain","content":"{\"content\":\"x\"}"}' task_nomanifest)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] \
  && ok "F2 control: no handoffs_write manifest — xd://retain still runs the ordinary device table, unaffected by this fix" \
  || not_ok "expected allow rc=0, got rc=$rc: $out"

out="$(enf retain '{"content":"x"}' task_nomanifest)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] \
  && ok "R2 control: no handoffs_write manifest — the bare 'retain' tool name still allows, unaffected by this fix" \
  || not_ok "expected allow rc=0, got rc=$rc: $out"

out="$(enf write '{"path":"local://note.md","content":"x"}' task_nomanifest)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] \
  && ok "R2 control: no handoffs_write manifest — write local://note.md still allows, unaffected by this fix" \
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
q() { sqlite3 "$(registry_db)" "$1"; }

out="$(HERDR_MCP_CONDUCTOR_PANE="$AGENT_PANE" dryc)"
printf '%s' "$out" | grep -q "conductor_pane=$AGENT_PANE " \
  && ok "no HERDR_PANE_ID, a live agent pane named by HERDR_MCP_CONDUCTOR_PANE: adopted as the fallback conductor" \
  || not_ok "fallback not adopted: $(printf '%s' "$out" | grep registry)"

register_task run1 task_occupant worker1 cond1 "$CPANE" "$CBIRTH" "$AGENT_PANE" gen-agent /repo "$wt" impl:task_occupant feat/occ main "" "" hook >/dev/null
set_task_state run1 task_occupant running
out="$(HERDR_MCP_CONDUCTOR_PANE="$AGENT_PANE" dryc)"
printf '%s' "$out" | grep -q 'conductor_pane=<none' \
  && ok "F8: a pane that is CURRENTLY an active worker's own task pane is refused as a conductor fallback, even though pane_is_agent says yes (a worker is never a conductor)" \
  || not_ok "an active worker's pane was adopted as the conductor: $(printf '%s' "$out" | grep registry)"
set_task_state run1 task_occupant completed no-follow-on >/dev/null
out="$(HERDR_MCP_CONDUCTOR_PANE="$AGENT_PANE" dryc)"
printf '%s' "$out" | grep -q "conductor_pane=$AGENT_PANE " \
  && ok "F8 control: once that task is terminal, the SAME pane is adoptable again" \
  || not_ok "a freed pane was still refused: $(printf '%s' "$out" | grep registry)"

out="$(HERDR_MCP_CONDUCTOR_PANE="$AGENT_PANE" HERDR_MCP_CONDUCTOR_BIRTH='expected-birth-that-does-not-match' dryc)"
printf '%s' "$out" | grep -q 'conductor_pane=<none' \
  && ok "R3: a pinned HERDR_MCP_CONDUCTOR_BIRTH that does not match the pane's live terminal_id refuses the fallback (recycled to an unrelated, unregistered session)" \
  || not_ok "birth-mismatched pane was adopted anyway: $(printf '%s' "$out" | grep registry)"
row="$(q "SELECT payload FROM events WHERE type='conductor_fallback_rejected' ORDER BY sequence DESC LIMIT 1;")"
printf '%s' "$row" | grep -q 'does not match the pinned HERDR_MCP_CONDUCTOR_BIRTH' \
  && ok "R3: the rejected fallback is now recorded as a conductor_fallback_rejected event (used to leave no trace)" \
  || not_ok "no conductor_fallback_rejected event recorded for the birth mismatch: $row"

out="$(HERDR_MCP_CONDUCTOR_PANE="$AGENT_PANE" HERDR_MCP_CONDUCTOR_BIRTH='gen-agent' dryc)"
printf '%s' "$out" | grep -q "conductor_pane=$AGENT_PANE " \
  && ok "R3 control: a pinned HERDR_MCP_CONDUCTOR_BIRTH that MATCHES the live pane still adopts it" \
  || not_ok "birth-matched pane was refused: $(printf '%s' "$out" | grep registry)"

out="$(HERDR_MCP_CONDUCTOR_PANE='w6:p6' dryc)"    # not in the fake herdr's pane list at all
printf '%s' "$out" | grep -q 'conductor_pane=<none' \
  && ok "HERDR_MCP_CONDUCTOR_PANE naming a dead/unknown pane: left empty exactly as before, task still starts" \
  || not_ok "dead pane was adopted anyway: $(printf '%s' "$out" | grep registry)"

out="$(env -u HERDR_TASK_ID -u HERDR_RUN_ID HERDR_PANE_ID="$PANE" HERDR_MCP_CONDUCTOR_PANE="$AGENT_PANE" HERDR_EXTRA_PATH="$work/bin" bash "$here/spawn-task.sh" --dry-run --no-secrets "$repo" fix/mcp-fallback2 implement omp 2>&1)"
printf '%s' "$out" | grep -q "conductor_pane=$PANE " \
  && ok "an interactive HERDR_PANE_ID is never overridden by HERDR_MCP_CONDUCTOR_PANE" \
  || not_ok "interactive pane was overridden: $(printf '%s' "$out" | grep registry)"

printf '== D: lib/command-policy.sh _cp_lexical_abspath (R1, security review round 2) ==\n'
# R1: this used to pop a ".." component via `set -- "${@:1:$(($#-1))}"` on
# the bash POSITIONAL PARAMETERS while `IFS=/` was active for the split.
# Confirmed live on this machine's /bin/bash (GNU bash 3.2.57): that does
# not even preserve the split, let alone pop the right element -- the
# reviewer's exact repro strings below must resolve to their lexical
# normal form, not a corrupted, space-merged string.
( . "$here/lib/command-policy.sh" >/dev/null 2>&1
  lex_check() {
    local got; got="$(_cp_lexical_abspath "$1")"
    [ "$got" = "$2" ] && echo "ok $1" || echo "FAIL $1 -> '$got' (want '$2')"
  }
  lex_check /w/t/src/../x /w/t/x
  lex_check /w/t/a/b/../../x /w/t/x
  lex_check /w/t/src/../.handoffs/ANSWER.md /w/t/.handoffs/ANSWER.md
) > "$work/r1.out"
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok "R1: ${line#ok }" ;;
    FAIL*) not_ok "R1: $line" ;;
  esac
done < "$work/r1.out"

printf '== E: F3 — handoffs_write also narrows bash, not just the write tool ==\n'
# Before the fix every escalate row below auto-allowed: peer_decide never saw
# handoffs_write, and the outer #184 hook only proves "inside the worktree".
rm -f "$wt/.handoffs/ANSWER.md"; mkdir -p "$wt/tmp"
bash_case() {                           # want(allow|escalate) command
  local want="$1" c="$2" out rc d
  out="$(enf bash "$(jq -nc --arg c "$c" '{command:$c}')")"; rc=$?
  d="$(printf '%s' "$out" | field decision)"
  if [ "$want" = allow ]; then
    [ "$rc" = 0 ] && [ "$d" = allow ] && ok "F3 allow: $c" || not_ok "F3 expected allow for [$c], got rc=$rc: $out"
  else
    [ "$rc" = 8 ] && [ -n "$(printf '%s' "$out" | field request_id)" ] && printf '%s' "$out" | field reason | grep -q 'restricts writes to .handoffs/ANSWER.md only' \
      && ok "F3 escalate: $c" || not_ok "F3 expected handoffs-write escalation for [$c], got rc=$rc: $out"
  fi
}
while IFS='|' read -r want c; do
  [ -n "$want" ] && bash_case "$want" "$c"
done <<'EOF'
allow|echo x > .handoffs/ANSWER.md
allow|printf x | tee .handoffs/ANSWER.md
allow|echo x > tmp/scratch.txt
allow|echo x > /tmp/f3-scratch-new
allow|cat README.md
allow|grep -rn foo . | head -5
allow|git log --oneline -3
allow|git diff HEAD -- src
allow|find . -name '*.py' -type f
allow|rg -n foo src | sort | head -20
allow|mkdir -p tmp/work && echo x > tmp/work/notes.txt
escalate|echo x > src/x.py
escalate|echo x > .handoffs/OTHER.md
escalate|echo x >> README.md
escalate|cd src && echo x > a.txt
escalate|echo x > tmp/../src/x.py
escalate|cat <<X > src/y.py
escalate|printf x | tee src/x.py
escalate|cp README.md src/copy.md
escalate|mv README.md src/moved.md
escalate|touch src/new
escalate|mkdir src/d
escalate|ln -s ../x .handoffs/ANSWER.md
escalate|sed -i '' s/a/b/ README.md
escalate|bash -c 'echo x > src/c'
escalate|tar -xf a.tar -C src
escalate|rsync a src/b
escalate|curl -o src/page.html https://example.com
escalate|perl -pi -e s/a/b/ README.md
escalate|awk '{print > "src/out"}' README.md
escalate|python3 -c 'open("src/p","w")'
escalate|node -e 'require("fs").writeFileSync("src/n","x")'
escalate|make
escalate|echo x > ../outside
escalate|tar -xf a.tar
escalate|cc -o src/evil tmp/x.c
escalate|timeout 5 cat README.md > src/a
escalate|sed -n p README.md
escalate|git -C src log
escalate|git checkout -- README.md
escalate|rg --pre ./tmp/x foo
escalate|cp -l src/x tmp/hl
escalate|cat "$(echo x > src/evil)"
escalate|printf '%s' "$(echo x > src/evil-2)"
escalate|cat `echo x > src/evil-3`
escalate|X=$(echo x > src/evil-4) cat README.md
escalate|git diff -osrc/git-glued-output
escalate|git show -osrc/x HEAD
escalate|git -Csrc log
escalate|git log --output=src/x
escalate|git diff --ext-diff
escalate|nice tee tmp/out
escalate|GIT_EXTERNAL_DIFF=./tmp/x git diff
escalate|LC_ALL=C grep foo README.md
EOF
# These are refused by peer_decide before F3 runs (find -exec/-delete, xargs,
# $VAR, unreviewable scripts, the env credential rule); they must stay refused.
for c in 'find . -name a -exec cp {} src/b \;' 'find . -name a -delete' 'echo src/z | xargs touch' 'echo x > "$OUT"' 'python3 tmp/probe.py' 'timeout 5 python3 tmp/p.py' "env -S \"python3 -c 'open(\\\"src/a\\\",\\\"w\\\")'\"" 'env --chdir=src tee tmp/out' 'env -C src touch tmp/out'; do
  out="$(enf bash "$(jq -nc --arg c "$c" '{command:$c}')")"; rc=$?
  [ "$rc" = 8 ] && ok "F3 still refused: $c" || not_ok "F3 expected refusal for [$c], got rc=$rc: $out"
done
# The deliverable itself replaced by a symlink: a bash redirect must refuse too.
ln -s ../src/x "$wt/.handoffs/ANSWER.md"
out="$(enf bash '{"command":"echo x > .handoffs/ANSWER.md"}')"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -q 'symlink' \
  && ok "F3: bash redirect into a symlinked ANSWER.md escalates" || not_ok "F3 symlinked ANSWER.md: rc=$rc: $out"
rm -f "$wt/.handoffs/ANSWER.md"
# Link planting through scratch or the deliverable (Zero review scope): every
# allowed target is resolved on disk, never matched lexically.
link_case() {                           # label command
  local out rc
  out="$(enf bash "$(jq -nc --arg c "$2" '{command:$c}')")"; rc=$?
  [ "$rc" = 8 ] && printf '%s' "$out" | field reason | grep -qE 'symlink|hard link|restricts writes' \
    && ok "F3 link: $1" || not_ok "F3 link [$1] expected escalation, got rc=$rc: $out"
}
printf 'tracked\n' > "$wt/src/victim"
ln "$wt/src/victim" "$wt/.handoffs/ANSWER.md"
link_case "ANSWER.md hard-linked to src/victim" 'echo x > .handoffs/ANSWER.md'
rm -f "$wt/.handoffs/ANSWER.md"
ln -s ../src/victim "$wt/tmp/sl"
link_case "tmp/ file is a symlink into src/" 'echo x > tmp/sl'
rm -f "$wt/tmp/sl"
ln "$wt/src/victim" "$wt/tmp/hl"
link_case "tmp/ file is a hard link to src/victim" 'echo x > tmp/hl'
rm -f "$wt/tmp/hl"
mv "$wt/tmp" "$wt/tmp.real"; ln -s src "$wt/tmp"
link_case "tmp/ itself is a symlink to src/" 'echo x > tmp/new.txt'
rm -f "$wt/tmp"; mv "$wt/tmp.real" "$wt/tmp"
tlnk="$(mktemp -u /tmp/f3-hl.XXXXXX)"; ln "$wt/src/victim" "$tlnk"
link_case "/tmp file is a hard link to src/victim" "echo x > $tlnk"
rm -f "$tlnk"; ln -s "$wt/src/victim" "$tlnk"
link_case "/tmp file is a symlink into the worktree" "echo x > $tlnk"
rm -f "$tlnk"
mv "$wt/.handoffs" "$wt/.handoffs.real"; ln -s src "$wt/.handoffs"
link_case ".handoffs itself is a symlink to src/" 'echo x > .handoffs/ANSWER.md'
rm -f "$wt/.handoffs"; mv "$wt/.handoffs.real" "$wt/.handoffs"
[ "$(cat "$wt/src/victim")" = tracked ] && ok "F3 link: src/victim untouched (judging only, nothing ran)" || not_ok "src/victim changed"
bash_case allow 'echo x > tmp/sub/new.txt'
# A task WITHOUT handoffs_write is unchanged (in-worktree bash write allowed).
register_task run1 task_impl worker1 cond1 "$CPANE" "$CBIRTH" "$PANE" "$BIRTH" /repo "$wt" impl:task_impl feat/y main "" '{}' hook >/dev/null
set_task_state run1 task_impl running
out="$(enf bash '{"command":"echo x > src/x.py"}' task_impl)"; rc=$?
[ "$rc" = 0 ] && ok "F3: a task with no handoffs_write still allows in-worktree bash writes" || not_ok "F3 no-hw task: rc=$rc: $out"

printf '\n%s\n' "-----"
printf 'passed=%s failed=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'PASS\n'; exit 0; else printf 'FAIL\n'; exit 1; fi
