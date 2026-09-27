#!/usr/bin/env bash
# verify-pretool-enforce.sh — hook approval (docs/design/pretool-approval.md §4):
# lib/pretool-shadow.sh --enforce, lib/action-request.sh, herdr-action.sh,
# the omp hook's enforcing path, and spawn-task.sh --approval. Every block and
# allow path, red and green; plus proof that a default (menu) worker and a
# default spawn behave exactly as before.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export HERDR_RUN_STATE_DIR="$work/runs" HERDR_STATE_ROOT="$work/state"
export PANE='w1:p1' BIRTH='gen-1' CPANE='w9:p9' CBIRTH='cgen-1'
export HERDR_PANE_ID="$PANE" HERDR_RUN_ID='run1' HERDR_TASK_ID='task1'
wt="$work/worktree"; mkdir -p "$wt/tmp" "$HERDR_STATE_ROOT/forms" "$work/bin"
wtp="$(cd "$wt" && pwd -P)"             # what realpath resolves (/var -> /private/var on macOS)
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
export HERDR_ACTION_NO_SURFACE=1       # surfacing is exercised explicitly below

. "$here/lib/run-registry.sh"
reg() {                                  # task approval
  register_task run1 "$1" worker1 cond1 "$CPANE" "$CBIRTH" "$PANE" "$BIRTH" /repo "$wt" "impl:$1" feat/x main "" "" "$2" >/dev/null
  set_task_state run1 "$1" running
}
reg task1 hook
good=0 bad=0
ok() { good=$((good + 1)); printf '  ok    %s\n' "$1"; }
not_ok() { bad=$((bad + 1)); printf '  FAIL  %s\n' "$1"; }
q() { sqlite3 "$(registry_db)" "$1"; }
field() { jq -r ".$1"; }
enf() {                                  # tool input-json [cwd] -> {decision,reason,request_id}
  jq -nc --arg t "$1" --argjson i "$2" --arg c "${3:-$wt}" '{tool:$t, input:$i, call_id:("c"+($i|tostring|length|tostring)), cwd:$c}' \
    | bash "$here/lib/pretool-shadow.sh" --enforce --record
}
bashc() { enf bash "$(jq -nc --arg c "$1" --arg i "${2:-run it}" '{command:$c, i:$i}')"; }
act() { bash "$here/herdr-action.sh" "$@"; }

printf '== registry: the posture is on the row, fixed at registration ==\n'
[ "$(read_task run1 task1 | field approval)" = hook ] && ok "row carries approval=hook" || not_ok "row approval: $(read_task run1 task1)"
[ "$(q "SELECT count(*) FROM events WHERE task_id='task1' AND type='approval_posture';")" = 1 ] && ok "approval_posture event recorded once" || not_ok "no approval_posture event"
reg task_menu menu
[ "$(read_task run1 task_menu | field approval)" = menu ] && ok "default row is approval=menu" || not_ok "menu row wrong"
[ "$(q "SELECT count(*) FROM events WHERE task_id='task_menu' AND type='approval_posture';")" = 0 ] && ok "a menu registration writes no posture event (unchanged)" || not_ok "menu wrote a posture event"
register_task run1 task_bad w c "$CPANE" "$CBIRTH" "$PANE" "$BIRTH" /repo "$wt" x b main "" "" yolo >/dev/null 2>&1 \
  && not_ok "an invalid approval posture was registered" || ok "invalid approval posture refused by register_task"

printf '== enforce: allow / deny / block paths ==\n'
out="$(bashc 'git status --short')"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] && ok "allow verdict runs (rc 0)" || not_ok "allow: rc=$rc $out"
out="$(bashc 'rm -rf /')"; rc=$?
[ "$rc" = 8 ] && [ -z "$(printf '%s' "$out" | field request_id)" ] && printf '%s' "$out" | grep -q 'Nobody can approve' \
  && ok "deny: blocked, no request, says nobody can approve" || not_ok "deny: rc=$rc $out"
out="$(enf eval '{"language":"py","code":"print(1)"}')"; rc=$?
[ "$rc" = 8 ] && [ -z "$(printf '%s' "$out" | field request_id)" ] && ok "eval: blocked, no request" || not_ok "eval: $out"
out="$(enf write '{"path":"xd://secret_present","content":"{}"}')"
[ "$(printf '%s' "$out" | field verdict)" = reserved ] && [ -n "$(printf '%s' "$out" | field request_id)" ] \
  && ok "secret_present: reserved -> human request" || not_ok "secret_present: $out"
[ "$(q "SELECT count(*) FROM action_requests;")" = 1 ] && ok "only the reserved call made a request so far" || not_ok "request rows: $(q 'SELECT count(*) FROM action_requests;')"

printf '== escalate -> request -> conductor approve -> one-shot grant ==\n'
ESC='chmod -R u+rw tmp/probe'
out="$(bashc "$ESC" 'first try')"; rc=$?
rid="$(printf '%s' "$out" | field request_id)"
[ "$rc" = 8 ] && [ -n "$rid" ] && printf '%s' "$out" | grep -q "Requested as $rid for your conductor" \
  && ok "escalate: blocked, request $rid, told it went to the conductor" || not_ok "escalate: rc=$rc $out"
[ "$(q "SELECT route||'/'||grant_kind||'/'||status FROM action_requests WHERE request_id='$rid';")" = conductor/once/pending ] \
  && ok "request row: conductor / once / pending" || not_ok "row: $(q "SELECT * FROM action_requests WHERE request_id='$rid';")"
[ "$(q "SELECT command FROM action_requests WHERE request_id='$rid';")" = "$ESC" ] && ok "the reviewer sees the exact command" || not_ok "command text wrong"
[ "$(q "SELECT count(*) FROM events WHERE type='action_requested' AND json_extract(payload,'\$.request_id')='$rid';")" = 1 ] \
  && ok "action_requested event recorded" || not_ok "no action_requested event"
out="$(bashc "$ESC" 'second try, rephrased intent')"
[ "$(printf '%s' "$out" | field request_id)" = "$rid" ] && printf '%s' "$out" | grep -q 'still waiting' \
  && ok "identical re-issue (different intent text) -> same pending request" || not_ok "re-issue: $out"
[ "$(q "SELECT count(*) FROM action_requests WHERE task_id='task1';")" = 2 ] && ok "no duplicate request row" || not_ok "dup rows"

HERDR_PANE_ID="$PANE" act approve "$rid" --authority conductor --review-category local-build --review-reason ok >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "approve from a pane that is not the task's conductor: refused" || not_ok "wrong-pane approve rc=$rc"
FAKE_CBIRTH=other HERDR_PANE_ID="$CPANE" act approve "$rid" --authority conductor --review-category local-build --review-reason ok >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "approve from a recycled conductor pane: refused" || not_ok "recycled conductor rc=$rc"
HERDR_PANE_ID="$CPANE" act approve "$rid" --authority conductor --review-reason ok >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "approve without an operational review category: refused" || not_ok "no-category rc=$rc"
HERDR_PANE_ID="$CPANE" act approve "$rid" --authority conductor --review-category local-build >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "approve without a review reason: refused" || not_ok "no-reason rc=$rc"
[ "$(q "SELECT status FROM action_requests WHERE request_id='$rid';")" = pending ] && ok "still pending after 4 refused approvals" || not_ok "status moved"
: > "$work/sent"
HERDR_PANE_ID="$CPANE" act approve "$rid" --authority conductor --review-category local-build --review-reason "scratch dir, own worktree" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(q "SELECT status||'/'||authority FROM action_requests WHERE request_id='$rid';")" = approved/conductor ] \
  && ok "the live conductor approves" || not_ok "approve rc=$rc"
grep -q "^$PANE \[HERDR-ACTION\] $rid APPROVED" "$work/sent" && ok "worker told in its own pane to re-issue" || not_ok "worker not told: $(cat "$work/sent")"
[ "$(q "SELECT authority||'/'||choice_text||'/'||outcome FROM approvals WHERE approval_id='appr_$rid';")" = conductor/Approve/submitted ] \
  && ok "approvals row recorded (conductor/Approve, delivery submitted)" || not_ok "approvals: $(q "SELECT * FROM approvals WHERE approval_id='appr_$rid';")"
HERDR_PANE_ID="$CPANE" act approve "$rid" --authority conductor --review-category local-build --review-reason again >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok "a second decision on the same request is refused (check-and-set)" || not_ok "double decide rc=$rc"
out="$(bashc 'chmod -R u+rw tmp/probe ')"
[ "$(printf '%s' "$out" | field decision)" = block ] && ok "different bytes (trailing space) do not match the grant" || not_ok "grant stretched: $out"
out="$(bashc "$ESC" 'third')"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | field decision)" = allow ] && ok "the identical call now runs (grant consumed)" || not_ok "consume: rc=$rc $out"
[ "$(q "SELECT status FROM action_requests WHERE request_id='$rid';")" = consumed ] && ok "request is consumed" || not_ok "not consumed"
out="$(bashc "$ESC" 'fourth')"
rid2="$(printf '%s' "$out" | field request_id)"
[ "$(printf '%s' "$out" | field decision)" = block ] && [ -n "$rid2" ] && [ "$rid2" != "$rid" ] \
  && ok "one-shot: the next identical call needs a NEW request ($rid2)" || not_ok "grant reused: $out"

printf '== parallel: identical calls make one request; one grant runs once ==\n'
PAR='chmod -R go-w tmp/par'
for k in 1 2 3 4 5 6; do bashc "$PAR" "p$k" > "$work/par$k" & done; wait
[ "$(q "SELECT count(*) FROM action_requests WHERE command='$PAR';")" = 1 ] && ok "6 parallel identical calls -> 1 request row" || not_ok "parallel rows: $(q "SELECT count(*) FROM action_requests WHERE command='$PAR';")"
prid="$(q "SELECT request_id FROM action_requests WHERE command='$PAR';")"
HERDR_PANE_ID="$CPANE" act approve "$prid" --authority conductor --review-category local-build --review-reason par >/dev/null
for k in 1 2 3 4 5 6; do bashc "$PAR" "r$k" > "$work/rr$k" & done; wait
n="$(cat "$work"/rr? | jq -r .decision | grep -c '^allow$')"
[ "$n" = 1 ] && ok "6 parallel re-issues after one approval -> exactly 1 runs" || not_ok "parallel consume allowed $n"

printf '== decline ==\n'
DEC='chmod -R a+x tmp/dec'
rid3="$(bashc "$DEC" | field request_id)"
HERDR_PANE_ID="$CPANE" act decline "$rid3" --authority conductor --review-reason "use a narrower mode" >/dev/null
out="$(bashc "$DEC" 'again')"
printf '%s' "$out" | grep -q "DECLINED (conductor): use a narrower mode" && [ "$(printf '%s' "$out" | field decision)" = block ] \
  && ok "re-issue after decline: blocked with the reviewer's reason" || not_ok "decline: $out"
[ "$(q "SELECT count(*) FROM action_requests WHERE command='$DEC';")" = 1 ] && ok "no new request after a decline" || not_ok "decline re-requested"
grep -q "\[HERDR-ACTION\] $rid3 DECLINED" "$work/sent" && ok "worker told it was declined" || not_ok "decline not sent"

printf '== reserved: human only, through an answered hub form ==\n'
RES='gh pr merge 7 --squash'
out="$(bashc "$RES")"; hrid="$(printf '%s' "$out" | field request_id)"
printf '%s' "$out" | grep -q "human-only: requested as $hrid" && ok "reserved -> human request $hrid" || not_ok "reserved: $out"
HERDR_PANE_ID="$CPANE" act approve "$hrid" --authority conductor --review-category branch-work --review-reason x >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "conductor cannot approve a human-only request" || not_ok "conductor approved reserved rc=$rc"
act approve "$hrid" --authority human >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "bare --authority human (no form): refused" || not_ok "bare human rc=$rc"
jq -nc --arg id "$hrid" '{status:"open", answers:{request_id:$id, decision:"approve"}}' > "$HERDR_STATE_ROOT/forms/F1.json"
act approve "$hrid" --authority human --form F1 >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "an OPEN (unanswered) form is not an approval" || not_ok "open form rc=$rc"
jq -nc '{status:"answered", answers:{request_id:"ar_other", decision:"approve"}}' > "$HERDR_STATE_ROOT/forms/F2.json"
act approve "$hrid" --authority human --form F2 >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "a form answered for ANOTHER request is refused" || not_ok "wrong-request form rc=$rc"
jq -nc --arg id "$hrid" '{status:"answered", answers:{request_id:$id, decision:"decline"}}' > "$HERDR_STATE_ROOT/forms/F3.json"
act approve "$hrid" --authority human --form F3 >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "a form that says decline cannot approve" || not_ok "decline-form approve rc=$rc"
act approve "$hrid" --authority human --form ../F3 >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "a form id with a path is refused" || not_ok "path form id rc=$rc"
jq -nc --arg id "$hrid" '{status:"answered", answers:{request_id:$id, decision:"approve", reason:"ship it"}}' > "$HERDR_STATE_ROOT/forms/F4.json"
act approve "$hrid" --authority human --form F4 >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(q "SELECT status||'/'||authority FROM action_requests WHERE request_id='$hrid';")" = approved/human ] \
  && ok "an answered form for exactly this request approves (authority human)" || not_ok "human approve rc=$rc"
[ "$(bashc "$RES" | field decision)" = allow ] && ok "the reserved call runs once after the human's yes" || not_ok "human grant not consumed"

printf '== code by reference: approval binds to the file sha, re-runs, re-escalates on edit ==\n'
printf '#!/bin/bash\nchmod -R u+rw tmp/probe\n' > "$wt/tmp/esc.sh"
CR="cd $wt && bash tmp/esc.sh"
out="$(bashc "$CR")"; crid="$(printf '%s' "$out" | field request_id)"
[ "$(q "SELECT grant_kind||'/'||code_path FROM action_requests WHERE request_id='$crid';")" = "file/$wtp/tmp/esc.sh" ] \
  && ok "escalating script content -> file-kind request" || not_ok "code-ref: $out / $(q "SELECT grant_kind, code_path FROM action_requests WHERE request_id='$crid';")"
HERDR_PANE_ID="$CPANE" act approve "$crid" --authority conductor --review-category local-build --review-reason "read the file" >/dev/null
[ "$(q "SELECT count(*) FROM file_approvals WHERE task_id='task1' AND path='$wtp/tmp/esc.sh';")" = 1 ] && ok "file_approvals row written for (task, path, sha)" || not_ok "no file approval"
a1="$(bashc "$CR" | field decision)"; a2="$(bashc "$CR" | field decision)"
[ "$a1/$a2" = allow/allow ] && ok "the same bytes re-run without review (twice)" || not_ok "file re-run: $a1/$a2"
printf '#!/bin/bash\nchmod -R u+rwx tmp/probe\n' > "$wt/tmp/esc.sh"
[ "$(bashc "$CR" | field decision)" = block ] && ok "an edited file escalates again" || not_ok "edited file ran"

printf '== learn goes to the conductor (q4) ==\n'
out="$(enf learn '{"memory":"lesson text","i":"x"}')"
lrid="$(printf '%s' "$out" | field request_id)"
[ -n "$lrid" ] && [ "$(q "SELECT route FROM action_requests WHERE request_id='$lrid';")" = conductor ] \
  && ok "learn: blocked, conductor request" || not_ok "learn: $out"

printf '== identity fails closed in enforce mode ==\n'
reg task_m menu
out="$(HERDR_TASK_ID=task_m bashc ls)"; rc=$?
[ "$rc" = 8 ] && printf '%s' "$out" | grep -q 'approval=menu' && ok "launched for hook, row says menu: refused" || not_ok "row-menu: rc=$rc $out"
out="$(HERDR_TASK_ID=nope bashc ls)"; rc=$?
[ "$rc" = 8 ] && ok "no registry row: refused" || not_ok "no row rc=$rc"
out="$(FAKE_BIRTH=gen-2 bashc ls)"; rc=$?
[ "$rc" = 8 ] && ok "recycled worker pane: refused" || not_ok "recycled rc=$rc"
printf x > "$work/nd"
out="$(HERDR_RUN_STATE_DIR="$work/nd/runs" bashc ls)"; rc=$?
[ "$rc" = 8 ] && ok "unreadable registry: refused" || not_ok "unreadable rc=$rc"

printf '== surfacing and the hub tick ==\n'
: > "$work/sent"
bash "$here/herdr-action.sh" surface "$rid2"; bash "$here/herdr-action.sh" surface "$rid2"
[ "$(grep -c "^$CPANE \[HERDR-ACTION\].*$rid2" "$work/sent")" = 1 ] && ok "surface wakes the conductor pane exactly once" || not_ok "surface sends: $(cat "$work/sent")"
grep -q "herdr-action.sh approve $rid2 --authority conductor" "$work/sent" && ok "the wake names the exact approve command" || not_ok "wake text"
: > "$work/sent"
FAKE_CBIRTH=other bash "$here/herdr-action.sh" surface "$lrid"
[ ! -s "$work/sent" ] && [ "$(q "SELECT json_extract(payload,'\$.outcome') FROM events WHERE type='action_surfaced' AND json_extract(payload,'\$.request_id')='$lrid';")" = conductor_unreachable ] \
  && ok "a recycled conductor pane is not typed into (outcome conductor_unreachable)" || not_ok "unreachable: $(cat "$work/sent")"
out="$(bashc 'chmod -R u+w tmp/hum2' )"; srid="$(printf '%s' "$out" | field request_id)"
q "UPDATE action_requests SET route='human', verdict='reserved' WHERE request_id='$srid';"
: > "$work/notified"
bash "$here/herdr-action.sh" tick; bash "$here/herdr-action.sh" tick
fp="$(q "SELECT form_path FROM action_requests WHERE request_id='$srid';")"
[ -r "$fp" ] && grep -q "$srid" "$fp" && ok "tick served a hub decision form for the human request" || not_ok "no form: '$fp'"
[ "$(grep -c -- "--class human-action" "$work/notified")" -ge 1 ] && [ "$(grep -c "$srid" "$work/notified")" = 1 ] \
  && ok "one Slack alert (class human-action) across two ticks" || not_ok "notify: $(cat "$work/notified")"
rec="$(grep -l -F "\"form_path\":\"$fp\"" "$HERDR_STATE_ROOT"/forms/*.json | head -1)"
jq -c '.status="expired"' "$rec" > "$rec.t" && mv "$rec.t" "$rec"
bash "$here/herdr-action.sh" tick
fp2="$(q "SELECT form_path FROM action_requests WHERE request_id='$srid';")"
[ "$(q "SELECT status FROM action_requests WHERE request_id='$srid';")" = pending ] && [ "$fp2" != "$fp" ] && [ -r "$fp2" ] \
  && ok "expired form: request still pending, a fresh form is served (expiry is not a decline)" || not_ok "expiry: status $(q "SELECT status FROM action_requests WHERE request_id='$srid';")"
[ "$(q "SELECT count(*) FROM events WHERE type='action_form_expired';")" -ge 1 ] && ok "action_form_expired recorded" || not_ok "no expiry event"
[ "$(grep -c "$srid" "$work/notified")" = 1 ] && ok "no second Slack post for a re-served form" || not_ok "slack re-posted"
rec2="$(grep -l -F "\"form_path\":\"$fp2\"" "$HERDR_STATE_ROOT"/forms/*.json | head -1)"
jq -c --arg id "$srid" '.status="answered" | .answers={request_id:$id, decision:"approve", reason:"fine"}' "$rec2" > "$rec2.t" && mv "$rec2.t" "$rec2"
bash "$here/herdr-action.sh" tick
[ "$(q "SELECT status||'/'||authority FROM action_requests WHERE request_id='$srid';")" = approved/human ] \
  && ok "tick applies an answered hub form (approved, authority human)" || not_ok "tick apply: $(q "SELECT status, authority FROM action_requests WHERE request_id='$srid';")"
out="$(bashc 'chmod -R u+rw tmp/stale')"; strid="$(printf '%s' "$out" | field request_id)"
: > "$work/notified"
HERDR_ACTION_STALE_S=0 bash "$here/herdr-action.sh" tick
grep -q "$strid" "$work/notified" && ok "a conductor request left pending past the stale window goes to the human route" || not_ok "stale not escalated"
emp="$work/empty"; mkdir -p "$emp"
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
HERDR_RUN_STATE_DIR="$emp" bash "$here/herdr-action.sh" tick
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
[ $((t1 - t0)) -lt 300 ] && ok "tick with no registry/pending work is cheap ($((t1 - t0))ms)" || not_ok "idle tick took $((t1 - t0))ms"

printf '== the omp hook: enforcing only for approval=hook rows ==\n'
if command -v bun >/dev/null 2>&1; then
  hook_js='const mod = await import(process.env.HOOK); const h = {}; mod.default({on: (e, f) => { h[e] = f; }});
    const cases = JSON.parse(process.env.CASES); const out = [];
    for (const c of cases) { let r; try { r = h.tool_call(c.ev, {cwd: process.env.WT}); } catch (err) { r = "THREW"; }
      out.push({id: c.id, r: r === "THREW" ? "THREW" : (r?.block ? "BLOCK" : "ALLOW"), why: r?.reason ?? ""}); }
    console.log(JSON.stringify(out)); await new Promise((res) => setTimeout(res, 800));'
  cases="$(jq -nc --arg wt "$wt" '[
    {id:"allow", ev:{toolName:"bash", toolCallId:"k1", input:{command:"git status --short"}}},
    {id:"escalate", ev:{toolName:"bash", toolCallId:"k2", input:{command:"chmod -R u+rw tmp/hookcase"}}},
    {id:"reserved", ev:{toolName:"bash", toolCallId:"k3", input:{command:"gh api -X PUT repos/o/r/pulls/7/merge"}}},
    {id:"eval", ev:{toolName:"eval", toolCallId:"k4", input:{code:"1"}}},
    {id:"read", ev:{toolName:"read", toolCallId:"k5", input:{path:($wt + "/x")}}},
    {id:"junk", ev:{toolName:42, input:"x"}}]')"
  run_hook() { HOOK="$1/agent-hooks/omp-herdr-control.ts" HERDR_CONTROL_DIR="$1" CASES="$cases" WT="$wt" bun -e "$hook_js" 2>/dev/null; }
  mine="$(run_hook "$here")"
  [ "$(printf '%s' "$mine" | jq -c '[.[]|.r]')" = '["ALLOW","BLOCK","BLOCK","BLOCK","ALLOW","BLOCK"]' ] \
    && ok "hook row: allow runs; escalate/reserved/eval/junk blocked; read runs" || not_ok "hook row: $mine"
  printf '%s' "$mine" | jq -r '.[1].why' | grep -q 'Requested as ar_' && ok "escalate block reason names the request" || not_ok "reason: $(printf '%s' "$mine" | jq -r '.[1].why')"
  hk="$(q "SELECT request_id FROM action_requests WHERE command='chmod -R u+rw tmp/hookcase';")"
  HERDR_PANE_ID="$CPANE" act approve "$hk" --authority conductor --review-category local-build --review-reason hook >/dev/null
  again="$(run_hook "$here")"
  [ "$(printf '%s' "$again" | jq -r '.[1].r')" = ALLOW ] && ok "after approval the hook lets the identical call run" || not_ok "post-approve: $again"
  [ "$(printf '%s' "$(run_hook "$here")" | jq -r '.[1].r')" = BLOCK ] && ok "…exactly once" || not_ok "grant reused through the hook"
  nolib="$work/nolib"; mkdir -p "$nolib/agent-hooks" "$nolib/lib"; cp "$here/agent-hooks/omp-herdr-control.ts" "$nolib/agent-hooks/"
  cp "$here/lib/run-registry.sh" "$nolib/lib/"
  [ "$(HOOK="$nolib/agent-hooks/omp-herdr-control.ts" HERDR_CONTROL_DIR="$nolib" CASES="$cases" WT="$wt" bun -e "$hook_js" 2>/dev/null | jq -r '.[0].r')" = BLOCK ] \
    && ok "hook row with the pre-tool lib missing: fails closed (BLOCK)" || not_ok "missing lib did not block"
  envhook="$(HERDR_TASK_ID=nope HERDR_APPROVAL=hook run_hook "$here")"
  [ "$(printf '%s' "$envhook" | jq -c '[.[]|.r]|unique')" = '["BLOCK"]' ] && ok "HERDR_APPROVAL=hook with no registry row: every call blocked" || not_ok "env-hook no-row: $envhook"
  menu_mine="$(HERDR_TASK_ID=task_m run_hook "$here")"
  base_dir="$work/base"; git -C "$here" worktree add -q --detach "$base_dir" origin/main 2>/dev/null
  menu_base="$(HERDR_TASK_ID=task_m run_hook "$base_dir")"
  nw_mine="$(env -u HERDR_TASK_ID -u HERDR_RUN_ID CASES="$cases" WT="$wt" bash -c 'HOOK="$1/agent-hooks/omp-herdr-control.ts" HERDR_CONTROL_DIR="$1" bun -e "$2"' _ "$here" "$hook_js" 2>/dev/null)"
  nw_base="$(env -u HERDR_TASK_ID -u HERDR_RUN_ID CASES="$cases" WT="$wt" bash -c 'HOOK="$1/agent-hooks/omp-herdr-control.ts" HERDR_CONTROL_DIR="$1" bun -e "$2"' _ "$base_dir" "$hook_js" 2>/dev/null)"
  git -C "$here" worktree remove --force "$base_dir" 2>/dev/null
  [ -n "$menu_mine" ] && [ "$(printf '%s' "$menu_mine" | jq -c '[.[]|{id,r}]')" = "$(printf '%s' "$menu_base" | jq -c '[.[]|{id,r}]')" ] \
    && ok "menu worker: every return value identical to origin/main ($(printf '%s' "$menu_mine" | jq -c '[.[]|.r]'))" || not_ok "menu differs: $menu_mine vs $menu_base"
  [ -n "$nw_mine" ] && [ "$nw_mine" = "$nw_base" ] && ok "non-worker session: identical to origin/main" || not_ok "non-worker differs: $nw_mine vs $nw_base"
else
  not_ok "bun not found — hook cases did not run"
fi

printf '== spawn-task.sh --approval ==\n'
norm() { sed -E 's/(run|task|worker)_[0-9TZ_]+/\1_X/g; s/term_[0-9a-f]+/term_X/g'; }
repo="$work/repo"; git init -q "$repo" && git -C "$repo" commit -q --allow-empty -m init
dry() { local d="$1"; shift; env -u HERDR_TASK_ID -u HERDR_RUN_ID HERDR_PANE_ID="$CPANE" bash "$d/spawn-task.sh" --dry-run --no-secrets "$repo" "$@" 2>&1 | norm | sed "s#$d/#<checkout>/#g"; }
base_dir="$work/base2"; git -C "$here" worktree add -q --detach "$base_dir" origin/main 2>/dev/null
a="$(dry "$here" fix/x implement omp)"; b="$(dry "$base_dir" fix/x implement omp)"
[ -n "$a" ] && [ "$a" = "$b" ] && ok "default spawn --dry-run is byte-identical to origin/main" || { not_ok "default dry-run differs"; diff <(printf '%s\n' "$b") <(printf '%s\n' "$a") | head; }
a="$(dry "$here" fix/x implement claude --approval menu)"; b="$(dry "$base_dir" fix/x implement claude)"
[ "$a" = "$b" ] && ok "explicit --approval menu is byte-identical to origin/main's default" || not_ok "--approval menu differs"
git -C "$here" worktree remove --force "$base_dir" 2>/dev/null
h="$(dry "$here" fix/x implement omp --approval hook)"
launch="$(printf '%s\n' "$h" | grep '^  launch')"
printf '%s' "$launch" | grep -q -- '--auto-approve --config .*agent-hooks/omp-worker-overlay.yml$' && ! printf '%s' "$launch" | grep -q -- '--approval-mode' \
  && ok "hook: launch is --auto-approve + worker overlay, no --approval-mode" || not_ok "hook launch: $launch"
printf '%s' "$h" | grep -q '^  approval  : hook' && ok "hook: dry-run states the approval posture" || not_ok "no approval line"
for bad_args in "--approval yolo" "--approval hook --posture strict"; do
  # shellcheck disable=SC2086
  out="$(dry "$here" fix/y implement omp $bad_args)"; 
  printf '%s' "$out" | grep -q 'refusing' && ok "refused: $bad_args" || not_ok "not refused: $bad_args -> $out"
done
out="$(dry "$here" fix/y implement omc --approval hook)"
printf '%s' "$out" | grep -q 'omp-only' && ok "refused: --approval hook with omc" || not_ok "omc hook: $out"
out="$(dry "$here" fix/y quick --approval hook -- echo hi)"
printf '%s' "$out" | grep -q 'managed agent launch' && ok "refused: --approval hook with a literal command" || not_ok "literal hook: $out"
[ ! -d "$HOME/.herdr/worktrees/$(basename "$repo")" ] && ok "refused spawns created no worktree" || not_ok "a refused spawn left a worktree"

printf '== shadow-compare.sh --gate (decision q1) ==\n'
g="$work/gate"; mkdir -p "$g"
( export HERDR_RUN_STATE_DIR="$g"; . "$here/lib/run-registry.sh"; registry_init >/dev/null
  sqlite3 "$g/pretool-shadow.sqlite3" "CREATE TABLE pretool_verdicts (sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id TEXT NOT NULL UNIQUE, run_id TEXT NOT NULL DEFAULT '', task_id TEXT NOT NULL DEFAULT '',
      type TEXT NOT NULL DEFAULT 'pretool_verdict', occurred_at TEXT NOT NULL, payload TEXT NOT NULL);
    WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<999)
    INSERT INTO pretool_verdicts(event_id, run_id, task_id, occurred_at, payload)
      SELECT 'g'||i, 'run1', 'gt'||(i%5), strftime('%Y-%m-%dT%H:%M:%SZ','now','-6 days','+'||(i*10)||' seconds'),
        json_object('mode','shadow','tool','bash','verdict','allow','command','echo '||i,'pane','') FROM n;"
  sqlite3 "$g/registry.sqlite3" "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<999)
    INSERT INTO approvals(approval_id, task_id, pane_id, authority, choice_text, command, decided_at)
      SELECT 'a'||i, 'gt'||(i%5), '', CASE WHEN i=0 THEN 'conductor' ELSE 'peer' END, 'Approve', 'echo '||i,
        strftime('%Y-%m-%dT%H:%M:%SZ','now','-6 days','+'||(i*10+1)||' seconds') FROM n;" )
gate() { HERDR_RUN_STATE_DIR="$g" bash "$here/scripts/shadow-compare.sh" --gate "$@"; }
out="$(gate)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL  (d) 1 SHADOW_LOOSER rows, 1 unexplained' && printf '%s' "$out" | grep -q '^PASS  (c) disagreement 1/1000' \
  && ok "gate FAILs on one unexplained SHADOW_LOOSER even at 0.1% disagreement" || not_ok "gate (unexplained): rc=$rc $out"
printf '1\tconductor approved a command the peer path would also allow; timing artefact\n' > "$g/shadow-explained.tsv"
out="$(gate)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^GATE: PASS' && ok "gate PASSes: 6 days, 1000 rows / 5 tasks, 0.1%, every looser row explained" || not_ok "gate (pass): rc=$rc $out"
sqlite3 "$g/registry.sqlite3" "UPDATE approvals SET authority='conductor' WHERE CAST(substr(approval_id,2) AS INTEGER) BETWEEN 1 AND 30;"
out="$(gate)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL  (c) disagreement 31/1000' && ok "gate FAILs above 2% disagreement (3.1%)" || not_ok "gate (rate): rc=$rc $out"
out="$(HERDR_RUN_STATE_DIR="$work/nogate" bash "$here/scripts/shadow-compare.sh" --gate)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'GATE: FAIL' && ok "gate FAILs with no shadow data" || not_ok "gate (empty): rc=$rc $out"

printf '\npassed=%d failed=%d\n' "$good" "$bad"
[ "$bad" -eq 0 ]
