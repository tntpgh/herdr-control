#!/usr/bin/env bash
# herdr-action.sh — decide an action request from a hook-approval worker.
#
# Design: docs/design/pretool-approval.md §4. A task spawned with
# `spawn-task.sh --approval hook` never paints an approval menu: its pre-tool
# hook blocks an escalate/reserved call and records an action request
# (lib/action-request.sh). This script is the only way to answer one.
#
#   herdr-action.sh list [--all]
#   herdr-action.sh show <request_id>
#   herdr-action.sh approve <request_id> --authority conductor \
#       --review-category <local-read|local-build|branch-work|owned-cleanup> --review-reason <why>
#   herdr-action.sh decline <request_id> --authority conductor --review-reason <why>
#   herdr-action.sh approve|decline <request_id> --authority human --form <form_id>
#   herdr-action.sh surface <request_id>   wake the owning conductor (idempotent)
#   herdr-action.sh tick                   the hub's pass (hub.py, every 60s)
#
# Authority — today's herdr-select.sh rules, unchanged:
#   conductor  the caller's HERDR_PANE_ID must be the task's registered
#              conductor pane AND its live generation (terminal_id) must equal
#              the registered conductor_pane_birth; the task must be active; an
#              operational --review-category and a --review-reason are required.
#              A conductor may approve only conductor-route requests (escalate
#              verdicts, lessons); a reserved (human-only) request refuses. It
#              may decline anything — declining runs nothing.
#   human      only through an ANSWERED hub decision form for this exact
#              request (--form <id>, ~/.local/state/herdr/forms/<id>.json). The
#              hub's tick applies answered forms itself.
#
# Approve writes a one-shot grant bound to (task, tool, action_sha256), or —
# for a script judged by reference (grant_kind=file) — a file_approvals row for
# (task, realpath, sha256) exactly as a conductor's menu approval does today.
# Either way an approvals row and an action_decided event are recorded, and the
# worker is told in its pane (send-to-agent.sh) to re-issue the identical call.
#
# The human route (route=human, or a conductor-route request still pending
# after HERDR_ACTION_STALE_S, default 900s): the tick posts ONE Slack alert
# (class human-action, lib/slack-level.sh) and serves a formserve decision on
# the hub, re-serving it when it expires. Expiry is never a decline.
# A request whose task reaches a terminal state (completed/failed/cancelled/
# lost) before a decision is withdrawn by the tick (status `withdrawn`), and
# its form record, if still open, is flipped to `withdrawn` so /decisions
# stops listing a question nobody can act on.
#
# Not a containment boundary (docs/approval-policy.md rule 7): a same-user
# process can set HERDR_PANE_ID, write the registry or a form file.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The hub runs `tick` every 15s. With nothing pending that is one read-only
# query, before the policy libraries are loaded at all.
if [ "${1:-}" = tick ]; then
  _db="${HERDR_RUN_STATE_DIR:-$HOME/.local/state/herdr/runs}/registry.sqlite3"
  [ -r "$_db" ] || exit 0
  # A plain SELECT on an ordinary connection: -readonly cannot open a WAL
  # database whose -wal/-shm files are absent, which would skip every tick.
  _n="$(sqlite3 -batch -noheader -cmd ".timeout 2000" "$_db" "SELECT count(*) FROM action_requests WHERE status='pending';" 2>/dev/null)"
  case "$_n" in ''|0) exit 0 ;; esac
fi
. "$here/lib/pretool-shadow.sh"          # run-registry, pane-guard, action-request, pretool_redact

HA_SEND="${HERDR_ACTION_SEND:-$here/send-to-agent.sh}"
HA_NOTIFY="${HERDR_ACTION_NOTIFY:-$here/slack-bridge/herdr-notify.sh}"
HA_FORMSERVE="${HERDR_ACTION_FORMSERVE:-$here/formserve.py}"
HA_PYTHON="${HERDR_ACTION_PYTHON:-python3}"
HA_RECORD_PYTHON="${HERDR_ACTION_RECORD_PYTHON:-python3}"
HA_FORMS_DIR="${HERDR_STATE_ROOT:-$HOME/.local/state/herdr}/forms"
HA_STALE_S="${HERDR_ACTION_STALE_S:-900}"

die() { printf 'herdr-action: %s\n' "$1" >&2; exit "${2:-2}"; }
_ha_field() { printf '%s' "$1" | jq -r ".$2 // empty" 2>/dev/null; }
_ha_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
_ha_epoch() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || printf '0'; }

_ha_task_active() {                     # task-json -> 0 if active
  case "$(_ha_field "$1" state)" in starting|running|blocked) return 0 ;; esac
  return 1
}

# Terminal states never come back (`lost` included: reconcile's verdict is
# final by design, verify-reconcile.sh).
_ha_task_terminal() {                   # task-json -> 0 if terminal
  case "$(_ha_field "$1" state)" in completed|failed|cancelled|lost) return 0 ;; esac
  return 1
}

_ha_conductor_ok() {                    # task-json -> 0 if the caller is its live conductor
  local owner birth
  owner="$(_ha_field "$1" conductor_pane_id)"; birth="$(_ha_field "$1" conductor_pane_birth)"
  [ -n "$owner" ] && [ "$owner" = "${HERDR_PANE_ID:-}" ] && [ -n "$birth" ] \
    && [ "$birth" = "$(pane_birth_now "$owner")" ]
}

# An answered hub form for exactly this request. Prints the answer JSON.
_ha_form_answer() {                     # form_id request_id -> answers json
  local f="$HA_FORMS_DIR/$1.json"
  case "$1" in ''|*/*|*..*) return 1 ;; esac
  [ -r "$f" ] || return 1
  jq -e --arg id "$2" '.status=="answered" and (.answers.request_id==$id)
      and ((.answers.decision=="approve") or (.answers.decision=="decline"))' "$f" >/dev/null 2>&1 || return 1
  jq -c '.answers' "$f"
}

_ha_notify_worker() {                   # row decision -> records action_notified
  local row="$1" decision="$2" id run task tj pane birth live msg rc outcome short
  id="$(_ha_field "$row" request_id)"; run="$(_ha_field "$row" run_id)"; task="$(_ha_field "$row" task_id)"
  tj="$(read_task "$run" "$task")"
  pane="$(_ha_field "$tj" pane_id)"; birth="$(_ha_field "$tj" pane_birth)"
  live="$(pane_birth_now "$pane" 2>/dev/null)"
  if [ -z "$pane" ] || [ -z "$live" ] || [ "$live" != "$birth" ]; then
    outcome="worker_pane_gone"; rc=6
  else
    short="$(_ha_field "$row" code_sha256 | cut -c1-12)"
    case "$decision:$(_ha_field "$row" grant_kind)" in
      approved:file) msg="[HERDR-ACTION] $id APPROVED ($(_ha_field "$row" authority)): $(_ha_field "$row" code_path) at sha256 $short is approved for this task — re-run it unchanged. Any edit to that file needs a new review." ;;
      approved:*)    msg="[HERDR-ACTION] $id APPROVED ($(_ha_field "$row" authority)): re-issue the identical call now — same tool, same command and arguments, byte for byte. It runs once." ;;
      *)             msg="[HERDR-ACTION] $id DECLINED ($(_ha_field "$row" authority)): $(_ha_field "$row" decision_reason). Do not retry it or work around it; change approach, or finish and hand off." ;;
    esac
    bash "$HA_SEND" "$pane" "$msg" >/dev/null 2>&1; rc=$?
    case "$rc" in 0) outcome=submitted ;; 5) outcome=refused ;; 4) outcome=unsubmitted ;; *) outcome="error_$rc" ;; esac
  fi
  append_event "$run" "$task" action_notified \
    "$(jq -nc --arg id "$id" --arg o "$outcome" --arg d "$decision" '{request_id:$id, decision:$d, outcome:$o}')" \
    "actnote_${id}" >/dev/null 2>&1 || true
  HA_NOTIFIED="$outcome"
  printf 'herdr-action: worker told (%s)\n' "$outcome"
}

# The one decide path (conductor CLI, human CLI, hub tick).
_ha_decide() {                          # id approved|declined authority decided_by category reason
  local id="$1" status="$2" auth="$3" who="$4" cat="$5" why="$6" row kind run task
  row="$(action_request_get "$id")"
  [ -n "$row" ] || die "no request $id" 3
  kind="$(_ha_field "$row" grant_kind)"; run="$(_ha_field "$row" run_id)"; task="$(_ha_field "$row" task_id)"
  action_request_decide "$id" "$status" "$auth" "$who" "$cat" "$why" \
    || die "request $id is not pending (status $(_ha_field "$row" status)) — nothing changed" 4
  if [ "$status" = approved ] && [ "$kind" = file ]; then
    if ! file_approval_record "$task" "$(_ha_field "$row" code_path)" "$(_ha_field "$row" code_sha256)" "$auth:$who"; then
      _sql "UPDATE action_requests SET status='pending', decided_at=NULL, authority='', decided_by='' WHERE request_id=$(_sq "$id");" >/dev/null 2>&1
      die "could not record the file approval — request left pending" 1
    fi
  fi
  row="$(action_request_get "$id")"
  append_event "$run" "$task" action_decided \
    "$(jq -nc --arg id "$id" --arg s "$status" --arg a "$auth" --arg w "$who" --arg c "$cat" --arg r "$why" \
       '{request_id:$id, decision:$s, authority:$a, reviewer:$w, review_category:$c, reason:$r}')" \
    "actdec_${id}" >/dev/null 2>&1 || true
  local tj pane choice=1 label=Approve
  [ "$status" = declined ] && { choice=2; label=Deny; }
  tj="$(read_task "$run" "$task")"; pane="$(_ha_field "$tj" pane_id)"
  approval_decided "appr_${id}" "$pane" "$id" "$choice" "$label" "$who" "$auth" \
    "$(_ha_field "$row" verdict)" "$(_ha_field "$row" command)" "$run" "$task" >/dev/null 2>&1 || true
  approval_attempted "appr_${id}" >/dev/null 2>&1 || true
  printf 'herdr-action: %s %s (%s)\n' "$id" "$status" "$auth"
  _ha_notify_worker "$row" "$status"
  approval_confirmed "appr_${id}" "$HA_NOTIFIED" "worker told via send-to-agent" >/dev/null 2>&1 || true
}

cmd_decide() {                          # approve|decline id [flags]
  local verb="$1" id="${2:-}" authority="" cat="" why="" form="" row tj route verdict
  shift 2 2>/dev/null || die "usage: herdr-action.sh $verb <request_id> --authority conductor|human …"
  while [ $# -gt 0 ]; do
    case "$1" in
      --authority) authority="${2:-}"; shift 2 ;;
      --review-category) cat="${2:-}"; shift 2 ;;
      --review-reason) why="${2:-}"; shift 2 ;;
      --form) form="${2:-}"; shift 2 ;;
      *) die "unknown argument $1" ;;
    esac
  done
  registry_init || die "registry unavailable" 1
  row="$(action_request_get "$id")"; [ -n "$row" ] || die "no request $id" 3
  tj="$(read_task "$(_ha_field "$row" run_id)" "$(_ha_field "$row" task_id)")"
  route="$(_ha_field "$row" route)"; verdict="$(_ha_field "$row" verdict)"
  local status=approved; [ "$verb" = decline ] && status=declined
  case "$authority" in
    conductor)
      _ha_task_active "$tj" || die "the task is not active — nothing to decide" 8
      _ha_conductor_ok "$tj" || die "caller is not this task's live registered conductor" 8
      [ -n "${why//[[:space:]]/}" ] || die "conductor requires --review-reason after reviewing the complete action and target"
      if [ "$status" = approved ]; then
        case "$cat" in local-read|local-build|branch-work|owned-cleanup) ;;
          *) die "conductor approval requires an operational --review-category" ;; esac
        if [ "$route" != conductor ] || [ "$verdict" = reserved ] || [ "$verdict" = deny ]; then
          die "request $id is human-only ($verdict): a conductor may decline it but not approve it" 8
        fi
      fi
      _ha_decide "$id" "$status" conductor "${HERDR_PANE_ID:-}" "$cat" "$why" ;;
    human)
      local ans pinned
      # Only the formserve record the hub tick pinned when it served THIS
      # request's form counts — a record written later by anything else does not.
      pinned="$(_ha_field "$row" form_record)"
      [ -n "$pinned" ] && [ "$form" = "$pinned" ] || die "human authority needs --form <id> naming the hub decision form served for $id (${pinned:-none served yet})" 8
      ans="$(_ha_form_answer "$form" "$id")" || die "human authority needs --form <id>: an ANSWERED hub decision form for exactly $id" 8
      [ "$(_ha_field "$ans" decision)" = "$verb" ] || die "form $form answered '$(_ha_field "$ans" decision)', not '$verb'" 8
      _ha_decide "$id" "$status" human "hub form $form" "" "$(_ha_field "$ans" reason)" ;;
    *) die "--authority conductor|human is required" ;;
  esac
}

cmd_surface() {                         # id -> wake the conductor once
  local id="$1" row tj cpane cbirth msg rc outcome disp label
  registry_init || return 1
  row="$(action_request_get "$id")"; [ -n "$row" ] || return 3
  [ "$(_ha_field "$row" status)" = pending ] || return 0
  [ "$(_ha_field "$row" route)" = conductor ] || return 0
  claim_once "actsurf_${id}" "$(_ha_field "$row" run_id)" "$(_ha_field "$row" task_id)" action_surface_claimed \
    "$(jq -nc --arg id "$id" '{request_id:$id}')" || return 0
  tj="$(read_task "$(_ha_field "$row" run_id)" "$(_ha_field "$row" task_id)")"
  cpane="$(_ha_field "$tj" conductor_pane_id)"; cbirth="$(_ha_field "$tj" conductor_pane_birth)"
  label="$(_ha_field "$tj" label)"
  disp="$(pretool_redact "$(_ha_field "$row" command)" | tr '\n' ' ' | cut -c1-300)"
  msg="[HERDR-ACTION] ${label:-$(_ha_field "$row" task_id)} ($(_ha_field "$tj" pane_id)) asks to run: ${disp} — $(_ha_field "$row" reason | cut -c1-200). Request $id. Review the complete action (herdr-action.sh show $id), then: $here/herdr-action.sh approve $id --authority conductor --review-category <local-read|local-build|branch-work|owned-cleanup> --review-reason '<why>'  OR  $here/herdr-action.sh decline $id --authority conductor --review-reason '<why>'"
  if [ -z "$cpane" ]; then
    outcome=conductor_unconfigured
  elif [ -z "$cbirth" ] || [ "$cbirth" != "$(pane_birth_now "$cpane")" ]; then
    outcome=conductor_unreachable
  else
    bash "$HA_SEND" "$cpane" "$msg" >/dev/null 2>&1; rc=$?
    case "$rc" in 0) outcome=submitted ;; 5) outcome=refused ;; 4) outcome=unsubmitted ;; *) outcome="error_$rc" ;; esac
  fi
  _sql "UPDATE action_requests SET surfaced_at=$(_sq "$(_now_iso)") WHERE request_id=$(_sq "$id");" >/dev/null 2>&1
  append_event "$(_ha_field "$row" run_id)" "$(_ha_field "$row" task_id)" action_surfaced \
    "$(jq -nc --arg id "$id" --arg o "$outcome" --arg p "$cpane" '{request_id:$id, route:"conductor", conductor_pane:$p, outcome:$o}')" \
    "actsurfres_${id}" >/dev/null 2>&1 || true
}

_ha_serve_form() {                      # row task-json -> form path (served)
  local row="$1" tj="$2" id dir f n
  id="$(_ha_field "$row" request_id)"
  dir="$(run_state_root)/action-forms"; mkdir -p "$dir" 2>/dev/null || return 1
  n="$(ls "$dir" 2>/dev/null | grep -c "^${id}-")"
  f="$dir/${id}-$((n + 1)).html"
  cat > "$f" <<HTML
<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1">
<title>Human-only action requested: $(_ha_esc "$(_ha_field "$tj" label)")</title>
<style>
:root{--ground:#eef2f2;--surface:#fff;--line:#c9d4d4;--ink:#10191c;--ink-2:#3d4e53;--accent:#1f6e7e;--accent-soft:#e2eef0}
@media (prefers-color-scheme:dark){:root{--ground:#0c1316;--surface:#131e22;--line:#2c3b41;--ink:#e6edee;--ink-2:#a9bcc1;--accent:#58b6c8;--accent-soft:#12323a}}
*{box-sizing:border-box}body{margin:0;background:var(--ground);color:var(--ink);font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:720px;margin:0 auto;padding:40px 24px 120px}h1{font-size:24px;margin:0 0 6px}.sub{color:var(--ink-2);margin:0 0 24px}
fieldset{border:1px solid var(--line);border-radius:6px;background:var(--surface);padding:18px 20px;margin:0 0 18px}
legend{font:600 12px system-ui;letter-spacing:.12em;text-transform:uppercase;color:var(--ink-2);padding:0 6px}
pre{margin:0;white-space:pre-wrap;word-break:break-word;font:13px/1.5 ui-monospace,Menlo,monospace;background:var(--ground);border:1px solid var(--line);border-radius:5px;padding:10px 12px}
label.opt{display:flex;gap:10px;align-items:flex-start;padding:10px 12px;border:1px solid var(--line);border-radius:5px;margin-top:10px;cursor:pointer;background:var(--ground)}
label.opt:has(input:checked){border-color:var(--accent);background:var(--accent-soft)}
textarea{width:100%;min-height:70px;padding:10px 12px;border-radius:5px;border:1px solid var(--line);background:var(--ground);color:var(--ink);font:14px/1.5 system-ui}
.bar{position:fixed;left:0;right:0;bottom:0;padding:14px 24px;background:var(--surface);border-top:1px solid var(--line);display:flex;justify-content:flex-end}
button{font:600 14px system-ui;padding:10px 20px;border-radius:5px;cursor:pointer;border:1px solid var(--accent);background:var(--accent);color:var(--ground)}
</style></head><body><main>
<h1>A worker needs your OK for one action</h1>
<p class=sub>Worker $(_ha_esc "$(_ha_field "$tj" label)") ($(_ha_esc "$(_ha_field "$tj" pane_id)")) was stopped before running this. It only runs if you approve it here, and then only once, exactly as shown. If this page expires, the request stays open — expiry is not a no.</p>
<form id=f>
<fieldset><legend>What it wants to run</legend><pre>$(_ha_esc "$(_ha_field "$row" command)")</pre></fieldset>
<fieldset><legend>Why it was stopped</legend><p style="margin:0">$(_ha_esc "$(_ha_field "$row" reason)")</p></fieldset>
<fieldset><legend>Your decision</legend>
<label class=opt><input type=radio name=decision value=approve required><span><b>Approve — run it once</b></span></label>
<label class=opt><input type=radio name=decision value=decline><span><b>Decline — do not run it</b></span></label>
<p style="margin:14px 0 6px">Reason (sent to the worker):</p><textarea name=reason></textarea></fieldset>
<p class=sub>Request $(_ha_esc "$id")</p>
</form></main>
<div class=bar><button type=submit form=f>Send decision</button></div>
<script>document.getElementById("f").addEventListener("submit",function(e){e.preventDefault();var fd=new FormData(e.target);
window.submitAnswers({request_id:"$(_ha_esc "$id")",decision:fd.get("decision"),reason:(fd.get("reason")||"").trim()})});</script>
</body></html>
HTML
  ( "$HA_PYTHON" "$HA_FORMSERVE" "$f" --timeout 86400 --no-open </dev/null >/dev/null 2>&1 & disown ) 2>/dev/null
  printf '%s\n' "$f"
}

# formserve writes its record (status open) as it starts. Pin that record to
# the request right away, so an answer given before the next tick still
# counts; a slow start is pinned by a later tick, and only while still open.
_ha_pin_form() {                        # request_id form-path -> 0 pinned
  local k st fid
  for k in 1 2 3 4 5 6 7 8 9 10; do
    read -r st fid <<EOF
$(_ha_form_status "$2")
EOF
    if [ "${st:-}" = open ] && [ -n "${fid:-}" ]; then
      _sql "UPDATE action_requests SET form_record=$(_sq "$fid") WHERE request_id=$(_sq "$1") AND status='pending';" >/dev/null 2>&1
      return 0
    fi
    sleep 0.3
  done
  return 1
}

_ha_form_status() {                     # form-path -> "<status> <form_id>" (empty if no record yet)
  local rec
  rec="$(grep -l -F "\"form_path\": \"$1\"" "$HA_FORMS_DIR"/*.json 2>/dev/null | head -1)"
  [ -n "$rec" ] || rec="$(grep -l -F "\"form_path\":\"$1\"" "$HA_FORMS_DIR"/*.json 2>/dev/null | head -1)"
  [ -n "$rec" ] || return 0
  printf '%s %s\n' "$(jq -r '.status // empty' "$rec" 2>/dev/null)" "$(basename "$rec" .json)"
}

_ha_human_route() {                     # id row task-json
  local id="$1" row="$2" tj="$3" fp st fid ans n disp
  fp="$(_ha_field "$row" form_path)"
  if [ -n "$fp" ]; then
    fid="$(_ha_field "$row" form_record)"
    if [ -z "$fid" ]; then
      # Pin the formserve record the first time it is seen OPEN; from then on
      # only that record is read.
      read -r st fid <<EOF
$(_ha_form_status "$fp")
EOF
      [ "${st:-}" = open ] || return 0
      _sql "UPDATE action_requests SET form_record=$(_sq "$fid") WHERE request_id=$(_sq "$id") AND status='pending';" >/dev/null 2>&1
      return 0
    fi
    st="$(jq -r '.status // empty' "$HA_FORMS_DIR/$fid.json" 2>/dev/null)"
    case "${st:-}" in
      answered)
        if ans="$(_ha_form_answer "$fid" "$id")"; then
          case "$(_ha_field "$ans" decision)" in
            approve) ( _ha_decide "$id" approved human "hub form $fid" "" "$(_ha_field "$ans" reason)" ) >/dev/null 2>&1 ;;
            decline) ( _ha_decide "$id" declined human "hub form $fid" "" "$(_ha_field "$ans" reason)" ) >/dev/null 2>&1 ;;
          esac
        fi
        return 0 ;;
      expired|gone)
        append_event "$(_ha_field "$row" run_id)" "$(_ha_field "$row" task_id)" action_form_expired \
          "$(jq -nc --arg id "$id" --arg f "$fp" '{request_id:$id, form_path:$f, note:"expired is still unanswered, never a decline"}')" \
          "actexp_$(printf '%s' "$fp" | shasum -a 256 | cut -c1-16)" >/dev/null 2>&1 || true ;;
      *) return 0 ;;                     # open, or formserve not up yet
    esac
  fi
  fp="$(_ha_serve_form "$row" "$tj")" || return 0
  _sql "UPDATE action_requests SET form_path=$(_sq "$fp"), form_record='' WHERE request_id=$(_sq "$id") AND status='pending';" >/dev/null 2>&1
  _ha_pin_form "$id" "$fp" || true
  append_event "$(_ha_field "$row" run_id)" "$(_ha_field "$row" task_id)" action_form_served \
    "$(jq -nc --arg id "$id" --arg f "$fp" '{request_id:$id, form_path:$f}')" >/dev/null 2>&1 || true
  # One Slack post per request (not per re-served form): the alert says where
  # to decide; the form is what stays open.
  if claim_once "actslack_${id}" "$(_ha_field "$row" run_id)" "$(_ha_field "$row" task_id)" action_slack_claimed \
       "$(jq -nc --arg id "$id" '{request_id:$id}')"; then
    # The command itself stays on this machine (the hub form shows it): a
    # command line can carry a secret no redactor recognises (webhook paths).
    bash "$HA_NOTIFY" --class human-action --pane "$(_ha_field "$tj" pane_id)" \
      "$(_ha_field "$tj" label): needs YOUR OK for one $(_ha_field "$row" tool) action (request $id, $(_ha_field "$row" verdict)) — see it and decide at http://127.0.0.1:8600/decisions" \
      >/dev/null 2>&1 || true
  fi
}

# Flip a form record open -> withdrawn under record_store's lock, so the hub
# stops listing it and refuses an answer (409). A record already answered or
# expired is left exactly as it is: a real answer is never overwritten.
# Prints what happened — withdrawn, kept:<status>[:<decision>], not-found,
# error — so the withdrawal event says whether a human answer was dropped.
_ha_retire_form() {                     # record-path reason -> outcome
  "$HA_RECORD_PYTHON" - "$here/lib" "$1" "$2" 2>/dev/null <<'PY' || printf 'error\n'
import sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from record_store import NotClaimable, claim_and_update
def _withdraw(row):
    row.update(status="withdrawn", withdrawn_reason=sys.argv[3], withdrawn_at=int(time.time() * 1000))
    return row
try:
    claim_and_update(Path(sys.argv[2]), _withdraw)
    print("withdrawn")
except NotClaimable as e:
    decision = (e.row.get("answers") or {}).get("decision") if isinstance(e.row.get("answers"), dict) else None
    print(f"kept:{e.state}" + (f":{decision}" if decision else ""))
except FileNotFoundError:
    print("not-found")
PY
}

# A request whose task ended before anyone decided it: observed 2026-09-29,
# 19 of them pending up to 15h after their workers completed or were lost,
# 4 with forms still listed open on /decisions. Answering one did nothing —
# the tick skipped inactive tasks — so the inbox held questions nobody could
# act on, and every tick re-read them.
_ha_withdraw() {                        # id row task-json
  local id="$1" row="$2" tj="$3" st why fp fid _st outcome
  st="$(_ha_field "$tj" state)"
  why="task $st before a decision; nothing is left to run it"
  action_request_withdraw "$id" "$why" || return 0
  fid="$(_ha_field "$row" form_record)"
  fp="$(_ha_field "$row" form_path)"
  if [ -z "$fid" ] && [ -n "$fp" ]; then
    read -r _st fid <<EOF
$(_ha_form_status "$fp")
EOF
  fi
  case "$fid" in
    ''|*/*|*..*) if [ -n "$fp" ]; then outcome=unpinned; else outcome=no-form; fi ;;
    *) outcome="$(_ha_retire_form "$HA_FORMS_DIR/$fid.json" "$why")" ;;
  esac
  append_event "$(_ha_field "$row" run_id)" "$(_ha_field "$row" task_id)" action_withdrawn \
    "$(jq -nc --arg id "$id" --arg s "$st" --arg f "$fid" --arg o "$outcome" '{request_id:$id, task_state:$s, form_record:$f, form_outcome:$o}')" \
    "actwd_${id}" >/dev/null 2>&1 || true
}

# _ha_surface_outcome <request_id> -> the outcome recorded on this request's
# newest action_surfaced event, or empty if it has never been surfaced.
# cmd_surface only emits one such event per request (claim_once-guarded), so
# a later tick must read it back here rather than relying on cmd_surface's
# own (silently swallowed, `|| true`) exit status.
_ha_surface_outcome() {
  _sql "SELECT json_extract(payload,'\$.outcome') FROM events
        WHERE type='action_surfaced' AND json_extract(payload,'\$.request_id')=$(_sq "$1")
        ORDER BY sequence DESC LIMIT 1;" 2>/dev/null
}

cmd_tick() {
  local id row tj age now
  registry_init >/dev/null 2>&1 || return 0
  now="$(date -u +%s)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    row="$(action_request_get "$id")"; [ -n "$row" ] || continue
    tj="$(read_task "$(_ha_field "$row" run_id)" "$(_ha_field "$row" task_id)")"
    if ! _ha_task_active "$tj"; then
      # Only a definite terminal state withdraws; an unreadable or missing
      # task row is left pending rather than guessed at.
      _ha_task_terminal "$tj" && _ha_withdraw "$id" "$row" "$tj"
      continue
    fi
    age=$(( now - $(_ha_epoch "$(_ha_field "$row" created_at)") ))
    if [ "$(_ha_field "$row" route)" = conductor ]; then
      cmd_surface "$id" >/dev/null 2>&1 || true
      # remote-research-answer-approval (2026-10-02): a request with NO
      # conductor pane configured at all (spawn-task.sh recorded none —
      # never a recycled/stale one, which keeps today's HA_STALE_S wait)
      # has nobody who could ever see the conductor alert; waiting out the
      # normal window before the human route only delays a question that
      # was never going anywhere. Escalate on the very next tick instead.
      if [ "$(_ha_surface_outcome "$id")" != conductor_unconfigured ]; then
        [ "$age" -ge "$HA_STALE_S" ] || continue
      fi
    fi
    ( _ha_human_route "$id" "$row" "$tj" ) >/dev/null 2>&1
  done < <(action_requests_pending)
}

cmd_list() {
  registry_init || die "registry unavailable" 1
  local where="WHERE status='pending'"; [ "${1:-}" = --all ] && where=""
  _sql "SELECT request_id || '  ' || status || '  ' || route || '  ' || verdict || '  ' || task_id || '  ' || substr(replace(command, char(10), ' '), 1, 100)
        FROM action_requests $where ORDER BY created_at;" 2>/dev/null
}

case "${1:-}" in
  approve|decline) cmd_decide "$@" ;;
  surface) [ -n "${2:-}" ] || die "usage: herdr-action.sh surface <request_id>"; cmd_surface "$2" ;;
  tick) cmd_tick ;;
  list) cmd_list "${2:-}" ;;
  show) registry_init || die "registry unavailable" 1; row="$(action_request_get "${2:-}")"; [ -n "$row" ] || die "no request ${2:-}" 3; printf '%s\n' "$row" | jq . ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
