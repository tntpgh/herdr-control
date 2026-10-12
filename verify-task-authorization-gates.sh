#!/usr/bin/env bash
# Isolated consumer tests. All panes, process ancestry and notification routes
# are fixtures; this is NOT the permitted live canary/owner-relay acceptance.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d /tmp/herdr-auth-gates.XXXXXX)"
trap 'rm -rf "$work"' EXIT
export HERDR_RUN_STATE_DIR="$work/runs" HERDR_STATE_ROOT="$work/state"
export HERDR_BRIDGE_STATE="$work/bridge" XDG_RUNTIME_DIR="$work/runtime"
export HERDR_ACTION_NO_SURFACE=1 HERDR_ACTION_STALE_S=0
export SCREEN="$work/screen" KEYS="$work/keys" SENDS="$work/sends"
export ANCESTRY_PANE=w9:p9
mkdir -p "$work/wt" "$work/bin" "$XDG_RUNTIME_DIR"
: > "$KEYS"; : > "$SENDS"
export WT="$(cd "$work/wt" && pwd -P)"
git -C "$WT" init -q
git -C "$WT" symbolic-ref HEAD refs/heads/feat/gates
printf 'fixture\n' > "$WT/result.txt"

# Exported functions take precedence over any real herdr/ps binary, including
# scripts that reset PATH. Every unmatched command fails; no live calls occur.
herdr() {
  case "$1 $2" in
    'pane list')
      printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","terminal_id":"worker-legacy"},{"pane_id":"w2:p2","terminal_id":"worker-valid"},{"pane_id":"w9:p9","terminal_id":"conductor-birth"},{"pane_id":"w8:p8","terminal_id":"other-birth"}]}}' ;;
    'pane process-info')
      local pid=999999
      [ "${4:-}" != "${ANCESTRY_PANE:-}" ] || pid="$PPID"
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"name":"omp","cmdline":"omp"}]}}}\n' "$pid" ;;
    'pane read') cat "$SCREEN" ;;
    'pane send-keys') printf '%s\n' "$*" >> "$KEYS" ;;
    'pane send-text') printf '%s\n' "$*" >> "$SENDS" ;;
    *) return 99 ;;
  esac
}
ps() { [ "${ANCESTRY_READ_FAILURE:-0}" = 0 ] || return 1; printf '1\n'; }
export -f herdr ps
cat > "$work/bin/send" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SENDS"
EOF
chmod +x "$work/bin/send"
export HERDR_ACTION_SEND="$work/bin/send" HERDR_ACTION_NOTIFY="$work/bin/send"
export HERDR_ACTION_FORMSERVE="$work/bin/send"
. "$here/lib/pretool-shadow.sh"
. "$here/lib/prompt-parse.sh"
good=0 bad=0
ok() { good=$((good + 1)); printf '  ok    %s\n' "$1"; }
fail() { bad=$((bad + 1)); printf '  FAIL  %s\n' "$1"; }
q() { _sql "$1"; }
hold_reason() { case "$1" in 'authorization hold:'*) return 0 ;; *) return 1 ;; esac; }
manifest='{"git":"push-own-branch"}'
registry_init || exit 1
register_task gates legacy worker conductor_unknown w9:p9 conductor-birth w1:p1 worker-legacy "$WT" "$WT" legacy feat/gates main '' "$manifest" hook >/dev/null || exit 1
set_task_state gates legacy running >/dev/null
legacy="$(read_task gates legacy)"

printf '== legacy source: every command shape stays held ==\n'
for command in 'git add result.txt' 'git commit -m fixture' 'git add result.txt && git status && git commit -m fixture' "cd \"$WT\" && git add result.txt && git status && git commit -m fixture"; do
  peer_decide "$command" "$legacy"; rc=$?
  [ "$rc" = 1 ] && [ "$PD_VERDICT" = reserved ] && hold_reason "$PD_REASON" \
    && ok "unverified source held: $command" || fail "legacy: $rc/$PD_VERDICT/$PD_REASON"
done
forged="$(printf '%s' "$legacy" | jq '.authorization_status="verified" | .authorization_source="local_conductor"')"
peer_decide 'git add result.txt' "$forged"; rc=$?
[ "$rc" = 1 ] && hold_reason "$PD_REASON" && ok 'caller JSON cannot forge verification' || fail "forged JSON: $rc/$PD_REASON"

printf '== stable hook hold: no repeated requests or grant consumption ==\n'
export HERDR_RUN_ID=gates HERDR_TASK_ID=legacy HERDR_PANE_ID=w1:p1
for attempt in 1 2 3; do
  PS_TASK_JSON="$legacy" PS_POLICY=command-policy PS_VERDICT=allow PS_REASON=fixture PS_CMD='git add result.txt' PS_TOOL=bash
  pretool_enforce '{"tool":"bash","input":{"command":"git add result.txt"}}'; rc=$?
  [ "$rc" = 8 ] && [ "$PS_DECISION" = block ] && [ "$PS_POLICY" = task-authorization ] && [ -z "$PS_REQUEST_ID" ] \
    && ok "hook attempt $attempt held without a request" || fail "hook hold $attempt: $rc/$PS_POLICY/$PS_REQUEST_ID"
done
[ "$(q 'SELECT count(*) FROM action_requests;')" = 0 ] && ok 'three retries created zero action requests' || fail 'retry requests created'
for attempt in 1 2 3 4; do
  (
    printf '%s\n' '{"tool":"bash","input":{"command":"git add result.txt"}}' \
      | bash "$here/lib/pretool-shadow.sh" --enforce > "$work/concurrent-$attempt"
    printf '%s\n' "$?" > "$work/concurrent-$attempt.rc"
  ) &
done
wait
parallel_ok=1
for attempt in 1 2 3 4; do
  [ "$(cat "$work/concurrent-$attempt.rc")" = 8 ] &&
    jq -e '.decision=="block" and (.reason|contains("authorization hold:"))' "$work/concurrent-$attempt" >/dev/null || parallel_ok=0
done
[ "$parallel_ok" = 1 ] && [ "$(q 'SELECT count(*) FROM action_requests;')" = 0 ] \
  && ok 'four concurrent enforcing hooks report provenance hold with zero requests' || fail 'concurrent hook refusal mismatch'
rid="$(action_request_create gates legacy bash legacy-sha 'git add result.txt' escalate fixture conductor once '' '')"
action_request_decide "$rid" approved conductor w9:p9 branch-work fixture; rc=$?
[ "$rc" = 1 ] && [ "$(action_request_get "$rid" | jq -r .status)" = pending ] && ok 'decision gate leaves unverified request pending' || fail 'unverified decision changed'
q "UPDATE action_requests SET status='approved',authority='conductor' WHERE request_id=$(_sq "$rid");" >/dev/null
action_grant_consume "$rid"; rc=$?
[ "$rc" = 1 ] && [ "$(action_request_get "$rid" | jq -r .status)" = approved ] && ok 'pre-existing approval cannot consume through an unverified source' || fail 'legacy grant consumed'
action_request_resolve gates legacy bash legacy-sha 'git add result.txt' escalate fixture conductor once '' ''
[ "$AR_STATE" = authorization_hold ] && [ "$AR_DECISION" = block ] && [ "$AR_REQUEST_ID" = "$rid" ] && ok 'ack-loss reissue retains same grant and holds' || fail "hold state $AR_STATE/$AR_REQUEST_ID"
q "UPDATE action_requests SET status='declined',decision_reason='preserved refusal' WHERE request_id=$(_sq "$rid");" >/dev/null
action_request_resolve gates legacy bash legacy-sha 'git add result.txt' escalate fixture conductor once '' ''
[ "$AR_STATE" = declined ] && [ "$AR_WHY" = 'preserved refusal' ] && ok 'explicit decline is preserved under provenance failure' || fail "decline lost: $AR_STATE/$AR_WHY"

pending="$(action_request_create gates legacy bash pending-sha 'chmod u+x result.txt' escalate fixture conductor once '' '')"
for attempt in 1 2; do
  bash "$here/herdr-action.sh" surface "$pending" > "$work/surface-$attempt" 2>&1; rc=$?
  [ "$rc" = 8 ] && ok "pending surface $attempt reports held" || fail "surface rc=$rc"
  bash "$here/herdr-action.sh" tick > "$work/tick-$attempt" 2>&1
done
[ "$(q "SELECT count(*) FROM events WHERE type='action_authorization_held';")" = 1 ] && [ ! -s "$SENDS" ] \
  && ok 'restart/tick retries record one hold and zero notifications/forms' || fail 'duplicate hold or outward notification'

printf '== trusted receipt: existing grants stay usable within scope ==\n'
# Direct storage fixture: source authentication is tested by the receipt and
# remote-protocol suites. This does not assert a real human/host delegation.
accept_local_task_authorization gates-trusted w9:p9 conductor-birth "$WT" "$manifest" >/dev/null || exit 1
register_task gates trusted worker conductor w9:p9 conductor-birth w2:p2 worker-valid "$WT" "$WT" trusted feat/gates main '' "$manifest" hook gates-trusted >/dev/null || exit 1
mark_authorization_launch gates-trusted trusted gates launch_claimed >/dev/null || exit 1
mark_authorization_launch gates-trusted trusted gates launched >/dev/null || exit 1
set_task_state gates trusted running >/dev/null
trusted="$(read_task gates trusted)"
task_authorization_check "$trusted" && ok 'bound receipt is trusted in scratch registry' || fail "receipt: $TASK_AUTHORIZATION_REASON"
peer_decide 'git add result.txt' "$trusted"; rc=$?
[ "$rc" = 0 ] && [ "$PD_AUTHORITY" = grant ] && ok 'trusted simple own-branch operation uses existing ownership grant' || fail "trusted grant: $rc/$PD_VERDICT/$PD_REASON"
peer_decide 'git add result.txt && git status && git commit -m fixture' "$trusted"; rc=$?
[ "$PD_AUTHORITY" != grant ] && [ -z "$(_cp_grant_action 'git add result.txt && git status && git commit -m fixture' "$WT" feat/gates main)" ] \
  && ok 'compound command cannot use the simple-command ownership recognizer' || fail "compound ownership expanded: $rc/$PD_VERDICT/$PD_AUTHORITY"

printf '== authority machinery cannot be executed or overwritten by a worker ==\n'
for control in lib/task-authorization.py lib/task-reservation.py remote-mcp/registry-bridge.sh remote-mcp/authorization.py tests/fixtures/task-authorization.sh; do
  interpreter=python3; case "$control" in *.sh) interpreter=bash ;; esac
  for command in "$interpreter $here/$control" "printf x > $here/$control"; do
    peer_decide "$command" "$trusted"; rc=$?
    [ "$rc" = 1 ] && [ "$PD_VERDICT" = reserved ] && [ -n "$(conductor_reserved_reason "$command")" ] \
      && ok "authority machinery is human-reserved: $command" || fail "authority file escaped: $rc/$PD_VERDICT/$PD_REASON"
  done
  peer_decide "cat $here/$control" "$trusted"; rc=$?
  [ "$rc" = 0 ] && [ "$PD_VERDICT" = allow ] && ok "ordinary source inspection stays allowed: $control" || fail "source read held: $rc/$PD_VERDICT/$PD_REASON"
done

printf '== parser dependency failure is a hold, including existing grants ==\n'
(
  _cp_bashlex_resolve_helper() { return 1; }
  peer_decide 'git add result.txt' "$trusted"; rc=$?
  [ "$rc" = 1 ] && [ "$PD_VERDICT" = reserved ] && case "$PD_REASON" in 'policy dependency unavailable:'*) exit 0 ;; esac
  exit 1
) && ok 'missing parser cannot be cleared by ownership grant' || fail 'missing parser ownership escape'
(
  _cp_bashlex_resolve_helper() { _CP_BASHLEX_PY=/bin/false; _CP_BASHLEX_SCRIPT=fixture; return 0; }
  peer_decide 'git add result.txt' "$trusted"; rc=$?
  [ "$rc" = 1 ] && [ "$PD_VERDICT" = reserved ] && case "$PD_REASON" in 'policy dependency unavailable:'*) exit 0 ;; esac
  exit 1
) && ok 'broken parser runtime cannot be cleared by ownership grant' || fail 'broken parser ownership escape'
trid="$(action_request_create gates trusted bash trusted-sha 'chmod u+x result.txt' escalate fixture conductor once '' '')"
action_request_decide "$trid" approved conductor w9:p9 local-build fixture || exit 1
(
  _cp_bashlex_resolve_helper() { return 1; }
  action_request_resolve gates trusted bash trusted-sha 'chmod u+x result.txt' escalate fixture conductor once '' ''
  [ "$AR_STATE" = dependency_hold ] && [ "$AR_DECISION" = block ] && [ "$AR_REQUEST_ID" = "$trid" ] &&
    [ "$(action_request_get "$trid" | jq -r .status)" = approved ]
) && ok 'missing parser neither consumes approved grant nor creates replacement' || fail 'missing parser consumed/replaced grant'

printf '== verified grant: concurrent consumption and replay ==\n'
once="$(action_request_create gates trusted bash race-sha 'chmod u+x result.txt' escalate fixture conductor once '' '')"
HERDR_PANE_ID=forged-label bash "$here/herdr-action.sh" approve "$once" --authority conductor --review-category local-build --review-reason fixture > "$work/verified-approval" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(action_request_get "$once" | jq -r '.status+"/"+.decided_by')" = approved/w9:p9 ] \
  && ok 'verified conductor decision is attributed to ancestry, not environment' || fail "verified decision rc=$rc: $(cat "$work/verified-approval")"
# The preceding positive notification went only to our scratch send stub.
[ "$(wc -l < "$SENDS" | tr -d ' ')" = 1 ] && ok 'positive decision emits exactly one fixture notification' || fail 'positive decision notification count'
: > "$SENDS"
for attempt in 1 2 3 4; do
  ( action_grant_consume "$once"; printf '%s\n' "$?" > "$work/consume-$attempt.rc" ) &
done
wait
winners=0 losers=0
for attempt in 1 2 3 4; do
  case "$(cat "$work/consume-$attempt.rc")" in 0) winners=$((winners + 1)) ;; 1) losers=$((losers + 1)) ;; esac
done
[ "$winners" = 1 ] && [ "$losers" = 3 ] && [ "$(action_request_get "$once" | jq -r .status)" = consumed ] \
  && ok 'four concurrent consumers: exactly one consumes, three refuse' || fail "concurrent consume winners=$winners losers=$losers"
action_grant_consume "$once"; rc=$?
[ "$rc" = 1 ] && ok 'replay of a consumed grant refuses' || fail 'consumed grant replay allowed'

printf '== invalidation after genuine preflight cannot win the action CAS ==\n'
# The adapter wrapper executes the real read-only check, then commits a
# conflicting scratch-registry write before returning that old valid result.
# This deterministically hit the former check/UPDATE gap; no verifier result
# is fabricated and production has no test-only pause or permission bypass.
source_sha="$(q "SELECT source_sha256 FROM task_authorizations WHERE task_id='trusted';")"
for operation in consume approve; do
  for invalidation in cancellation source; do
    race_sha="$(_ps_sha "interleave-$operation-$invalidation")"
    race_id="$(action_request_create gates trusted bash "$race_sha" 'chmod u+x result.txt' escalate fixture conductor once '' '')"
    if [ "$operation" = consume ]; then
      action_request_decide "$race_id" approved conductor w9:p9 local-build fixture || { fail "race setup: $AR_MUTATION_REASON"; exit 1; }
    fi
    case "$invalidation" in
      cancellation) race_sql="UPDATE tasks SET state='cancelled' WHERE task_id='trusted';" ;;
      source) race_sql="UPDATE task_authorizations SET source_sha256='invalidated' WHERE task_id='trusted';" ;;
    esac
    race_mark="$work/$race_sha-preflight"; execute_mark="$work/$race_sha-executed"
    race_checks="$work/$race_sha-checks"; race_after=1
    # resolve checks once before looking up a grant; the second genuine check
    # is action_grant_consume's own preflight, immediately before its mutation.
    [ "$operation" != consume ] || race_after=2
    (
      _task_authorization_adapter() {
        local op="$1" result checks
        python3 "$_TASK_AUTHORIZATION_HELPER" "$(registry_db)" "$@"; result=$?
        if [ "$op" = check ] && [ "$result" = 0 ] && [ ! -e "$race_mark" ]; then
          checks="$(cat "$race_checks" 2>/dev/null || printf '0')"
          checks=$((checks + 1)); printf '%s\n' "$checks" > "$race_checks"
          if [ "$checks" = "$race_after" ]; then
            _sql "$race_sql" >/dev/null || return 1
            printf 'committed\n' > "$race_mark"
          fi
        fi
        return "$result"
      }
      if [ "$operation" = consume ]; then
        action_request_resolve gates trusted bash "$race_sha" 'chmod u+x result.txt' escalate fixture conductor once '' ''
        [ "$AR_DECISION" != allow ] || printf 'executed\n' > "$execute_mark"
        [ "$AR_STATE" = authorization_hold ] && [ "$AR_REQUEST_ID" = "$race_id" ] && hold_reason "$AR_WHY"
      else
        action_request_decide "$race_id" approved conductor w9:p9 local-build fixture; result=$?
        [ "$result" != 0 ] || printf 'approved\n' > "$execute_mark"
        [ "$result" = 1 ] && [ "$AR_MUTATION_HOLD" = 1 ] && hold_reason "$AR_MUTATION_REASON"
      fi
    ); race_rc=$?
    expected=pending; [ "$operation" != consume ] || expected=approved
    [ "$race_rc" = 0 ] && [ -s "$race_mark" ] && [ ! -e "$execute_mark" ] &&
      [ "$(action_request_get "$race_id" | jq -r .status)" = "$expected" ] &&
      [ "$(q "SELECT count(*) FROM action_requests WHERE action_sha256=$(_sq "$race_sha");")" = 1 ] \
      && ok "$operation after $invalidation: committed invalidation, zero mutation/execution/replacement" \
      || fail "$operation/$invalidation interleaving rc=$race_rc status=$(action_request_get "$race_id" | jq -r .status)"
    q "UPDATE tasks SET state='running' WHERE task_id='trusted'; UPDATE task_authorizations SET source_sha256=$(_sq "$source_sha") WHERE task_id='trusted';" >/dev/null
  done
done

printf '== authorized compound command reaches the fixture menu transport ==\n'
compound='git add result.txt && git status && git commit -m fixture'
printf 'Allow tool: bash\nCommand: %s\n\n\033[48;2;42;47;65m Approve\033[0m\nDeny\n\nup/down navigate  enter select  esc cancel\n' "$compound" > "$SCREEN"
compound_prompt="$(prompt_id w2:p2)"
append_event gates trusted input_required "$(jq -nc --arg cmd "$compound" --arg pid "$compound_prompt" '{tool:"bash",command:$cmd,prompt_id:$pid}')" >/dev/null
HERDR_PANE_ID=forged-label bash "$here/herdr-select.sh" w2:p2 1 --authority conductor --expect-prompt-id "$compound_prompt" --review-category branch-work --review-reason 'fixture compound inside approved task scope' > "$work/compound-menu" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(wc -l < "$KEYS" | tr -d ' ')" = 1 ] && grep -qx 'pane send-keys w2:p2 Enter' "$KEYS" &&
  [ "$(q "SELECT count(*) FROM approvals WHERE task_id='trusted' AND prompt_id=$(_sq "$compound_prompt") AND authority='conductor' AND outcome='pressed';")" = 1 ] \
  && ok 'authorized compound: exact prompt, current conductor ancestry, one delivered Enter and auditable acknowledgement' \
  || fail "authorized compound delivery rc=$rc: $(cat "$work/compound-menu")"
: > "$KEYS"

printf '== approved grants revalidate original source ==\n'
printf '#!/bin/bash\nchmod u+x result.txt\n' > "$WT/probe.sh"
code_ref_inspect "bash $WT/probe.sh" "$WT"; rc=$?
[ "$rc" = 0 ] || { fail "file fixture could not resolve: rc=$rc"; exit 1; }
file_approval_record trusted "$PD_CODE_PATH" "$PD_CODE_SHA" conductor:w9:p9 || exit 1
peer_decide "bash $WT/probe.sh" "$trusted"; rc=$?
[ "$rc" = 0 ] && [ "$PD_VERDICT" = allow ] && ok 'verified file approval permits its unchanged reviewed bytes' || fail "valid file approval $rc/$PD_VERDICT/$PD_REASON"
q "DELETE FROM task_authorizations WHERE task_id='trusted';" >/dev/null
peer_decide "bash $WT/probe.sh" "$trusted"; rc=$?
[ "$rc" = 1 ] && [ "$PD_VERDICT" = reserved ] && hold_reason "$PD_REASON" && ok 'old file approval cannot clear newly unverified provenance' || fail 'file grant source revalidation'
action_grant_consume "$trid"; rc=$?
[ "$rc" = 1 ] && [ "$(action_request_get "$trid" | jq -r .status)" = approved ] && ok 'old one-shot grant cannot clear newly unverified provenance' || fail 'once grant source revalidation'

printf '== conductor paths require provenance and ancestry; no keys/sends ==\n'
menu() { printf 'Allow tool: bash\nCommand: git add result.txt\n\n\033[48;2;42;47;65m Approve\033[0m\nDeny\n\nup/down navigate  enter select  esc cancel\n' > "$SCREEN"; }
menu
pid="$(prompt_id w1:p1)"
HERDR_PANE_ID=w9:p9 bash "$here/herdr-select.sh" w1:p1 1 --authority conductor --expect-prompt-id "$pid" --review-category branch-work --review-reason fixture > "$work/menu-held" 2>&1; rc=$?
[ "$rc" = 8 ] && grep -q 'authorization hold:' "$work/menu-held" && [ ! -s "$KEYS" ] && ok 'menu conductor cannot override provenance hold' || fail "menu held rc=$rc: $(cat "$work/menu-held")"
HERDR_PANE_ID=w9:p9 bash "$here/herdr-action.sh" approve "$pending" --authority conductor --review-category local-build --review-reason fixture > "$work/action-held" 2>&1; rc=$?
[ "$rc" = 8 ] && grep -q 'authorization hold:' "$work/action-held" && [ ! -s "$SENDS" ] && ok 'hook conductor cannot override provenance hold' || fail "action held rc=$rc: $(cat "$work/action-held")"
for path in menu action; do
  if [ "$path" = menu ]; then
    ANCESTRY_PANE=w8:p8 HERDR_PANE_ID=w9:p9 bash "$here/herdr-select.sh" w1:p1 1 --authority conductor --expect-prompt-id "$pid" --review-category branch-work --review-reason fixture > "$work/wrong-$path" 2>&1; rc=$?
  else
    ANCESTRY_PANE=w8:p8 HERDR_PANE_ID=w9:p9 bash "$here/herdr-action.sh" approve "$pending" --authority conductor --review-category local-build --review-reason fixture > "$work/wrong-$path" 2>&1; rc=$?
  fi
  [ "$rc" = 8 ] && grep -q 'caller is not.*live registered conductor' "$work/wrong-$path" && [ ! -s "$KEYS" ] && [ ! -s "$SENDS" ] \
    && ok "$path rejects forged HERDR_PANE_ID with zero sends" || fail "wrong $path rc=$rc: $(cat "$work/wrong-$path")"
done
ANCESTRY_READ_FAILURE=1 HERDR_PANE_ID=w9:p9 bash "$here/herdr-action.sh" approve "$pending" --authority conductor --review-category local-build --review-reason fixture > "$work/ancestry-failed" 2>&1; rc=$?
[ "$rc" = 8 ] && grep -q 'caller is not.*live registered conductor' "$work/ancestry-failed" && [ ! -s "$SENDS" ] \
  && ok 'unreadable ancestry fails closed; no env fallback' || fail "ancestry failure rc=$rc: $(cat "$work/ancestry-failed")"
[ "$(q "SELECT count(*) FROM action_requests WHERE status='consumed' AND request_id!=$(_sq "$once");")" = 0 ] && [ ! -s "$KEYS" ] && [ ! -s "$SENDS" ] \
  && ok 'held scenarios: exactly zero consumes, keypresses and notifications' || fail 'unexpected side effect'
printf '\n%d passed / %d failed; live canary runs=0 (not measured)\n' "$good" "$bad"
[ "$bad" = 0 ]
