#!/usr/bin/env bash
# orch-dispatch-child.sh — structured, fixed-argv entry point letting a LIVE
# bound orchestrator@<project> pane (1) deliver a brief/message to its OWN
# registered child and (2) decide its child's bound approval, without Main.
#
# Incident (thurber-os/.handoffs/closed-panes/website-pilot-r5/
# REGRESSION-CASE-orch-dispatch.md; pilot METRICS.md, 2026-10-18): a
# hook-mode orchestrator's own bash tool refuses EVERY shape of dispatching
# send-to-agent.sh itself -- a bare call escalates on its own quoting/
# length, and any wrapper script that EXECS send-to-agent.sh (or
# orch-approve-child.sh's `decide`, with its long hex-bearing argv) as a
# SEPARATE local file is classified "nested: runs other local files" (the
# command does not bind one reviewable file, it binds two). Neither half of
# spawn -> kick off -> supervise -> approve child work was reachable without
# a conductor/Main relay, defeating the point of hook mode.
#
# This script never execs another local file. It SOURCES send-to-agent.sh
# and orch-approve-child.sh as libraries (SEND_TO_AGENT_LIB_SOURCED=1 /
# ORCH_CHILD_LIB_SOURCED=1 suppress their own auto-invoke) and calls their
# unmodified, already-reviewed functions in-process, so the orchestrator's
# own bash call is always this ONE file. Variable-length content (the
# kickoff message; decide's digest/sha/reason) never sits in argv -- it is
# a FILE the orchestrator already wrote under its OWN worktree with the
# `write` tool (the one write path hook mode already has), named on a
# short, fixed argv identical in shape to orch-approve-child.sh's own
# `review` call (proven to work live in the pilot).
#
# Usage:
#   orch-dispatch-child.sh kickoff <child_pane> <message_file>
#   orch-dispatch-child.sh decide  <child_pane> <payload_file>
#     message_file: plain text, <= 64KiB, delivered verbatim (--not-an-answer:
#       a kickoff is never recorded as answering a live CONDUCTOR: request).
#     payload_file: JSON object with approval_request_id, tool_call_id,
#       arguments_digest ("sha256:<64 hex>"), payload_sha (bare 64 hex),
#       decision ("approve"|"deny"), category ("local-read"|"local-build"|
#       "branch-work"), reason (non-empty) -- exactly orch-approve-child.sh
#       decide's own argument set, moved from argv into one file.
#
# Authorization (ALL required; every clause has a negative test in
# verify-orch-child-dispatch.sh):
#   1. Caller identity from process ANCESTRY (lib/pane-guard.sh
#      caller_pane_from_ancestry), NEVER $HERDR_PANE_ID.
#   2. Caller is the live roles['orchestrator@*'] holder AND the live
#      holder of a proj:<child's repo> claim, at its exact live pane+birth
#      (_pg_bound_orchestrator_eligible -- unexpired, current generation;
#      claim_holder only ever returns the live row for a scope).
#   3. The child task is registered, non-terminal, its conductor_pane_id/
#      birth equal the caller's live pane+birth (the caller's own task,
#      same run_id), and task_authorization_check passes -- re-verified a
#      second time (TOCTOU) immediately before acting.
#   4. <message_file>/<payload_file> must resolve (realpath) inside the
#      CALLER's OWN registered worktree -- never a sibling's, never a path
#      outside any worktree -- so this is never a cross-worktree read
#      primitive (the exact write-scope boundary that blocked the
#      conductor-relay workaround in the pilot).
#   5. decide reuses orch-approve-child.sh's unmodified authorization chain
#      and command-classify gate verbatim (Approve of a bash/shell
#      occurrence must classify non-deny/non-reserved; Deny is exempt) --
#      this script adds NO new decision logic, only a file-based argv.
#
# Exit codes mirror orch-approve-child.sh: 2 usage, 7 pane recycled since
# registration, 8 refused by policy or authority. Every refusal and every
# action writes an audit event (orch_child_dispatch_refused/_delivered, or
# orch-approve-child.sh's own orch_child_approval_* for decide) via the
# shared append_event ledger.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
[ -r "$here/config.sh" ] && . "$here/config.sh" >/dev/null 2>&1
. "$here/lib/pane-guard.sh"
. "$here/lib/run-registry.sh"
. "$here/lib/claims.sh"
. "$here/lib/command-policy.sh"
export SEND_TO_AGENT_LIB_SOURCED=1
. "$here/send-to-agent.sh"
export ORCH_CHILD_LIB_SOURCED=1
. "$here/orch-approve-child.sh"

_usage() {
  echo "usage: orch-dispatch-child.sh kickoff <child_pane> <message_file>" >&2
  echo "       orch-dispatch-child.sh decide  <child_pane> <payload_file>" >&2
  exit 2
}

cmd="${1:-}"; [ -n "$cmd" ] || _usage
case "$cmd" in kickoff|decide) ;; *) _usage ;; esac
[ $# -eq 3 ] || _usage
child_pane="${2:?child pane required}"
data_file="${3:?file required}"

# ---- identity: ancestry-verified caller, never env-asserted ----------------
_ODC_CALLER="$(caller_pane_from_ancestry)" || {
  echo "orch-dispatch-child: caller identity is unproven (not resolvable to a live herdr pane via process ancestry); refusing." >&2
  exit 8
}
_ODC_CALLER_BIRTH="$(pane_birth_now "$_ODC_CALLER" 2>/dev/null)"
[ -n "$_ODC_CALLER_BIRTH" ] || {
  echo "orch-dispatch-child: caller pane has no live birth fingerprint; refusing." >&2
  exit 8
}
_ODC_ROLE="$(role_for_live_pane "$_ODC_CALLER" "$_ODC_CALLER_BIRTH" 'orchestrator@' 2>/dev/null)"
[ -n "$_ODC_ROLE" ] || {
  echo "orch-dispatch-child: caller is not a live registered orchestrator@<project> pane." >&2
  exit 8
}

_odc_audit() {   # type extra_json
  append_event "${_ODC_RUN:-}" "${_ODC_TASK:-}" "$1" \
    "$(jq -nc --arg child "$child_pane" --arg caller "$_ODC_CALLER" --arg cmd "$cmd" \
         --arg role "$_ODC_ROLE" --argjson extra "${2:-{\}}" \
         '{child_pane:$child, caller_pane:$caller, cmd:$cmd, role:$role} + $extra')" \
    >/dev/null 2>&1 || true
}
_odc_refuse() {   # exit_code message reason_json
  echo "orch-dispatch-child: $2" >&2
  _odc_audit orch_child_dispatch_refused "$3"
  exit "$1"
}

# ---- caller's OWN task (bounds <data_file> and proves "same run") --------
_ODC_CALLER_TASK="$(task_for_pane "$_ODC_CALLER" 2>/dev/null)"
_ODC_CALLER_RUN="$(printf '%s' "$_ODC_CALLER_TASK" | jq -r '.run_id // empty' 2>/dev/null)"
_ODC_CALLER_WORKTREE="$(printf '%s' "$_ODC_CALLER_TASK" | jq -r '.worktree // empty' 2>/dev/null)"
[ -n "$_ODC_CALLER_WORKTREE" ] ||
  _odc_refuse 8 "caller is not a registered task (no own worktree to bound $data_file to)." '{"reason":"caller_not_registered"}'
_ODC_CALLER_WT_REAL="$(cd "$_ODC_CALLER_WORKTREE" 2>/dev/null && pwd -P)"
[ -n "$_ODC_CALLER_WT_REAL" ] ||
  _odc_refuse 8 "caller's registered worktree $_ODC_CALLER_WORKTREE does not exist." '{"reason":"caller_worktree_missing"}'

# ---- child task -------------------------------------------------------------
_ODC_CHILD_TASK="$(task_for_pane "$child_pane" 2>/dev/null)"
_ODC_RUN="$(printf '%s' "$_ODC_CHILD_TASK" | jq -r '.run_id // empty' 2>/dev/null)"
_ODC_TASK="$(printf '%s' "$_ODC_CHILD_TASK" | jq -r '.task_id // empty' 2>/dev/null)"
_ODC_WORKTREE="$(printf '%s' "$_ODC_CHILD_TASK" | jq -r '.worktree // empty' 2>/dev/null)"
_ODC_CHILD_BIRTH="$(printf '%s' "$_ODC_CHILD_TASK" | jq -r '.pane_birth // empty' 2>/dev/null)"
_ODC_REPO="$(printf '%s' "$_ODC_CHILD_TASK" | jq -r '.repo // empty' 2>/dev/null)"
_ODC_STATE="$(printf '%s' "$_ODC_CHILD_TASK" | jq -r '.state // empty' 2>/dev/null)"
_ODC_OWNER_PANE="$(printf '%s' "$_ODC_CHILD_TASK" | jq -r '.conductor_pane_id // empty' 2>/dev/null)"
_ODC_OWNER_BIRTH="$(printf '%s' "$_ODC_CHILD_TASK" | jq -r '.conductor_pane_birth // empty' 2>/dev/null)"

[ -n "$_ODC_RUN" ] && [ -n "$_ODC_TASK" ] && [ -n "$_ODC_WORKTREE" ] ||
  _odc_refuse 8 "$child_pane is not a registered task." '{"reason":"not_registered"}'
case "$_ODC_STATE" in
  starting|running|blocked) ;;
  *) _odc_refuse 8 "$child_pane's task is not active (non-terminal required, is '$_ODC_STATE')." '{"reason":"task_terminal"}' ;;
esac
[ -n "$_ODC_CALLER_RUN" ] && [ "$_ODC_RUN" = "$_ODC_CALLER_RUN" ] ||
  _odc_refuse 8 "$child_pane is not registered in the caller's own run." '{"reason":"other_run"}'
[ "$_ODC_OWNER_PANE" = "$_ODC_CALLER" ] && [ -n "$_ODC_OWNER_BIRTH" ] && [ "$_ODC_OWNER_BIRTH" = "$_ODC_CALLER_BIRTH" ] ||
  _odc_refuse 8 "caller is not this child's live registered conductor." '{"reason":"not_conductor"}'
_ODC_REPO_REAL="$(cd "$_ODC_REPO" 2>/dev/null && pwd -P)"; [ -n "$_ODC_REPO_REAL" ] || _ODC_REPO_REAL="$_ODC_REPO"
_pg_bound_orchestrator_eligible "$_ODC_CALLER" "$_ODC_REPO_REAL" ||
  _odc_refuse 8 "caller holds no live orchestrator role + proj: claim for $_ODC_REPO_REAL." '{"reason":"not_eligible"}'
require_pane_birth_match "$child_pane" || {
  _odc_audit orch_child_dispatch_refused '{"reason":"pane_recycled"}'
  exit 7
}
task_authorization_check "$_ODC_CHILD_TASK" ||
  _odc_refuse 8 "${TASK_AUTHORIZATION_REASON:-task authorization unavailable; human-only hold}." \
    "$(jq -nc --arg r "${TASK_AUTHORIZATION_REASON:-unavailable}" '{reason:"task_authorization", detail:$r}')"

# ---- <data_file> must resolve inside the CALLER'S OWN worktree ------------
case "$data_file" in
  /*) _ODC_DF_ABS="$data_file" ;;
  *) _ODC_DF_ABS="$PWD/$data_file" ;;
esac
_ODC_DF_DIR_REAL="$(cd "$(dirname "$_ODC_DF_ABS")" 2>/dev/null && pwd -P)"
[ -n "$_ODC_DF_DIR_REAL" ] ||
  _odc_refuse 8 "$data_file's directory does not exist." '{"reason":"file_missing"}'
_ODC_DF_REAL="$_ODC_DF_DIR_REAL/$(basename "$_ODC_DF_ABS")"
case "$_ODC_DF_REAL" in
  "$_ODC_CALLER_WT_REAL"/*) ;;
  *) _odc_refuse 8 "$data_file does not resolve inside the caller's own worktree $_ODC_CALLER_WT_REAL." '{"reason":"file_outside_worktree"}' ;;
esac
[ -f "$_ODC_DF_REAL" ] ||
  _odc_refuse 8 "$data_file does not exist." '{"reason":"file_missing"}'

# ---- TOCTOU re-check immediately before acting -----------------------------
_odc_recheck() {
  local fresh
  fresh="$(task_for_pane "$child_pane" 2>/dev/null)"
  [ "$(printf '%s' "$fresh" | jq -r '.run_id + "\t" + .task_id + "\t" + .pane_birth')" = "$_ODC_RUN"$'\t'"$_ODC_TASK"$'\t'"$_ODC_CHILD_BIRTH" ] &&
    [ "$(printf '%s' "$fresh" | jq -r '.worktree // empty')" = "$_ODC_WORKTREE" ] &&
    case "$(printf '%s' "$fresh" | jq -r '.state // empty')" in starting|running|blocked) true ;; *) false ;; esac &&
    [ "$(printf '%s' "$fresh" | jq -r '.conductor_pane_id // empty')" = "$_ODC_CALLER" ] &&
    [ "$(printf '%s' "$fresh" | jq -r '.conductor_pane_birth // empty')" = "$_ODC_CALLER_BIRTH" ] &&
    [ "$_ODC_CALLER_BIRTH" = "$(pane_birth_now "$_ODC_CALLER" 2>/dev/null)" ] &&
    _pg_bound_orchestrator_eligible "$_ODC_CALLER" "$_ODC_REPO_REAL" &&
    require_pane_birth_match "$child_pane" && task_authorization_check "$fresh"
}
_odc_recheck ||
  _odc_refuse 8 "task identity or orchestrator authority changed just before acting." '{"reason":"toctou_changed"}'

case "$cmd" in
  kickoff)
    # Bounded size: the write tool already wrote this file; a runaway size
    # here would be a bug in the caller, not something to silently truncate.
    _ODC_SZ="$(wc -c < "$_ODC_DF_REAL" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$_ODC_SZ" ] && [ "$_ODC_SZ" -gt 0 ] && [ "$_ODC_SZ" -le 65536 ] ||
      _odc_refuse 8 "$data_file is empty or over the 64KiB kickoff message ceiling." '{"reason":"message_size"}'
    _odc_message="$(cat "$_ODC_DF_REAL")"
    [ -n "${_odc_message//[[:space:]]/}" ] ||
      _odc_refuse 8 "$data_file is empty after trimming whitespace." '{"reason":"message_empty"}'
    out="$(send_to_agent_run "$child_pane" --not-an-answer "$_odc_message" 2>&1)"; src=$?
    printf '%s\n' "$out"
    if [ "$src" -eq 0 ]; then
      _odc_audit orch_child_dispatch_delivered \
        "$(jq -nc --arg s "$(printf '%s' "$_odc_message" | shasum -a 256 | cut -d' ' -f1)" '{message_sha256:$s}')"
    else
      _odc_audit orch_child_dispatch_refused \
        "$(jq -nc --arg rc "$src" '{reason:"send_to_agent_failed", exit_code:$rc}')"
    fi
    exit "$src"
    ;;
  decide)
    _odc_payload="$(cat "$_ODC_DF_REAL" 2>/dev/null)"
    _odc_req="$(printf '%s' "$_odc_payload" | jq -r '.approval_request_id // empty' 2>/dev/null)"
    _odc_call="$(printf '%s' "$_odc_payload" | jq -r '.tool_call_id // empty' 2>/dev/null)"
    _odc_digest="$(printf '%s' "$_odc_payload" | jq -r '.arguments_digest // empty' 2>/dev/null)"
    _odc_sha="$(printf '%s' "$_odc_payload" | jq -r '.payload_sha // empty' 2>/dev/null)"
    _odc_decision="$(printf '%s' "$_odc_payload" | jq -r '.decision // empty' 2>/dev/null)"
    _odc_category="$(printf '%s' "$_odc_payload" | jq -r '.category // empty' 2>/dev/null)"
    _odc_reason="$(printf '%s' "$_odc_payload" | jq -r '.reason // empty' 2>/dev/null)"
    [ -n "$_odc_req" ] && [ -n "$_odc_call" ] && [ -n "$_odc_digest" ] && [ -n "$_odc_sha" ] &&
      [ -n "$_odc_decision" ] && [ -n "$_odc_category" ] && [ -n "$_odc_reason" ] ||
      _odc_refuse 2 "$data_file is missing a required field (approval_request_id/tool_call_id/arguments_digest/payload_sha/decision/category/reason)." '{"reason":"payload_malformed"}'
    orch_approve_child_main decide "$child_pane" "$_odc_req" "$_odc_call" "$_odc_digest" "$_odc_sha" "$_odc_decision" "$_odc_category" "$_odc_reason"
    exit $?
    ;;
esac
