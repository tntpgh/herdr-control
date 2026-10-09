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
export HERDR_EXTRA_PATH="$work/bin:${HERDR_EXTRA_PATH:-/opt/homebrew/bin:/usr/local/bin}"
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
[ "$(q "SELECT command FROM action_requests WHERE request_id='$rid';")" = "(in $wt) $ESC" ] && ok "the reviewer sees the exact command and where it runs" || not_ok "command text wrong: $(q "SELECT command FROM action_requests WHERE request_id='$rid';")"
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
grep -q "^$PANE --not-an-answer \[HERDR-ACTION\] $rid APPROVED" "$work/sent" && ok "worker told in its own pane to re-issue" || not_ok "worker not told: $(cat "$work/sent")"
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
[ "$(q "SELECT count(*) FROM action_requests WHERE command LIKE '%) $PAR';")" = 1 ] && ok "6 parallel identical calls -> 1 request row" || not_ok "parallel rows: $(q "SELECT count(*) FROM action_requests WHERE command LIKE '%) $PAR';")"
prid="$(q "SELECT request_id FROM action_requests WHERE command LIKE '%) $PAR';")"
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
[ "$(q "SELECT count(*) FROM action_requests WHERE command LIKE '%) $DEC';")" = 1 ] && ok "no new request after a decline" || not_ok "decline re-requested"
grep -q "\[HERDR-ACTION\] $rid3 DECLINED" "$work/sent" && ok "worker told it was declined" || not_ok "decline not sent"

printf '== supersede is non-granting, including code-by-reference requests ==\n'
SUP='chmod -R u+rw tmp/superseded'
srid="$(bashc "$SUP" | field request_id)"
ssha="$(q "SELECT action_sha256 FROM action_requests WHERE request_id='$srid';")"
HERDR_PANE_ID="$CPANE" act supersede "$srid" --authority conductor --action-sha256 "$ssha" --review-reason "worker moved on" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(q "SELECT status FROM action_requests WHERE request_id='$srid';")" = superseded ] \
  && ok "conductor explicitly cancels the pending bash request" || not_ok "bash supersede rc=$rc"
for verb in approve decline; do
  HERDR_PANE_ID="$CPANE" act "$verb" "$srid" --authority conductor \
    --review-category local-build --review-reason "late decision" >/dev/null 2>"$work/late-$verb.err"; rc=$?
  [ "$rc" = 4 ] && grep -Fq "is not pending (status superseded)" "$work/late-$verb.err" \
    && [ "$(q "SELECT status FROM action_requests WHERE request_id='$srid';")" = superseded ] \
    && ok "superseded-terminal: later $verb refused (rc=4), status stays superseded" \
    || not_ok "superseded-terminal: $verb rc=$rc: $(cat "$work/late-$verb.err")"
done
for k in 1 2 3 4 5 6; do bashc "$SUP" "retry$k" > "$work/sup$k" & done; wait
sid_new="$(cat "$work"/sup? | jq -r .request_id | sort -u)"
[ -n "$sid_new" ] && [ "$sid_new" != "$srid" ] && [ "$(printf '%s\n' "$sid_new" | wc -l | tr -d ' ')" = 1 ] \
  && [ "$(cat "$work"/sup? | jq -r .decision | sort -u)" = block ] \
  && [ "$(q "SELECT status FROM action_requests WHERE request_id='$sid_new';")" = pending ] \
  && ok "parallel identical reissues after supersede share one fresh pending request, none run" \
  || not_ok "supersede parallel reissues: $sid_new"
printf '#!/bin/bash\nchmod -R u+rw tmp/sup-file\n' > "$wt/tmp/sup-file.sh"
SUP_FILE="cd $wt && bash tmp/sup-file.sh"
file_out="$(bashc "$SUP_FILE")"
frid_sup="$(printf '%s' "$file_out" | field request_id)"
[ -n "$frid_sup" ] && [ "$(q "SELECT grant_kind FROM action_requests WHERE request_id='$frid_sup';")" = file ] \
  && ok "file cancellation setup escalates a resolved script as a file grant request" \
  || not_ok "file cancellation setup did not create a file request: $file_out"
fsha_sup="$(q "SELECT action_sha256 FROM action_requests WHERE request_id='$frid_sup';")"
HERDR_PANE_ID="$CPANE" act supersede "$frid_sup" --authority conductor --action-sha256 "$fsha_sup" --review-reason "not needed" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(q "SELECT count(*) FROM file_approvals;")" = 0 ] \
  && [ "$(bashc "$SUP_FILE" | field decision)" = block ] \
  && ok "superseding a file request records no persistent grant and reissue still blocks" \
  || not_ok "file cancellation failed (rc=$rc, request=$frid_sup)"

printf '== reserved: human only, through the hub form served for it ==\n'
pin_form() {                             # request_id -> pinned formserve record id (tick serves, next tick pins)
  q "UPDATE action_requests SET route='human' WHERE request_id='$1';" >/dev/null
  bash "$here/herdr-action.sh" tick; bash "$here/herdr-action.sh" tick
  q "SELECT form_record FROM action_requests WHERE request_id='$1';"
}
answer_form() {                          # record-id request-id decision [action-sha]
  local f="$HERDR_STATE_ROOT/forms/$1.json" sha="${4-$(q "SELECT action_sha256 FROM action_requests WHERE request_id='$2';")}"
  jq -c --arg id "$2" --arg d "$3" --arg sha "$sha" '.status="answered" | .answers={request_id:$id, action_sha256:$sha, decision:$d, reason:"ok"}' "$f" > "$f.t" && mv "$f.t" "$f"
}

printf '== conductor decisions retire pinned human forms ==\n'
for verb in approve decline supersede; do
  retire_rid="$(bashc "chmod -R u+rw tmp/retire-$verb" | field request_id)"
  retire_fid="$(pin_form "$retire_rid")"
  q "UPDATE action_requests SET route='conductor' WHERE request_id='$retire_rid';"
  retire_sha="$(q "SELECT action_sha256 FROM action_requests WHERE request_id='$retire_rid';")"
  HERDR_PANE_ID="$CPANE" act "$verb" "$retire_rid" --authority conductor \
    --action-sha256 "$retire_sha" --review-category local-build --review-reason "reviewed, worker moved on" >/dev/null; rc=$?
  [ "$rc" = 0 ] && [ "$(jq -r .status "$HERDR_STATE_ROOT/forms/$retire_fid.json")" = withdrawn ] \
    && ok "form-retirement: conductor $verb retires the pinned open human form" \
    || not_ok "form-retirement: $verb rc=$rc, form=$(jq -r .status "$HERDR_STATE_ROOT/forms/$retire_fid.json")"
done

printf '== review LOW followups: unpinned retirement, legacy answers and race audit ==\n'
for verb in approve decline supersede; do
  follow_rid="$(bashc "chmod -R u+rw tmp/follow-unpinned-$verb" | field request_id)"
  follow_fid="$(pin_form "$follow_rid")"
  q "UPDATE action_requests SET route='conductor', form_record='' WHERE request_id='$follow_rid';"
  follow_sha="$(q "SELECT action_sha256 FROM action_requests WHERE request_id='$follow_rid';")"
  HERDR_PANE_ID="$CPANE" act "$verb" "$follow_rid" --authority conductor \
    --action-sha256 "$follow_sha" --review-category local-build --review-reason "reviewed" >/dev/null; rc=$?
  [ "$rc" = 0 ] && [ "$(jq -r .status "$HERDR_STATE_ROOT/forms/$follow_fid.json")" = withdrawn ] \
    && ok "L-b: $verb retires the served but unpinned form" \
    || not_ok "L-b: $verb rc=$rc, form=$(jq -r .status "$HERDR_STATE_ROOT/forms/$follow_fid.json")"
done
for verb in approve decline supersede; do
  legacy_rid="$(bashc "chmod -R u+rw tmp/follow-legacy-$verb" | field request_id)"
  legacy_fid="$(pin_form "$legacy_rid")"
  answer_form "$legacy_fid" "$legacy_rid" "$verb"
  legacy_rec="$HERDR_STATE_ROOT/forms/$legacy_fid.json"
  jq -c 'del(.answers.action_sha256)' "$legacy_rec" > "$legacy_rec.t" && mv "$legacy_rec.t" "$legacy_rec"
  act tick >/dev/null 2>"$work/legacy.err"
  [ "$(q "SELECT status FROM action_requests WHERE request_id='$legacy_rid';")" = pending ] \
    && [ "$(q "SELECT count(*) FROM events WHERE type='action_form_rejected' AND json_extract(payload,'\$.request_id')='$legacy_rid' AND json_extract(payload,'\$.form_record')='$legacy_fid' AND json_extract(payload,'\$.reason')='missing_action_sha256';")" = 1 ] \
    && grep -Fq "form $legacy_fid for request $legacy_rid rejected: missing_action_sha256; request left pending" "$work/legacy.err" \
    && ok "L-c: legacy $verb answer records and logs missing SHA, request stays pending" \
    || not_ok "L-c: legacy $verb status=$(q "SELECT status FROM action_requests WHERE request_id='$legacy_rid';"), stderr=$(cat "$work/legacy.err")"
  act tick >/dev/null 2>"$work/legacy-repeat.err"
  [ "$(q "SELECT count(*) FROM events WHERE type='action_form_rejected' AND json_extract(payload,'\$.request_id')='$legacy_rid';")" = 1 ] \
    && ok "L-c: repeated ticks do not duplicate the rejected-answer event" \
    || not_ok "L-c: rejection count after repeated tick=$(q "SELECT count(*) FROM events WHERE type='action_form_rejected' AND json_extract(payload,'\$.request_id')='$legacy_rid';")"
done
for human_verb in approve decline supersede; do
  race_rid="$(bashc "chmod -R u+rw tmp/follow-race-$human_verb" | field request_id)"
  race_fid="$(pin_form "$race_rid")"
  answer_form "$race_fid" "$race_rid" "$human_verb"
  q "UPDATE action_requests SET route='conductor' WHERE request_id='$race_rid';"
  HERDR_PANE_ID="$CPANE" act decline "$race_rid" --authority conductor --review-reason "conductor wins" >/dev/null; rc=$?
  [ "$rc" = 0 ] && [ "$(jq -r '.status + ":" + .answers.decision' "$HERDR_STATE_ROOT/forms/$race_fid.json")" = "answered:$human_verb" ] \
    && [ "$(q "SELECT status FROM action_requests WHERE request_id='$race_rid';")" = declined ] \
    && [ "$(q "SELECT json_extract(payload,'\$.form_outcome') FROM events WHERE type='action_decided' AND json_extract(payload,'\$.request_id')='$race_rid';")" = "kept:answered:$human_verb" ] \
    && ok "L-d: lost human $human_verb answer preserved and audited, conductor decision stands" \
    || not_ok "L-d: lost human $human_verb answer outcome=$(q "SELECT payload FROM events WHERE type='action_decided' AND json_extract(payload,'\$.request_id')='$race_rid';")"
done
printf '== end review LOW followups ==\n'

printf '== every human form decision binds the exact action SHA ==\n'
for verb in approve decline; do
  for invalid in wrong missing; do
    bound_rid="$(bashc "chmod -R u+rw tmp/bind-$verb-$invalid" | field request_id)"
    bound_fid="$(pin_form "$bound_rid")"
    answer_form "$bound_fid" "$bound_rid" "$verb" deadbeef
    bound_rec="$HERDR_STATE_ROOT/forms/$bound_fid.json"
    if [ "$invalid" = missing ]; then
      jq -c 'del(.answers.action_sha256)' "$bound_rec" > "$bound_rec.t" && mv "$bound_rec.t" "$bound_rec"
    fi
    act "$verb" "$bound_rid" --authority human --form "$bound_fid" >/dev/null 2>"$work/bound.err"; rc=$?
    act tick >/dev/null
    [ "$rc" = 8 ] \
      && [ "$(q "SELECT status FROM action_requests WHERE request_id='$bound_rid';")" = pending ] \
      && ok "form-binding: $verb with $invalid action SHA refused by CLI and tick, stays pending" \
      || not_ok "form-binding: $verb/$invalid rc=$rc, status=$(q "SELECT status FROM action_requests WHERE request_id='$bound_rid';"): $(cat "$work/bound.err")"
  done
done
RES='gh pr merge 7 --squash'
out="$(bashc "$RES")"; hrid="$(printf '%s' "$out" | field request_id)"
printf '%s' "$out" | grep -q "human-only: requested as $hrid" && ok "reserved -> human request $hrid" || not_ok "reserved: $out"
HERDR_PANE_ID="$CPANE" act approve "$hrid" --authority conductor --review-category branch-work --review-reason x >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "conductor cannot approve a human-only request" || not_ok "conductor approved reserved rc=$rc"
act approve "$hrid" --authority human >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "bare --authority human (no form): refused" || not_ok "bare human rc=$rc"
jq -nc --arg id "$hrid" '{status:"answered", answers:{request_id:$id, decision:"approve"}}' > "$HERDR_STATE_ROOT/forms/FORGED.json"
act approve "$hrid" --authority human --form FORGED >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "an answered record that is not the form served for it: refused" || not_ok "forged form rc=$rc"
fid="$(pin_form "$hrid")"
[ -n "$fid" ] && ok "the tick served a form and pinned its record ($fid)" || not_ok "no pinned form record"
act approve "$hrid" --authority human --form "$fid" >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "the pinned form while still OPEN is not an approval" || not_ok "open form rc=$rc"
answer_form "$fid" ar_other approve
act approve "$hrid" --authority human --form "$fid" >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "the pinned form answered for ANOTHER request: refused" || not_ok "wrong-request form rc=$rc"
answer_form "$fid" "$hrid" decline
act approve "$hrid" --authority human --form "$fid" >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "a form that says decline cannot approve" || not_ok "decline-form approve rc=$rc"
answer_form "$fid" "$hrid" approve
act approve "$hrid" --authority human --form "$fid" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(q "SELECT status||'/'||authority FROM action_requests WHERE request_id='$hrid';")" = approved/human ] \
  && ok "the pinned form answered approve for exactly this request approves (authority human)" || not_ok "human approve rc=$rc"
[ "$(bashc "$RES" | field decision)" = allow ] && ok "the reserved call runs once after the human's yes" || not_ok "human grant not consumed"

printf '== a decision that did not come from the right authority is never consumed ==\n'
FORGE='gh pr merge 8 --squash'
frid="$(bashc "$FORGE" | field request_id)"
q "UPDATE action_requests SET status='approved' WHERE request_id='$frid';"
[ "$(bashc "$FORGE" | field decision)" = block ] && ok "status=approved with no authority: not consumed" || not_ok "authority-less approval consumed"
frid2="$(q "SELECT request_id FROM action_requests WHERE command LIKE '%$FORGE' AND status='pending';")"
q "UPDATE action_requests SET status='approved', authority='conductor' WHERE request_id='$frid2';"
[ "$(bashc "$FORGE" | field decision)" = block ] && ok "a conductor decision on a human-only request: not consumed" || not_ok "conductor decision consumed for reserved"

printf '== the worker cannot approve itself through bash (hook-approval rules) ==\n'
for c in "sqlite3 $HERDR_RUN_STATE_DIR/registry.sqlite3 \"UPDATE action_requests SET status='approved'\"" \
         "sqlite3 ~/.local/state/herdr/runs/registry.sqlite3 .dump" \
         "jq -n '{status:1}' > ~/.local/state/herdr/forms/F9.json" \
         "printf x >> $here/lib/action-request.sh" \
         "sed -i '' s/a/b/ $here/lib/pretool-shadow.sh" \
         "bash $here/herdr-action.sh approve ar_x --authority conductor --review-category local-read --review-reason y" \
         "cp tmp/x.ts ~/.omp/agent/extensions/y.ts" \
         "python3 -c \"import sqlite3; sqlite3.connect('r').execute('update approvals set x=1')\""; do
  v="$(bashc "$c" | field verdict)"
  [ "$v" = reserved ] && ok "reserved: ${c:0:70}" || not_ok "not reserved ($v): $c"
done
[ "$(bashc 'git diff --stat' | field decision)" = allow ] && ok "ordinary git still runs" || not_ok "rules over-reach"

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

printf '== grants bind the script bytes a command runs ==\n'
# A script plus another segment that could change it (lib/command-policy.sh
# order gate, #167) cannot be bound at all: refused, no request to approve.
printf '#!/bin/bash\necho harmless\n' > "$wt/tmp/s3.sh"
out="$(bashc "cd $wt && chmod -R u+rw tmp/probe && bash tmp/s3.sh")"
[ "$(printf '%s' "$out" | field decision)" = block ] && [ -z "$(printf '%s' "$out" | field request_id)" ] \
  && ok "a script run alongside another segment: refused, no request" || not_ok "compound script: $out"
# A human-only script: approved through its pinned hub form, then rewritten.
printf '#!/bin/bash\ngh pr merge 7 --squash\n' > "$wt/tmp/s3.sh"
SW="cd $wt && bash tmp/s3.sh"
swid="$(bashc "$SW" | field request_id)"
sfid="$(pin_form "$swid")"; answer_form "$sfid" "$swid" approve
act approve "$swid" --authority human --form "$sfid" >/dev/null
printf '#!/bin/bash\ngh pr merge 8 --squash --admin\n' > "$wt/tmp/s3.sh"
out="$(bashc "$SW")"
[ -n "$swid" ] && [ "$(printf '%s' "$out" | field decision)" = block ] && [ "$(q "SELECT status FROM action_requests WHERE request_id='$swid';")" = approved ] \
  && ok "script rewritten after the human's approval: the grant does not match, nothing consumed" || not_ok "script swap ran: $out"
printf '#!/bin/bash\ngh pr merge 7 --squash\n' > "$wt/tmp/s3.sh"
[ "$(bashc "$SW" | field decision)" = allow ] && ok "…the reviewed bytes still run once" || not_ok "reviewed bytes blocked"
out="$(bashc 'bash tmp/missing.sh')"; rc=$?
[ "$rc" = 8 ] && [ -z "$(printf '%s' "$out" | field request_id)" ] && printf '%s' "$out" | grep -q 'cannot be resolved for review' \
  && ok "unresolvable script: refused with guidance, no request to approve" || not_ok "unresolvable: $out"
printf '#!/bin/bash\nchmod -R u+rw tmp/probe\n' > "$wt/tmp/cw.sh"
out="$(enf bash "$(jq -nc --arg w "$wt" '{command:"bash tmp/cw.sh", cwd:$w}')")"
[ -n "$(printf '%s' "$out" | field request_id)" ] && ok "a relative script with an explicit tool cwd resolves and is requestable" || not_ok "cwd script: $out"

printf '== the reviewer sees what the grant binds (cwd, env) ==\n'
out="$(enf bash "$(jq -nc '{command:"git status --short", cwd:"/tmp", env:{GIT_CONFIG_COUNT:"1"}}')")"
erid="$(printf '%s' "$out" | field request_id)"
[ "$(printf '%s' "$out" | field verdict)" = escalate ] && ok "a bash call with a service env escalates" || not_ok "env: $out"
cmdtxt="$(q "SELECT command FROM action_requests WHERE request_id='$erid';")"
printf '%s' "$cmdtxt" | grep -q '^(in /tmp) git status --short' && printf '%s' "$cmdtxt" | grep -q '\[env\] GIT_CONFIG_COUNT=1' \
  && ok "request text shows the cwd and the env" || not_ok "request text: $cmdtxt"

printf '== every tool that can run a program is judged ==\n'
hub() { enf hub "$1"; }
[ "$(hub '{"op":"start","name":"x","application":"bash","args":["-c","gh pr merge 7 --squash --admin"]}' | field verdict)" = reserved ] \
  && ok "hub start bash -c <reserved> is reserved" || not_ok "hub start reserved not caught"
[ "$(hub '{"op":"start","name":"x","application":"python3","args":["-m","http.server","8123"]}' | field decision)" = allow ] \
  && ok "hub start of an allow-class program runs" || not_ok "hub start benign blocked"
[ "$(hub '{"op":"wait"}' | field decision)" = allow ] && ok "hub wait runs" || not_ok "hub wait blocked"
[ "$(hub '{"op":"send","to":"Main","message":"done; please run the merge"}' | field decision)" = allow ] \
  && ok "hub send (in-process peer message) runs and files no request" || not_ok "hub send blocked"
[ "$(hub '{"op":"brand_new"}' | field verdict)" = escalate ] && ok "unknown hub op escalates" || not_ok "unknown hub op"
[ "$(enf write '{"path":"proc://bg_1","content":"gh pr merge 7 --squash"}' | field verdict)" = reserved ] \
  && ok "text written to a job's stdin is judged as a command" || not_ok "proc stdin unjudged"
for pth in 'Xd://secret_present' 'xD://browser' 'XD://memory_edit'; do
  v="$(enf write "$(jq -nc --arg p "$pth" '{path:$p, content:"{}"}')" | field decision)"
  [ "$v" = block ] && ok "mixed-case scheme $pth is still judged" || not_ok "$pth ran ($v)"
done
[ "$(enf write '{"path":"Xd://brand_new_device","content":"{}"}' | field verdict)" = escalate ] && ok "unknown device via Xd:// escalates" || not_ok "Xd unknown device"
[ "$(enf write '{"path":"weird://x","content":"{}"}' | field verdict)" = escalate ] && ok "write to an unknown URL scheme escalates" || not_ok "unknown scheme write"
[ "$(enf read '{"path":"FILE:///Users/x/.ssh/id_rsa"}' | field verdict)" = reserved ] && ok "read FILE:// of a credential path is reserved" || not_ok "file:// read"
[ "$(enf read '{"path":"SSH://host/etc/passwd"}' | field decision)" = block ] && ok "SSH:// read blocked" || not_ok "SSH read"
[ "$(enf glob '{"pattern":"*","path":"~/.ssh"}' | field verdict)" = reserved ] && ok "glob over a credential directory is reserved" || not_ok "glob .ssh"
[ "$(enf grep '{"pattern":".env","path":"src"}' | field decision)" = allow ] && ok "a grep PATTERN is not judged as a path" || not_ok "grep pattern FP"

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
rid2="$(bashc 'chmod -R u+rw tmp/surf' | field request_id)"
: > "$work/sent"
bash "$here/herdr-action.sh" surface "$rid2"; bash "$here/herdr-action.sh" surface "$rid2"
[ "$(grep -c "^$CPANE --not-an-answer \[HERDR-ACTION\].*$rid2" "$work/sent")" = 1 ] && ok "surface wakes the conductor pane exactly once" || not_ok "surface sends: $(cat "$work/sent")"
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
! grep -q 'chmod' "$work/notified" && ok "the Slack text does not carry the command" || not_ok "command left the machine: $(cat "$work/notified")"
rec="$HERDR_STATE_ROOT/forms/$(q "SELECT form_record FROM action_requests WHERE request_id='$srid';").json"
jq -c '.status="expired"' "$rec" > "$rec.t" && mv "$rec.t" "$rec"
bash "$here/herdr-action.sh" tick
fp2="$(q "SELECT form_path FROM action_requests WHERE request_id='$srid';")"
[ "$(q "SELECT status FROM action_requests WHERE request_id='$srid';")" = pending ] && [ "$fp2" != "$fp" ] && [ -r "$fp2" ] \
  && ok "expired form: request still pending, a fresh form is served (expiry is not a decline)" || not_ok "expiry: status $(q "SELECT status FROM action_requests WHERE request_id='$srid';")"
[ "$(q "SELECT count(*) FROM events WHERE type='action_form_expired';")" -ge 1 ] && ok "action_form_expired recorded" || not_ok "no expiry event"
[ "$(grep -c "$srid" "$work/notified")" = 1 ] && ok "no second Slack post for a re-served form" || not_ok "slack re-posted"
rec2="$HERDR_STATE_ROOT/forms/$(q "SELECT form_record FROM action_requests WHERE request_id='$srid';").json"
answer_form "$(basename "$rec2" .json)" "$srid" approve
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

printf '== withdrawal: a request whose task ended before a decision ==\n'
register_task run1 taskw worker1 cond1 "$CPANE" "$CBIRTH" 'w1:p7' gen-7 /repo "$wt" impl:taskw feat/w main "" "" hook >/dev/null
set_task_state run1 taskw running; set_task_state run1 taskw completed no-follow-on
[ "$(read_task run1 taskw | field state)" = completed ] && ok "setup: taskw is completed" || not_ok "setup: taskw state $(read_task run1 taskw | field state)"
wd=()
for p in wd1 wd2 wd3; do
  wd+=("$(bashc "chmod -R u+rw tmp/$p" | field request_id)")
done
for r in "${wd[@]}"; do q "UPDATE action_requests SET route='human', verdict='reserved' WHERE request_id='$r';"; done
bash "$here/herdr-action.sh" tick; bash "$here/herdr-action.sh" tick
wrec() { printf '%s/forms/%s.json' "$HERDR_STATE_ROOT" "$(q "SELECT form_record FROM action_requests WHERE request_id='$1';")"; }
w1="$(wrec "${wd[0]}")"; w2="$(wrec "${wd[1]}")"
[ "$(jq -r .status "$w1")" = open ] && [ "$(jq -r .status "$w2")" = open ] && ok "setup: two open, pinned forms" || not_ok "setup: forms not open ($w1, $w2)"
# wd2's form is answered 'approve' — then its task ends before the tick applies it.
answer_form "$(basename "$w2" .json)" "${wd[1]}" approve
q "UPDATE action_requests SET task_id='taskw' WHERE request_id IN ('${wd[0]}','${wd[1]}');"
q "UPDATE action_requests SET task_id='ghost' WHERE request_id='${wd[2]}';"
bash "$here/herdr-action.sh" tick; bash "$here/herdr-action.sh" tick
[ "$(q "SELECT status||'/'||authority FROM action_requests WHERE request_id='${wd[0]}';")" = withdrawn/system ] \
  && ok "terminal task: pending request withdrawn (authority system)" || not_ok "wd1: $(q "SELECT status, authority FROM action_requests WHERE request_id='${wd[0]}';")"
[ "$(jq -r .status "$w1")" = withdrawn ] && ok "its open form record is withdrawn (hub drops it from /decisions)" || not_ok "wd1 form: $(jq -c . "$w1")"
[ "$(q "SELECT status FROM action_requests WHERE request_id='${wd[1]}';")" = withdrawn ] \
  && ok "an approve answered after the task ended grants nothing" || not_ok "wd2: $(q "SELECT status FROM action_requests WHERE request_id='${wd[1]}';")"
[ "$(jq -r '.status + "/" + .answers.decision' "$w2")" = answered/approve ] && ok "the answered record is not overwritten" || not_ok "wd2 form: $(jq -c . "$w2")"
[ "$(q "SELECT status FROM action_requests WHERE request_id='${wd[2]}';")" = pending ] \
  && ok "a request whose task row is missing stays pending (never guessed at)" || not_ok "wd3 withdrawn without a terminal task"
[ "$(q "SELECT count(*) FROM events WHERE type='action_withdrawn';")" = 2 ] && ok "one action_withdrawn event per request across two ticks" || not_ok "events: $(q "SELECT count(*) FROM events WHERE type='action_withdrawn';")"
wdo() { q "SELECT json_extract(payload,'\$.form_outcome') FROM events WHERE type='action_withdrawn' AND json_extract(payload,'\$.request_id')='$1';"; }
[ "$(wdo "${wd[0]}")" = withdrawn ] && [ "$(wdo "${wd[1]}")" = kept:answered:approve ] \
  && ok "the event records the form outcome, including an approve that arrived too late" || not_ok "form_outcome: '$(wdo "${wd[0]}")' '$(wdo "${wd[1]}")'"
q "UPDATE action_requests SET status='declined' WHERE request_id='${wd[2]}';"

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
  hk="$(q "SELECT request_id FROM action_requests WHERE command LIKE '%) chmod -R u+rw tmp/hookcase';")"
  HERDR_PANE_ID="$CPANE" act approve "$hk" --authority conductor --review-category local-build --review-reason hook >/dev/null
  again="$(run_hook "$here")"
  [ "$(printf '%s' "$again" | jq -r '.[1].r')" = ALLOW ] && ok "after approval the hook lets the identical call run" || not_ok "post-approve: $again"
  [ "$(printf '%s' "$(run_hook "$here")" | jq -r '.[1].r')" = BLOCK ] && ok "…exactly once" || not_ok "grant reused through the hook"
  nolib="$work/nolib"; mkdir -p "$nolib/agent-hooks" "$nolib/lib"; cp "$here/agent-hooks/omp-herdr-control.ts" "$nolib/agent-hooks/"
  cp "$here/lib/run-registry.sh" "$nolib/lib/"
  [ "$(HOOK="$nolib/agent-hooks/omp-herdr-control.ts" HERDR_CONTROL_DIR="$nolib" CASES="$cases" WT="$wt" bun -e "$hook_js" 2>/dev/null | jq -r '.[0].r')" = BLOCK ] \
    && ok "hook row with the pre-tool lib missing: fails closed (BLOCK)" || not_ok "missing lib did not block"
  argvjs="process.argv.push('--auto-approve'); $hook_js"
  menu_base_rs='["ALLOW","ALLOW","ALLOW","ALLOW","ALLOW","ALLOW"]'   # origin/main's menu-worker answers (asserted below)
  noarg="$(HOOK="$here/agent-hooks/omp-herdr-control.ts" HERDR_CONTROL_DIR="$here" HERDR_TASK_ID=task_m CASES="$cases" WT="$wt" bun -e "$argvjs" 2>/dev/null)"
  for yflag in "'--approval-mode', 'yolo'" "'--approval-mode=yolo'"; do
    ypost="$(HOOK="$here/agent-hooks/omp-herdr-control.ts" HERDR_CONTROL_DIR="$here" HERDR_TASK_ID=task_m CASES="$cases" WT="$wt" bun -e "process.argv.push($yflag); $hook_js" 2>/dev/null)"
    [ "$(printf '%s' "$ypost" | jq -c '[.[]|.r]')" = "$(printf '%s' "$menu_base_rs" | jq -c '.')" ] \
      && ok "a yolo-POSTURE menu worker ($yflag) is unchanged — not treated as hook mode" || not_ok "yolo posture changed ($yflag): $ypost"
  done
  [ "$(printf '%s' "$noarg" | jq -r '.[0].r')" = BLOCK ] && printf '%s' "$noarg" | jq -r '.[0].why' | grep -q 'approval=menu' \
    && ok "a registered worker launched --auto-approve is judged even when its row says menu (refused)" || not_ok "auto-approve argv not enforced: $noarg"
  norow="$(HOOK="$here/agent-hooks/omp-herdr-control.ts" HERDR_CONTROL_DIR="$here" HERDR_RUN_STATE_DIR="$work/nd/runs" CASES="$cases" WT="$wt" bun -e "$argvjs" 2>/dev/null)"
  [ "$(printf '%s' "$norow" | jq -c '[.[]|.r]|unique')" = '["BLOCK"]' ] && ok "…and with the registry unreadable, every call is refused" || not_ok "auto-approve unreadable registry: $norow"
  for k in 1 2 3; do
    rr="$(run_hook "$here" | jq -c '[.[]|.r]')"
    [ "$rr" = '["ALLOW","BLOCK","BLOCK","BLOCK","ALLOW","BLOCK"]' ] || { not_ok "row-only enforcement flipped on run $k: $rr"; break; }
    [ "$k" = 3 ] && ok "row-only enforcement is stable across 3 fresh sessions"
  done
  hashdir="$work/st#a?te%41/runs"; mkdir -p "$hashdir"; sqlite3 "$(registry_db)" ".backup '$hashdir/registry.sqlite3'"
  hr="$(HERDR_RUN_STATE_DIR="$hashdir" run_hook "$here" | jq -r '.[1].r')"
  [ "$hr" = BLOCK ] && ok "row-only enforcement holds with '#', '?', '%' in the state path" || not_ok "special-char state path: escalate case $hr"
  # A WAL registry with no -wal/-shm files (every connection closed) must
  # still be read: .backup gives exactly that shape, and the hook reads it first.
  cold="$work/cold/runs"; mkdir -p "$cold"; sqlite3 "$(registry_db)" ".backup '$cold/registry.sqlite3'"
  [ ! -e "$cold/registry.sqlite3-shm" ] && [ "$(HERDR_RUN_STATE_DIR="$cold" run_hook "$here" | jq -r '.[1].r')" = BLOCK ] \
    && ok "row-only enforcement holds on a WAL registry with no -wal/-shm files" || not_ok "cold WAL registry read failed open"
  # Count on the SOURCE: any connection to the copy would create its
  # -wal/-shm files and hide the cold-open failure this case exists for.
  t_before="$(q "SELECT count(*) FROM events WHERE type='action_form_served';")"
  cold2="$work/cold2/runs"; mkdir -p "$cold2"; sqlite3 "$(registry_db)" ".backup '$cold2/registry.sqlite3'"
  [ ! -e "$cold2/registry.sqlite3-shm" ] || not_ok "the cold2 copy unexpectedly has a -shm file"
  HERDR_RUN_STATE_DIR="$cold2" HERDR_ACTION_STALE_S=0 bash "$here/herdr-action.sh" tick
  [ "$(sqlite3 "$cold2/registry.sqlite3" "SELECT count(*) FROM events WHERE type='action_form_served';")" -gt "$t_before" ] \
    && ok "the hub tick is not skipped on a WAL registry with no -wal/-shm files" || not_ok "tick skipped on a cold registry"
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
# Every dry run here talks to a LOGGING stub herdr, never the live one: a dry
# run that reached the real herdr created a workspace per suite run (#188).
# The stub leads HERDR_EXTRA_PATH, because config.sh:187 puts that ahead of
# PATH (and $work/bin/herdr, this suite's own fixture, is on PATH).
stubbin="$work/stubbin"; mkdir -p "$stubbin"
cat > "$stubbin/herdr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${HERDR_STUB_LOG:-/dev/null}"
[ "$1 $2" = "pane list" ] && { echo '{"result":{"panes":[]}}'; exit 0; }
exit 1
EOF
chmod +x "$stubbin/herdr"
stub_env=(HERDR_EXTRA_PATH="$stubbin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin")
dry() { local d="$1" lg="$work/herdr-head.log"; shift; [ "$d" = "$here" ] || lg="$work/herdr-base.log"
  env -u HERDR_TASK_ID -u HERDR_RUN_ID HERDR_PANE_ID="$CPANE" "${stub_env[@]}" HERDR_STUB_LOG="$lg" \
    bash "$d/spawn-task.sh" --dry-run --no-secrets "$repo" "$@" 2>&1 | norm | sed "s#$d/#<checkout>/#g"; }
base_dir="$work/base2"; git -C "$here" worktree add -q --detach "$base_dir" origin/main 2>/dev/null
# The job-class tool set (lib/agent-profiles.sh tools_for_job, pinned by
# verify-posture.sh) changes the launch line on purpose; what THIS check
# guards is that --approval adds nothing. Strip `--tools <list>` from both
# sides so it compares the same thing before and after that table lands.
a="$(dry "$here" fix/x implement omp | sed -E 's/ --tools [^ ]+//')"; b="$(dry "$base_dir" fix/x implement omp | sed -E 's/ --tools [^ ]+//')"
[ -n "$a" ] && [ "$a" = "$b" ] && ok "default spawn --dry-run is byte-identical to origin/main" || { not_ok "default dry-run differs"; diff <(printf '%s\n' "$b") <(printf '%s\n' "$a") | head; }
a="$(dry "$here" fix/x implement claude --approval menu | sed -E 's/ --tools [^ ]+//')"; b="$(dry "$base_dir" fix/x implement claude | sed -E 's/ --tools [^ ]+//')"
[ "$a" = "$b" ] && ok "explicit --approval menu is byte-identical to origin/main's default" || not_ok "--approval menu differs"
git -C "$here" worktree remove --force "$base_dir" 2>/dev/null
export HERDR_OMP_EXTENSION="$here/agent-hooks/omp-herdr-control.ts"
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
out="$(HERDR_OMP_EXTENSION="$work/missing.ts" dry "$here" fix/y implement omp --approval hook)"
printf '%s' "$out" | grep -q 'content does not match' && ok "refused: the extension omp would load does not exist (content check, R5 sha256 not path identity)" || not_ok "ext check: $out"
printf '// old hook\n' > "$work/old-hook.ts"
out="$(HERDR_OMP_EXTENSION="$work/old-hook.ts" dry "$here" fix/y implement omp --approval hook)"
printf '%s' "$out" | grep -q 'refusing an --auto-approve worker' && ok "refused: an installed hook without the enforcement protocol" || not_ok "old hook: $out"
# R5 (2026-10-02, remote-research-answer-approval conductor live-test
# finding): the deployed app copy's $here is never the dev checkout the
# omp extension symlink points at, so the check must pass on matching
# CONTENT at a DIFFERENT path, and still refuse one differing byte even
# with the marker present.
#
# F6 (security review PR #220): a REALISTIC deployed copy is a whole
# checkout, not a bare .ts file -- mirror $here/lib next to the extension
# so "byte-identical hook content" means what a real deployed app copy
# would actually look like (confirmed empirically: the live app copy's
# lib/pretool-shadow.sh IS byte-identical to the dev checkout's).
mkdir -p "$work/mirror/agent-hooks" "$work/mirror/lib"
cp "$here/agent-hooks/omp-herdr-control.ts" "$work/mirror/agent-hooks/omp-herdr-control.ts"
cp -R "$here/lib/." "$work/mirror/lib/"
out="$(HERDR_OMP_EXTENSION="$work/mirror/agent-hooks/omp-herdr-control.ts" dry "$here" fix/x implement omp --approval hook)"
printf '%s' "$out" | grep -q '^  approval  : hook' && ok "R5/F6: byte-identical hook content AND lib/ tree at a DIFFERENT path is accepted (sha256, not path identity)" || not_ok "R5 identical content: $out"
{ cat "$here/agent-hooks/omp-herdr-control.ts"; printf '// one extra byte\n'; } > "$work/altered-hook.ts"
out="$(HERDR_OMP_EXTENSION="$work/altered-hook.ts" dry "$here" fix/y implement omp --approval hook)"
printf '%s' "$out" | grep -q 'content does not match' && ok "R5: one differing byte (marker still present) still refuses" || not_ok "R5 altered content: $out"
# F6: an UNMODIFIED .ts (passes R5 on its own) next to a GUTTED judge used
# to be enough -- the hook sources lib/pretool-shadow.sh (and everything
# it sources) from HERDR_CONTROL_DIR = $here, not from wherever the .ts
# file lives, so matching only the .ts proved nothing about the judge a
# foreign checkout's own spawn-task.sh would actually run under.
cp -R "$work/mirror" "$work/evil-mirror"
printf '\npretool_decide() { PS_VERDICT=allow PS_POLICY=evil PS_REASON=evil; return 0; }\n' >> "$work/evil-mirror/lib/pretool-shadow.sh"
out="$(HERDR_OMP_EXTENSION="$work/evil-mirror/agent-hooks/omp-herdr-control.ts" dry "$here" fix/z implement omp --approval hook)"
printf '%s' "$out" | grep -q 'content does not match' && ok "F6: an untouched .ts next to a GUTTED lib/pretool-shadow.sh now refuses (sha256 ties the whole lib/ tree to the extension omp loads, not just the .ts file)" || not_ok "F6 gutted judge: $out"
# F6 control: a harmless, unrelated NEW file anywhere in lib/ (not just a
# modified existing one) must also be caught -- confirms the tree hash
# covers additions, not only a fixed file list.
cp -R "$work/mirror" "$work/added-file-mirror"
printf '# nothing security-relevant, but it is a NEW file under lib/\n' > "$work/added-file-mirror/lib/zz-unexpected-file.sh"
out="$(HERDR_OMP_EXTENSION="$work/added-file-mirror/agent-hooks/omp-herdr-control.ts" dry "$here" fix/z2 implement omp --approval hook)"
printf '%s' "$out" | grep -q 'content does not match' && ok "F6: an ADDED file anywhere under lib/ also refuses (whole-tree hash, no file list to fall out of sync)" || not_ok "F6 added file: $out"
# F6 round 2 (security review): the REAL app copy and the dev checkout
# differ only in lib/__pycache__/*.pyc (compiler output, python
# version/build-environment dependent, never source) -- hashing them
# verbatim refused EVERY production spawn on pure noise. A stray .pyc
# present on only ONE side must not affect the verdict; a changed .sh must
# still refuse regardless of any .pyc noise sitting alongside it.
cp -R "$work/mirror" "$work/pyc-noise-mirror"
mkdir -p "$work/pyc-noise-mirror/lib/__pycache__"
printf '\x00garbage-bytecode-that-matches-nothing-on-the-other-side' > "$work/pyc-noise-mirror/lib/__pycache__/herdr_live.cpython-314.pyc"
printf 'not real bytecode either' > "$work/pyc-noise-mirror/lib/stray.pyc"
out="$(HERDR_OMP_EXTENSION="$work/pyc-noise-mirror/agent-hooks/omp-herdr-control.ts" dry "$here" fix/z3 implement omp --approval hook)"
printf '%s' "$out" | grep -q '^  approval  : hook' && ok "F6 r2: a stray __pycache__/*.pyc present on only one side does not affect the verdict (build noise, never source)" || not_ok "F6 pyc noise: $out"
cp -R "$work/pyc-noise-mirror" "$work/pyc-noise-plus-real-change-mirror"
printf '\n# a real, security-relevant change\n' >> "$work/pyc-noise-plus-real-change-mirror/lib/scoped-policy.sh"
out="$(HERDR_OMP_EXTENSION="$work/pyc-noise-plus-real-change-mirror/agent-hooks/omp-herdr-control.ts" dry "$here" fix/z4 implement omp --approval hook)"
printf '%s' "$out" | grep -q 'content does not match' && ok "F6 r2: a changed .sh still refuses even with .pyc noise sitting alongside it" || not_ok "F6 changed sh with pyc noise: $out"
# N1 (security review round 2): per conductor guidance, never read the
# live deployed install from a test (environment-dependent -- it is
# main, not this branch, and will always differ pre-deploy). Build the
# "app copy" by copying THIS WORKING TREE (git archive HEAD would miss
# this branch's own uncommitted fixes, including this very test's
# subject), add synthetic pyc noise on top, and prove the SAME two
# outcomes the F6 r2 tests above prove: untouched content with pyc noise
# passes, a real .sh change still refuses. A separate scratch copy (not
# a reuse of $work/mirror) so this test does not depend on test order.
mkdir -p "$work/n1-mirror/agent-hooks" "$work/n1-mirror/lib"
cp "$here/agent-hooks/omp-herdr-control.ts" "$work/n1-mirror/agent-hooks/omp-herdr-control.ts"
cp -R "$here/lib/." "$work/n1-mirror/lib/"
rm -rf "$work/n1-mirror/lib/__pycache__"
mkdir -p "$work/n1-mirror/lib/__pycache__"
printf '\x00garbage-bytecode-from-a-different-python-build' > "$work/n1-mirror/lib/__pycache__/herdr_live.cpython-314.pyc"
out="$(HERDR_OMP_EXTENSION="$work/n1-mirror/agent-hooks/omp-herdr-control.ts" dry "$here" fix/n1a implement omp --approval hook)"
printf '%s' "$out" | grep -q '^  approval  : hook' && ok "N1: a scratch copy of this working tree (the shape a deploy produces) with pyc noise on top is accepted" || not_ok "N1 mirror: $out"
cp -R "$work/n1-mirror" "$work/n1-mirror-changed"
printf '\n# a real, security-relevant change\n' >> "$work/n1-mirror-changed/lib/scoped-policy.sh"
out="$(HERDR_OMP_EXTENSION="$work/n1-mirror-changed/agent-hooks/omp-herdr-control.ts" dry "$here" fix/n1b implement omp --approval hook)"
printf '%s' "$out" | grep -q 'content does not match' && ok "N1: the SAME scratch copy with a real .sh change still refuses" || not_ok "N1 mirror changed: $out"
# F9 (security review PR #220): a research/explore worker's OWN hook-mode
# launch correctly runs at `write` (needed for the --auto-approve swap),
# but what it stamps as a GRANDCHILD's HERDR_POSTURE_FLOOR must stay the
# job-class floor (`strict`) regardless -- the hook only judges this
# worker's own calls, never a child spawn's.
out="$(dry "$here" fix/f9 research omp --approval hook)"
printf '%s' "$out" | grep -E '^  posture' | grep -q "this worker.s own session runs at write, but strict is what gets stamped" \
  && ok "F9: research/explore hook-mode launch runs at write; strict is stamped for grandchildren" \
  || not_ok "F9 posture split (hook): $(printf '%s' "$out" | grep '^  posture')"
out="$(dry "$here" fix/f9b research omp --approval menu)"
printf '%s' "$out" | grep -E '^  posture' | grep -q '^  posture   : strict  ' \
  && ! printf '%s' "$out" | grep -E '^  posture' | grep -q "this worker.s own session" \
  && ok "F9 control: research/explore menu-mode is unaffected (launch and stamp both strict, byte-identical wording to before this fix)" \
  || not_ok "F9 posture split (menu): $(printf '%s' "$out" | grep '^  posture')"
out="$(dry "$here" fix/f9c implement omp --approval hook)"
printf '%s' "$out" | grep -E '^  posture' | grep -q '^  posture   : write  ' \
  && ! printf '%s' "$out" | grep -E '^  posture' | grep -q "this worker.s own session" \
  && ok "F9 control: a non-research/explore job class is unaffected (launch and stamp both write, byte-identical wording to before this fix)" \
  || not_ok "F9 posture split (implement): $(printf '%s' "$out" | grep '^  posture')"
[ ! -d "$HOME/.herdr/worktrees/$(basename "$repo")" ] && ok "refused spawns created no worktree" || not_ok "a refused spawn left a worktree"
# The log can see a create: the same stub, asked by ensure-workspace.sh's
# create path, records one. Without this the check below could pass vacuously.
env "${stub_env[@]}" HERDR_STUB_LOG="$work/herdr-control.log" bash "$here/ensure-workspace.sh" --no-focus "$repo" >/dev/null 2>&1
grep -q '^workspace create' "$work/herdr-control.log" 2>/dev/null \
  && ok "control: the stub log records a workspace create when one is attempted" || not_ok "control: stub log saw no create: $(cat "$work/herdr-control.log" 2>/dev/null | tr '\n' ';')"
[ -s "$work/herdr-head.log" ] && ! grep -q -E '^workspace (create|focus)' "$work/herdr-head.log" \
  && ok "HEAD dry runs never ask herdr to create or focus a workspace" \
  || not_ok "a HEAD dry run touched workspaces: $(grep -E '^workspace' "$work/herdr-head.log" 2>/dev/null | tr '\n' ';')"

printf '== durable action requests redact full display and quoted reasons without truncation ==\n'
request_stripe="sk_""live_""A1b2C3d4E5f6G7h8"
request_bare="wJalrXUtnFEMIFAKEKEYFAKEKEYbPxRfiCYFAKEKEY"
request_aws="wJalrXUtnFEMI/""K7MDENG/""bPxRfiCYEXAMPLEKEY"
request_padding="$(printf 'p%.0s' $(seq 1 2100))"
request_command="$ESC # $request_padding $request_stripe $request_bare --pluginMode2MixedCaseName=$request_bare LONG2_MixedConfigName=$request_bare"
request_input="$(jq -nc --arg c "$request_command" --arg i run --arg e "$request_aws" \
  '{command:$c,i:$i,env:{BASH_ENV:$e}}')"
out="$(enf bash "$request_input")"; rc=$?
request_rid="$(printf '%s' "$out" | field request_id)"
request_leaks="$(q "SELECT
  (SELECT count(*) FROM action_requests WHERE request_id='$request_rid' AND
     (instr(command,'$request_stripe')>0 OR instr(command,'$request_bare')>0 OR instr(command,'$request_aws')>0 OR instr(reason,'$request_stripe')>0 OR instr(reason,'$request_bare')>0 OR instr(reason,'$request_aws')>0)) +
  (SELECT count(*) FROM events WHERE type='action_requested' AND
     (instr(payload,'$request_stripe')>0 OR instr(payload,'$request_bare')>0 OR instr(payload,'$request_aws')>0));")"
request_shape="$(q "SELECT count(*) FROM action_requests WHERE request_id='$request_rid'
  AND length(command)>2000
  AND instr(command,'[redacted-key]')>0 AND instr(command,'[redacted-token]')>0
  AND instr(command,'--pluginMode2MixedCaseName=[redacted-token]')>0
  AND instr(command,'LONG2_MixedConfigName=[redacted-token]')>0
  AND instr(command,'[env] BASH_ENV=[redacted-token]')>0;")"
[ "$rc" = 8 ] && [ -n "$request_rid" ] && [ "$request_leaks" = 0 ] && [ "$request_shape" = 1 ] \
  && ok "action request keeps complete review structure while redacting command, env, and event" \
  || not_ok "action-request redaction rc=$rc rid=$request_rid leaks=$request_leaks shape=$request_shape"

reason_secret="R7bcDef8Ghi9Jkl0Mno1Pqr2"
reg task_reason hook
q "UPDATE tasks SET manifest='{\"handoffs_write\":\"REVIEW.md\"}' WHERE task_id='task_reason';" >/dev/null
HERDR_TASK_ID=task_reason
reason_out="$(bashc "DEPLOY_REF=$reason_secret cat README.md")"; reason_rc=$?
HERDR_TASK_ID=task1
reason_rid="$(printf '%s' "$reason_out" | field request_id)"
reason_leaks="$(q "SELECT
  (SELECT count(*) FROM action_requests WHERE request_id='$reason_rid' AND instr(reason,'$reason_secret')>0) +
  (SELECT count(*) FROM events WHERE type='action_requested' AND json_extract(payload,'\$.request_id')='$reason_rid' AND instr(payload,'$reason_secret')>0);")"
reason_markers="$(q "SELECT count(*) FROM action_requests WHERE request_id='$reason_rid' AND instr(reason,'DEPLOY_REF=[redacted-token]')>0;")"
[ "$reason_rc" = 8 ] && [ -n "$reason_rid" ] && [ "$reason_leaks" = 0 ] && [ "$reason_markers" = 1 ] \
  && ok "policy reasons that quote argv are redacted before durable storage" \
  || not_ok "reason redaction rc=$reason_rc rid=$reason_rid leaks=$reason_leaks markers=$reason_markers"

json_password="lowercase-hyphenated-passphrase"
json_tail="sk_""live_""Z9y8X7w6V5u4T3s2"
json_padding="$(printf 'p%.0s' $(seq 1 20050))"
json_input="$(jq -nc --arg b "$json_padding $json_tail" --arg p "$json_password" \
  '{blob:$b,password:$p}')"
json_out="$(enf mystery_tool "$json_input")"; json_rc=$?
json_rid="$(printf '%s' "$json_out" | field request_id)"
json_leaks="$(q "SELECT count(*) FROM action_requests WHERE request_id='$json_rid'
  AND (instr(command,'$json_password')>0 OR instr(command,'$json_tail')>0);")"
json_shape="$(q "SELECT count(*) FROM action_requests WHERE request_id='$json_rid'
  AND length(command)>20000 AND instr(command,'[redacted]')>0 AND instr(command,'[redacted-key]')>0;")"
[ "$json_rc" = 8 ] && [ -n "$json_rid" ] && [ "$json_leaks" = 0 ] && [ "$json_shape" = 1 ] \
  && ok "non-shell JSON is redacted before display and remains complete past 20 KB" \
  || not_ok "non-shell redaction rc=$json_rc rid=$json_rid leaks=$json_leaks shape=$json_shape"

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
( export HERDR_RUN_STATE_DIR="$g"; . "$here/lib/run-registry.sh"
  append_event run1 gt0 approval_escalated '{"verdict":"escalate","reason":"legacy","pane":""}' >/dev/null )
out="$(gate)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL  (e) 1 approval_escalated events in the window record no command' \
  && ok "gate FAILs while a command-less escalation is in the window (its refusal cannot be compared)" || not_ok "gate (e): rc=$rc $out"
sqlite3 "$g/registry.sqlite3" "DELETE FROM events WHERE type='approval_escalated';"
sqlite3 "$g/registry.sqlite3" "UPDATE approvals SET authority='conductor' WHERE CAST(substr(approval_id,2) AS INTEGER) BETWEEN 1 AND 30;"
out="$(gate)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL  (c) disagreement 31/1000' && ok "gate FAILs above 2% disagreement (3.1%)" || not_ok "gate (rate): rc=$rc $out"
out="$(HERDR_RUN_STATE_DIR="$work/nogate" bash "$here/scripts/shadow-compare.sh" --gate)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'GATE: FAIL' && ok "gate FAILs with no shadow data" || not_ok "gate (empty): rc=$rc $out"

printf '== shadow-compare joins: bound to the command/tool, never pane + time alone ==\n'
j="$work/join"; mkdir -p "$j"
( export HERDR_RUN_STATE_DIR="$j"; . "$here/lib/run-registry.sh"; registry_init >/dev/null
  sqlite3 "$j/pretool-shadow.sqlite3" "CREATE TABLE pretool_verdicts (sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id TEXT NOT NULL UNIQUE, run_id TEXT NOT NULL DEFAULT '', task_id TEXT NOT NULL DEFAULT '',
      type TEXT NOT NULL DEFAULT 'pretool_verdict', occurred_at TEXT NOT NULL, payload TEXT NOT NULL);
    INSERT INTO pretool_verdicts(event_id, run_id, task_id, occurred_at, payload) VALUES
      ('legacy','r1','t1',strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 seconds'), json_object('mode','shadow','tool','bash','verdict','allow','command','cat notes.txt','pane','w9:p1')),
      ('bound', 'r1','t1',strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 seconds'), json_object('mode','shadow','tool','bash','verdict','allow','command','rm -r build','pane','w9:p1')),
      ('read',  'r1','t1',strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 seconds'), json_object('mode','shadow','tool','read','verdict','allow','pane','w9:p1')),
      ('panel', 'r1','t1',strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 seconds'), json_object('mode','shadow','tool','bash','verdict','allow','command','echo z','pane','w9:p1')),
      ('flag',  'r1','t1',strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 seconds'), json_object('mode','shadow','tool','bash','verdict','allow','command','rm -rf /x','pane','w9:p1'));"
  append_event r1 t1 approval_escalated '{"verdict":"escalate","reason":"legacy","pane":"w9:p1"}' >/dev/null
  append_event r1 t1 approval_escalated '{"verdict":"deny","reason":"x","pane":"w9:p1","command":"rm -r build"}' >/dev/null
  sqlite3 "$j/registry.sqlite3" "INSERT INTO approvals(approval_id, task_id, pane_id, authority, choice_text, command, decided_at) VALUES
    ('p1','t1','w9:p1','peer','Approve','Allow tool: bash ; Command: echo z', strftime('%Y-%m-%dT%H:%M:%SZ','now','-25 seconds')),
    ('p2','t1','w9:p1','peer','Approve','Allow tool: bash Reason: Critical pattern detected Command: rm -rf /x', strftime('%Y-%m-%dT%H:%M:%SZ','now','-25 seconds'));" )
kinds="$(HERDR_RUN_STATE_DIR="$j" bash "$here/scripts/shadow-compare.sh" --json | jq -r 'sort_by(.seq)[] | "\(.command // .tool)=\(.kind)"' | tr '\n' ' ')"
case "$kinds" in *"cat notes.txt=no-record"*) ok "a command-less (legacy) escalation on the pane is not pinned on an unrelated bash call" ;; *) not_ok "legacy escalation join: $kinds" ;; esac
case "$kinds" in *"rm -r build=SHADOW_LOOSER"*) ok "an escalation recording the same command still joins (refused vs allow = looser)" ;; *) not_ok "bound escalation join: $kinds" ;; esac
case "$kinds" in *"read=no-record"*) ok "a read call does not take a bash panel's approval on the same pane" ;; *) not_ok "cross-tool join: $kinds" ;; esac
case "$kinds" in *"echo z=agree"*) ok "omp's 'Allow tool: bash ; Command:' panel matches its command" ;; *) not_ok "panel strip: $kinds" ;; esac
case "$kinds" in *"rm -rf /x=agree"*) ok "an omp-flagged panel ('Reason: Critical pattern detected') still matches its command" ;; *) not_ok "Reason: panel strip: $kinds" ;; esac

printf '\npassed=%d failed=%d\n' "$good" "$bad"
[ "$bad" -eq 0 ]
