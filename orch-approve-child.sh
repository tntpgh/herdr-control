#!/usr/bin/env bash
# orch-approve-child.sh — structured, single-purpose entry point letting a
# LIVE bound orchestrator@<project> pane review and resolve its OWN child's
# pending bound approval request.
#
# Incident (.handoffs/SPEC.md "narrow orchestrator -> child approval
# interface"; live evidence ~/Code/thurber-os/.handoffs/closed-panes/
# website-pilot-r3/PILOT-REPORT.md, 2026-10-18): PR #334's bound-orchestrator
# mode correctly routes a child's approval wake to the orchestrator pane
# (tasks.conductor_pane_id = the orchestrator), but the orchestrator could
# not ANSWER it: any bash command invoking herdr-select.sh is human-only by
# design (command-policy.sh's _CP_POLICY_FILE_RE), and a raw
# `prompt-occurrence.py --db <registry path> proposal --show` call is
# classified a registry write (command-policy.sh's _CP_REGISTRY_TRIGGER_RE
# matches the registry path appearing in argv).
#
# This is NOT a wrapper that shells into herdr-select.sh with caller-chosen
# flags, and herdr-select.sh is NOT added to any allowlist (constraints,
# .handoffs/SPEC.md). Instead this script re-derives every fact itself,
# straight from the registry, reusing the exact same verified primitives
# herdr-select.sh's own bound-request path already uses:
#   - lib/pane-guard.sh: caller_pane_from_ancestry, pane_birth_now,
#     require_pane_birth_match, _pg_bound_orchestrator_eligible
#   - lib/run-registry.sh: role_for_live_pane, task_for_pane,
#     task_authorization_check, registry_db, _registry_python, gen_id,
#     approval_decided/attempted/confirmed, append_event
#   - lib/command-policy.sh: classify_command, conductor_reserved_reason
#   - lib/prompt-occurrence.py: proposal (exact-identity verification,
#     --show for the read-only review text), authorize-bound (the one-shot
#     decision write — no screen read, no keypress, same as herdr-select.sh's
#     bound path)
# No command text this script's OWN invocation needs to contain ever names
# a reserved policy file or a registry path: the registry path is resolved
# INSIDE this script, never passed by the caller, so naming this script on
# the orchestrator's own bash command line trips neither
# _CP_POLICY_FILE_RE nor _CP_REGISTRY_TRIGGER_RE. Verified empirically
# (.handoffs/PROOF.md) rather than assumed — see that file for the exact
# conductor_reserved_reason probe and its (empty) result.
#
# Usage:
#   orch-approve-child.sh review <child_pane> <approval_request_id> \
#     <tool_call_id> <arguments_digest>
#   orch-approve-child.sh decide <child_pane> <approval_request_id> \
#     <tool_call_id> <arguments_digest> <payload_sha> <approve|deny> \
#     <local-read|local-build|branch-work> <reason>
#
# `review` is read-only: it prints the complete reviewed payload for the
# bound conductor (prompt-occurrence.py proposal --show), satisfying
# PILOT-REPORT.md finding #1's "read step" without ever putting a registry
# path in the orchestrator's own bash argv. `decide` is the only path that
# writes a decision, and only after re-verifying every one of the five
# authorization clauses below from scratch.
#
# Authorization (ALL required; every clause has a negative test in
# verify-orch-child-approve.sh):
#   1. Caller identity comes from process ANCESTRY (lib/pane-guard.sh
#      caller_pane_from_ancestry), NEVER from $HERDR_PANE_ID -- and that
#      pane must be BOTH the live roles['orchestrator@*'] holder AND the
#      live holder of a proj:<child's repo> claim, at its exact live
#      pane+birth (_pg_bound_orchestrator_eligible, reused bit for bit --
#      claim_holder alone already excludes an expired or superseded-by-
#      regrant claim, so "live" here already means current generation).
#   2. The child task row's conductor_pane_id/birth must equal the caller's
#      pane+birth, the task must be non-terminal (starting|running|blocked),
#      and the eligibility check in (1) is run against the CHILD's OWN repo
#      -- never an argument the caller supplies -- so a claim held for a
#      DIFFERENT repo cannot authorize this child (cross-project refused).
#   3. The exact pending request -- approval_request_id + tool_call_id +
#      arguments digest + payload sha -- must match the one live occurrence
#      (prompt-occurrence.py `proposal`), re-verified a second time
#      immediately before the decision is written (stale, replayed, or
#      already-resolved refused both times).
#   4. For an Approve of a bash/shell occurrence, the CANONICAL bound
#      command (never painted screen text -- there is none to paint) must
#      classify non-deny and non-reserved via the EXISTING, unmodified
#      classify_command/conductor_reserved_reason -- identical gate to
#      herdr-select.sh's own bound-bash path. A Deny executes nothing, so
#      it is exempt (same rationale as herdr-select.sh).
#   5. decision in {approve, deny}; category in {local-read, local-build,
#      branch-work} -- a narrower set than herdr-select.sh's human/Main
#      conductor path (no owned-cleanup): an orchestrator may approve
#      routine child work only.
#
# Exit codes mirror herdr-select.sh: 2 usage, 7 pane recycled since
# registration, 8 refused by policy or authority. Every refusal and every
# decision writes an audit event (orch_child_approval_refused /
# orch_child_approval_decided) via the shared append_event ledger.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
[ -r "$here/config.sh" ] && . "$here/config.sh" >/dev/null 2>&1
. "$here/lib/pane-guard.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/claims.sh"
. "$here/lib/command-policy.sh"

# Sourceable reuse: when ORCH_CHILD_LIB_SOURCED=1 is set BEFORE this file is
# sourced (not executed), the libs above load but orch_approve_child_main is
# NOT auto-invoked -- a caller (orch-dispatch-child.sh's `decide`
# subcommand) calls it directly in-process, with its OWN fixed argv, after
# that caller has already sourced the identical lib set and performed the
# identical ancestry/eligibility checks. This is plain function reuse, not
# a second copy of the authorization logic: every check below is unchanged.
orch_approve_child_main() {

_usage() {
  echo "usage: orch-approve-child.sh review <child_pane> <approval_request_id> <tool_call_id> <arguments_digest>" >&2
  echo "       orch-approve-child.sh decide <child_pane> <approval_request_id> <tool_call_id> <arguments_digest> <payload_sha> <approve|deny> <local-read|local-build|branch-work> <reason>" >&2
  exit 2
}

cmd="${1:-}"; [ -n "$cmd" ] || _usage
case "$cmd" in review|decide) ;; *) _usage ;; esac
child_pane="${2:?child pane required}"
request_id="${3:?approval_request_id required}"
case "$cmd" in
  review) [ $# -eq 5 ] || _usage ;;
  decide) [ $# -eq 9 ] || _usage ;;
esac
# tool_call_id/arguments_digest are required by BOTH subcommands:
# prompt-occurrence.py's bound-lookup path refuses to even ATTEMPT a
# request-id-only lookup without them (the exact identity a bound wake
# already hands the orchestrator) -- `review` needs them for the same
# reason `decide` does, not a looser one.
tool_call_id="${4:?tool_call_id required}"
arguments_digest="${5:?arguments_digest required}"
printf '%s' "$arguments_digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || {
  echo "orch-approve-child: an exact sha256 arguments digest is required." >&2
  exit 2
}

# ---- identity: ancestry-verified caller, never env-asserted ----------------
_ORC_CALLER="$(caller_pane_from_ancestry)" || {
  echo "orch-approve-child: caller identity is unproven (not resolvable to a live herdr pane via process ancestry); refusing." >&2
  exit 8
}
_ORC_CALLER_BIRTH="$(pane_birth_now "$_ORC_CALLER" 2>/dev/null)"
[ -n "$_ORC_CALLER_BIRTH" ] || {
  echo "orch-approve-child: caller pane has no live birth fingerprint; refusing." >&2
  exit 8
}
_ORC_ROLE="$(role_for_live_pane "$_ORC_CALLER" "$_ORC_CALLER_BIRTH" 'orchestrator@' 2>/dev/null)"
[ -n "$_ORC_ROLE" ] || {
  echo "orch-approve-child: caller is not a live registered orchestrator@<project> pane." >&2
  exit 8
}

_audit() {   # type extra_json
  append_event "${_ORC_RUN:-}" "${_ORC_TASK:-}" "$1" \
    "$(jq -nc --arg child "$child_pane" --arg req "$request_id" --arg caller "$_ORC_CALLER" \
         --arg role "$_ORC_ROLE" --argjson extra "${2:-{\}}" \
         '{child_pane:$child, approval_request_id:$req, caller_pane:$caller, role:$role} + $extra')" \
    >/dev/null 2>&1 || true
}
_refuse() {   # exit_code message reason_json
  echo "orch-approve-child: $2" >&2
  _audit orch_child_approval_refused "$3"
  exit "$1"
}

_ORC_CHILD_TASK="$(task_for_pane "$child_pane" 2>/dev/null)"
_ORC_RUN="$(printf '%s' "$_ORC_CHILD_TASK" | jq -r '.run_id // empty' 2>/dev/null)"
_ORC_TASK="$(printf '%s' "$_ORC_CHILD_TASK" | jq -r '.task_id // empty' 2>/dev/null)"
_ORC_WORKTREE="$(printf '%s' "$_ORC_CHILD_TASK" | jq -r '.worktree // empty' 2>/dev/null)"
_ORC_CHILD_BIRTH="$(printf '%s' "$_ORC_CHILD_TASK" | jq -r '.pane_birth // empty' 2>/dev/null)"
_ORC_REPO="$(printf '%s' "$_ORC_CHILD_TASK" | jq -r '.repo // empty' 2>/dev/null)"
_ORC_STATE="$(printf '%s' "$_ORC_CHILD_TASK" | jq -r '.state // empty' 2>/dev/null)"
_ORC_OWNER_PANE="$(printf '%s' "$_ORC_CHILD_TASK" | jq -r '.conductor_pane_id // empty' 2>/dev/null)"
_ORC_OWNER_BIRTH="$(printf '%s' "$_ORC_CHILD_TASK" | jq -r '.conductor_pane_birth // empty' 2>/dev/null)"

[ -n "$_ORC_RUN" ] && [ -n "$_ORC_TASK" ] && [ -n "$_ORC_WORKTREE" ] ||
  _refuse 8 "$child_pane is not a registered task." '{"reason":"not_registered"}'
case "$_ORC_STATE" in
  starting|running|blocked) ;;
  *) _refuse 8 "$child_pane's task is not active (non-terminal required, is '$_ORC_STATE')." '{"reason":"task_terminal"}' ;;
esac
[ "$_ORC_OWNER_PANE" = "$_ORC_CALLER" ] && [ -n "$_ORC_OWNER_BIRTH" ] && [ "$_ORC_OWNER_BIRTH" = "$_ORC_CALLER_BIRTH" ] ||
  _refuse 8 "caller is not this child's live registered conductor." '{"reason":"not_conductor"}'
_ORC_REPO_REAL="$(cd "$_ORC_REPO" 2>/dev/null && pwd -P)"; [ -n "$_ORC_REPO_REAL" ] || _ORC_REPO_REAL="$_ORC_REPO"
_pg_bound_orchestrator_eligible "$_ORC_CALLER" "$_ORC_REPO_REAL" ||
  _refuse 8 "caller holds no live orchestrator role + proj: claim for $_ORC_REPO_REAL." '{"reason":"not_eligible"}'
require_pane_birth_match "$child_pane" || {
  _audit orch_child_approval_refused '{"reason":"pane_recycled"}'
  exit 7
}
task_authorization_check "$_ORC_CHILD_TASK" ||
  _refuse 8 "${TASK_AUTHORIZATION_REASON:-task authorization unavailable; human-only hold}." \
    "$(jq -nc --arg r "${TASK_AUTHORIZATION_REASON:-unavailable}" '{reason:"task_authorization", detail:$r}')"

occ_py="$(_registry_python 2>/dev/null)" || {
  echo "orch-approve-child: no pinned python3 interpreter can verify the bound request." >&2
  exit 8
}

case "$cmd" in
  review)
    review_text="$("$occ_py" "$here/lib/prompt-occurrence.py" proposal --db "$(registry_db)" \
      --run "$_ORC_RUN" --task "$_ORC_TASK" --pane "$child_pane" --birth "$_ORC_CHILD_BIRTH" \
      --worktree "$_ORC_WORKTREE" --approval-request-id "$request_id" \
      --expect-arguments-digest "$arguments_digest" --expect-tool-call-id "$tool_call_id" --show 2>/dev/null)"
    printf '%s' "$review_text"
    case "$review_text" in REFUSED:*) exit 8 ;; esac
    exit 0
    ;;
esac

# ---- decide ------------------------------------------------------------
payload_sha="${6-}"
decision="${7-}"
category="${8-}"
reason="${9-}"

case "$decision" in
  approve) label=Approve ;;
  deny) label=Deny ;;
  *) echo "orch-approve-child: decision must be approve or deny, got '$decision'." >&2; exit 2 ;;
esac
case "$category" in
  local-read|local-build|branch-work) ;;
  *) echo "orch-approve-child: category must be local-read, local-build, or branch-work, got '$category'." >&2; exit 2 ;;
esac
[ -n "${reason//[[:space:]]/}" ] || {
  echo "orch-approve-child: a non-empty reason is required after reviewing the complete payload." >&2
  exit 2
}

printf '%s' "$payload_sha" | grep -Eq '^[0-9a-f]{64}$' || {
  echo "orch-approve-child: the exact reviewed full payload sha256 is required." >&2
  exit 2
}

_bound_proposal() {
  "$occ_py" "$here/lib/prompt-occurrence.py" proposal --db "$(registry_db)" \
    --run "$_ORC_RUN" --task "$_ORC_TASK" --pane "$child_pane" --birth "$_ORC_CHILD_BIRTH" \
    --worktree "$_ORC_WORKTREE" --approval-request-id "$request_id" \
    --expect-arguments-digest "$arguments_digest" --expect-tool-call-id "$tool_call_id" \
    --expect-sha "$payload_sha"
}
payload_json="$(_bound_proposal 2>/dev/null)"
[ "$(printf '%s' "$payload_json" | jq -r '.ok == true' 2>/dev/null)" = true ] ||
  _refuse 8 "exact bound request verification failed: $(printf '%s' "$payload_json" | jq -r '.reason // "unreadable verification result"' 2>/dev/null)" \
    "$(jq -nc --arg r "$(printf '%s' "$payload_json" | jq -r '.reason // "unreadable"' 2>/dev/null)" '{reason:"proposal_mismatch", detail:$r}')"
registry_tool_lc="$(printf '%s' "$payload_json" | jq -r '.tool // empty')"
if [ "${HERDR_BOUND_BASH:-}" = "1" ]; then
  case "$registry_tool_lc" in write|edit|bash|shell) ;; *)
    _refuse 8 "bound resolution is limited to write/edit/bash/shell (got '$registry_tool_lc')." '{"reason":"tool_not_bound"}' ;;
  esac
else
  case "$registry_tool_lc" in write|edit) ;; *)
    _refuse 8 "bound resolution is limited to write/edit (got '$registry_tool_lc')." '{"reason":"tool_not_bound"}' ;;
  esac
fi

# ---- TOCTOU re-check immediately before the durable decision ----------------
fresh_task="$(task_for_pane "$child_pane" 2>/dev/null)"
[ "$(printf '%s' "$fresh_task" | jq -r '.run_id + "\t" + .task_id + "\t" + .pane_birth')" = "$_ORC_RUN"$'\t'"$_ORC_TASK"$'\t'"$_ORC_CHILD_BIRTH" ] &&
  [ "$(printf '%s' "$fresh_task" | jq -r '.worktree // empty')" = "$_ORC_WORKTREE" ] &&
  case "$(printf '%s' "$fresh_task" | jq -r '.state // empty')" in starting|running|blocked) true ;; *) false ;; esac &&
  [ "$(printf '%s' "$fresh_task" | jq -r '.conductor_pane_id // empty')" = "$_ORC_CALLER" ] &&
  [ "$(printf '%s' "$fresh_task" | jq -r '.conductor_pane_birth // empty')" = "$_ORC_CALLER_BIRTH" ] &&
  [ "$_ORC_CALLER_BIRTH" = "$(pane_birth_now "$_ORC_CALLER" 2>/dev/null)" ] &&
  _pg_bound_orchestrator_eligible "$_ORC_CALLER" "$_ORC_REPO_REAL" &&
  require_pane_birth_match "$child_pane" && task_authorization_check "$fresh_task" ||
  _refuse 8 "task identity or orchestrator authority changed during review." '{"reason":"toctou_changed"}'
rechecked="$(_bound_proposal 2>/dev/null)"
[ "$(printf '%s' "$rechecked" | jq -r '.ok == true' 2>/dev/null)" = true ] ||
  _refuse 8 "bound request changed or expired during review." '{"reason":"proposal_changed"}'

# A Deny executes nothing, so it is never gated on the command's class
# (herdr-select.sh's own rule, fix/fleet-gate-readonly-fp): Approve stays gated.
[ "$label" = Deny ] || case "$registry_tool_lc" in
  bash|shell)
    _bound_command="$(printf '%s' "$rechecked" | jq -r '.command // empty')"
    _bound_verdict="$(classify_command "$_bound_command" "$_ORC_WORKTREE")"
    if [ "$_bound_verdict" = deny ] || [ -z "${_bound_command//[[:space:]]/}" ]; then
      _refuse 8 "bound bash command classifies deny -- binding proves identity only, never permission." '{"reason":"command_deny"}'
    fi
    _reservation="$(conductor_reserved_reason "$_bound_command")"
    if [ -n "$_reservation" ]; then
      _refuse 8 "$_reservation" "$(jq -nc --arg r "$_reservation" '{reason:"command_reserved", detail:$r}')"
    fi
    ;;
esac

log_dir="${HERDR_BRIDGE_STATE:-$HOME/.local/state/herdr-bridge}"
mkdir -p "$log_dir" || exit 2
audit_text="$(printf '%s' "$rechecked" | jq -r '.audit_text // empty' | tr '\n' ' ' | cut -c1-500)"
approval_id="$(gen_id appr)"
occ_session="$(printf '%s' "$rechecked" | jq -r '.native_session // empty')"
decided_by="orchestrator:${_ORC_ROLE}:${_ORC_CALLER}"
authorized_json="$("$occ_py" "$here/lib/prompt-occurrence.py" authorize-bound --db "$(registry_db)" \
  --run "$_ORC_RUN" --task "$_ORC_TASK" --pane "$child_pane" --birth "$_ORC_CHILD_BIRTH" \
  --session "$occ_session" --call-id "$tool_call_id" \
  --approval-request-id "$request_id" --core-arguments-digest "$arguments_digest" \
  --worktree "$_ORC_WORKTREE" --conductor-pane "$_ORC_CALLER" --conductor-birth "$_ORC_CALLER_BIRTH" \
  --approval-id "$approval_id" --choice "$label" --authority conductor \
  --decided-by "$decided_by" \
  --review-reason "$reason" --review-category "$category" --reviewer "$_ORC_CALLER" \
  --audit-text "$audit_text" --expect-payload-sha "$payload_sha" \
  2>/dev/null)" || {
    echo "orch-approve-child: failed to persist exact bound resolution -- refusing." >&2
    _audit orch_child_approval_refused '{"reason":"persist_failed"}'
    exit 2
  }
if [ "$(printf '%s' "$authorized_json" | jq -r '.written // empty' 2>/dev/null)" != authorized ]; then
  _choice_num=1; [ "$label" = Deny ] && _choice_num=2
  approval_decided "$approval_id" "$child_pane" "$request_id" "$_choice_num" "$label" \
    "$decided_by" conductor allow "$audit_text" "$_ORC_RUN" "$_ORC_TASK" >/dev/null 2>&1 || true
  approval_attempted "$approval_id" >/dev/null 2>&1 || true
  approval_confirmed "$approval_id" "lost-race" \
    "bound request was not claimed: $(printf '%s' "$authorized_json" | jq -r '.written // "unknown"')" >/dev/null 2>&1 || true
  _refuse 8 "exact bound request was not claimed; current authority or one-shot state changed." '{"reason":"not_claimed"}'
fi
approval_confirmed "$approval_id" "bound-request" \
  "mechanism=orch-child-approve request=$request_id digest=$arguments_digest" >/dev/null 2>&1 || true
_audit orch_child_approval_decided \
  "$(jq -nc --arg d "$decision" --arg c "$category" --arg r "$reason" --arg dg "$arguments_digest" \
       '{decision:$d, category:$c, reason:$r, arguments_digest:$dg}')"
jq -nc --arg request "$request_id" --arg call "$tool_call_id" --arg decision "$label" \
  '{resolved:true,approval_request_id:$request,tool_call_id:$call,decision:$decision}'
exit 0
}

[ "${ORCH_CHILD_LIB_SOURCED:-0}" = 1 ] || orch_approve_child_main "$@"
