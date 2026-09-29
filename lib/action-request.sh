#!/usr/bin/env bash
# lib/action-request.sh — the ONE escalation channel for hook-mode workers.
#
# Design: docs/design/pretool-approval.md §4. A task spawned with
# `spawn-task.sh --approval hook` runs omp with --auto-approve, so no approval
# menu ever paints. Its pre-tool hook (lib/pretool-shadow.sh --enforce) decides
# every call on the exact input; an escalate/reserved verdict is BLOCKED and
# becomes a row here instead of a menu:
#
#   pending --(conductor|human decides, herdr-action.sh)--> approved | declined
#   approved (grant_kind once) --(the identical call re-issued)--> consumed
#   approved (grant_kind file) -> a file_approvals row (code by reference); the
#                                 same bytes then re-run through peer_decide
#
# The grant is bound to (task, tool, action_sha256): the sha256 of the call's
# execution-relevant input (pretool_action_sha). Different bytes are a
# different request. Consumption is a check-and-set UPDATE, so one approval
# runs the call exactly once even under parallel identical calls.
#
# Requires lib/run-registry.sh to be sourced.
# Not a containment boundary (docs/approval-policy.md rule 7): a same-user
# process can write the registry.
[ -n "${_HERDR_ACTION_REQUEST_SH:-}" ] && return 0
_HERDR_ACTION_REQUEST_SH=1

# Canonical, execution-relevant input for a tool call. The model's free-text
# `i` (intent) field is excluded — it is rephrased on every re-issue and does
# not change what runs. For bash only what decides the process is kept: the
# command, its working directory (the session cwd when the call names none),
# a service env and name. timeout/pty/async do not change what runs.
pretool_action_sha() {                  # tool input-json session-cwd -> sha256
  local tool="$1" input="$2" cwd="${3:-}" canon
  case "$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')" in
    bash|shell)
      canon="$(printf '%s' "$input" | jq -cS --arg cwd "$cwd" \
        '{command:(.command // ""), cwd:(.cwd // $cwd), env:(.env // {}), name:(.name // "")}' 2>/dev/null)" ;;
    *)
      canon="$(printf '%s' "$input" | jq -cS 'if type=="object" then del(.i) else . end' 2>/dev/null)" ;;
  esac
  [ -n "$canon" ] || canon="$input"
  printf '%s\n%s' "$tool" "$canon" | shasum -a 256 | cut -d' ' -f1
}

_ar_row() {                             # request_id -> json row (empty if absent)
  _sql "SELECT json_object('request_id',request_id,'run_id',run_id,'task_id',task_id,'tool',tool,
      'action_sha256',action_sha256,'command',command,'verdict',verdict,'reason',reason,'route',route,
      'grant_kind',grant_kind,'code_path',code_path,'code_sha256',code_sha256,'status',status,
      'created_at',created_at,'decided_at',decided_at,'decided_by',decided_by,'authority',authority,
      'review_category',review_category,'decision_reason',decision_reason,'consumed_at',consumed_at,
      'surfaced_at',surfaced_at,'form_path',form_path,'form_record',form_record)
    FROM action_requests WHERE request_id=$(_sq "$1");" 2>/dev/null
}
action_request_get() { _ar_row "$1"; }

_ar_latest() {                          # task action_sha -> json row of the newest request
  local id
  id="$(_sql "SELECT request_id FROM action_requests WHERE task_id=$(_sq "$1")
      AND action_sha256=$(_sq "$2") ORDER BY created_at DESC, rowid DESC LIMIT 1;" 2>/dev/null)"
  [ -n "$id" ] && _ar_row "$id"
}

# Atomically turn an approved one-shot grant into `consumed`. 0 only for the
# ONE caller whose UPDATE changed the row.
action_grant_consume() {                # request_id -> 0 consumed by this call
  local n
  n="$(_sql "UPDATE action_requests SET status='consumed', consumed_at=$(_sq "$(_now_iso)")
      WHERE request_id=$(_sq "$1") AND status='approved' AND grant_kind='once'; SELECT changes();" 2>/dev/null)"
  [ "${n:-0}" = 1 ]
}

# Create (or find) the pending request for one call. Deterministic id: the
# same (task, action) generation maps to the same id, so parallel identical
# calls make ONE row (INSERT OR IGNORE). Prints the request id.
action_request_create() {               # run task tool action_sha command verdict reason route grant_kind code_path code_sha
  local run="$1" task="$2" tool="$3" sha="$4" cmd="$5" verdict="$6" reason="$7" route="$8" kind="$9"
  local cpath="${10:-}" csha="${11:-}" gen id
  gen="$(_sql "SELECT count(*) FROM action_requests WHERE task_id=$(_sq "$task") AND action_sha256=$(_sq "$sha")
      AND status IN ('consumed','approved');" 2>/dev/null)"
  id="ar_$(printf '%s' "$task" | shasum -a 256 | cut -c1-8)_$(printf '%s' "$sha" | cut -c1-16)_$(( ${gen:-0} + 1 ))"
  if _sql "INSERT OR IGNORE INTO action_requests (request_id, run_id, task_id, tool, action_sha256, command,
        verdict, reason, route, grant_kind, code_path, code_sha256, status, created_at)
      VALUES ($(_sq "$id"), $(_sq "$run"), $(_sq "$task"), $(_sq "$tool"), $(_sq "$sha"), $(_sq "$cmd"),
        $(_sq "$verdict"), $(_sq "$reason"), $(_sq "$route"), $(_sq "$kind"), $(_sq "$cpath"), $(_sq "$csha"),
        'pending', $(_sq "$(_now_iso)"));" >/dev/null 2>&1; then
    claim_once "actreq_${id}" "$run" "$task" action_requested \
      "$(jq -nc --arg id "$id" --arg tool "$tool" --arg cmd "$cmd" --arg v "$verdict" --arg r "$reason" \
         --arg route "$route" --arg sha "$sha" --arg cp "$cpath" --arg cs "$csha" \
         '{request_id:$id, tool:$tool, command:$cmd, verdict:$v, reason:$r, route:$route,
           action_sha256:$sha, code_path:$cp, code_sha256:$cs}')" >/dev/null 2>&1 || true
    printf '%s\n' "$id"
    return 0
  fi
  return 1
}

# The whole hook-time lookup for a not-allowed call. Sets AR_DECISION
# (allow|block), AR_REQUEST_ID, AR_STATE (consumed|pending|declined|new) and
# AR_WHO/AR_WHY for a declined request.
action_request_resolve() {              # run task tool action_sha command verdict reason route grant_kind code_path code_sha
  local run="$1" task="$2" sha="$4" row st id
  AR_DECISION=block AR_REQUEST_ID="" AR_STATE="" AR_WHO="" AR_WHY=""
  row="$(_ar_latest "$task" "$sha")"
  if [ -n "$row" ]; then
    st="$(printf '%s' "$row" | jq -r '.status')"; id="$(printf '%s' "$row" | jq -r '.request_id')"
    case "$st" in
      approved)
        # Consume only a decision whose authority could have made it: a
        # human-route request needs a human decision; a conductor decision
        # counts only if the request was, and still is, conductor-route.
        local auth rroute okauth=0
        auth="$(printf '%s' "$row" | jq -r '.authority')"; rroute="$(printf '%s' "$row" | jq -r '.route')"
        case "$auth" in
          human) okauth=1 ;;
          conductor) [ "$rroute" = conductor ] && [ "$8" = conductor ] && okauth=1 ;;
        esac
        if [ "$okauth" = 1 ] && [ "$(printf '%s' "$row" | jq -r '.grant_kind')" = once ] && action_grant_consume "$id"; then
          AR_DECISION=allow AR_REQUEST_ID="$id" AR_STATE=consumed
          append_event "$run" "$task" action_consumed "$(jq -nc --arg id "$id" '{request_id:$id}')" \
            "actcons_${id}" >/dev/null 2>&1 || true
          return 0
        fi ;;
      pending) AR_REQUEST_ID="$id" AR_STATE=pending; return 0 ;;
      declined)
        AR_REQUEST_ID="$id" AR_STATE=declined
        AR_WHO="$(printf '%s' "$row" | jq -r '.authority')"
        AR_WHY="$(printf '%s' "$row" | jq -r '.decision_reason')"
        return 0 ;;
    esac
  fi
  AR_REQUEST_ID="$(action_request_create "$@")" || { AR_REQUEST_ID=""; return 1; }
  AR_STATE=new
  return 0
}

# Check-and-set pending -> approved|declined. 0 only for the caller that won.
action_request_decide() {               # request_id approved|declined authority decided_by category reason [form_path]
  local n
  n="$(_sql "UPDATE action_requests SET status=$(_sq "$2"), decided_at=$(_sq "$(_now_iso)"),
      authority=$(_sq "$3"), decided_by=$(_sq "$4"), review_category=$(_sq "$5"), decision_reason=$(_sq "$6")
      WHERE request_id=$(_sq "$1") AND status='pending'; SELECT changes();" 2>/dev/null)"
  [ "${n:-0}" = 1 ]
}

# Check-and-set pending -> withdrawn: the task ended (completed/failed/
# cancelled/lost) before anyone decided, so nothing is left to run the action.
# Not a decline and not an approval — no worker is told anything. 0 only for
# the caller that won.
action_request_withdraw() {             # request_id reason
  local n
  n="$(_sql "UPDATE action_requests SET status='withdrawn', decided_at=$(_sq "$(_now_iso)"),
      authority='system', decided_by='herdr-action tick', decision_reason=$(_sq "$2")
      WHERE request_id=$(_sq "$1") AND status='pending'; SELECT changes();" 2>/dev/null)"
  [ "${n:-0}" = 1 ]
}

action_requests_pending() {             # -> one request_id per line
  _sql "SELECT request_id FROM action_requests WHERE status='pending' ORDER BY created_at;" 2>/dev/null
}
