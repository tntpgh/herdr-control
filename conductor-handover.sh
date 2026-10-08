#!/usr/bin/env bash
# conductor-handover.sh — give a task's (or a whole conductor's set of
# tasks') conductor authority to another live pane. Built for the case
# measured 2026-10-07: task_20261007T021346Z_91873_9846 deadlocked behind a
# blocked conductor pane (w72:p2) and nothing but a human could answer its
# worker's prompts, because conductor_pane_id/conductor_pane_birth/
# conductor_id are written once at spawn (lib/run-registry.sh register_task)
# and every conductor-authority check compares the live caller against
# exactly that row.
#
#   conductor-handover.sh --task <id>  --to <pane> --reason "<text>" [--dry-run]
#   conductor-handover.sh --from <pane> --to <pane> --reason "<text>" [--dry-run]
#
# --task hands over ONE task; --from hands over every active task whose
# current conductor_pane_id is that pane. --dry-run prints what would
# happen and writes nothing.
#
# ---- caller identity: process ancestry, never self-asserted env -----------
# The caller is resolved from caller_pane_from_ancestry (lib/pane-guard.sh),
# the first ancestor pid of this process that herdr itself reports as a
# pane's CURRENT foreground process — NOT from $HERDR_PANE_ID/$HERDR_TASK_ID
# (security review PR #252, F2: those are the caller's own environment; a
# worker can export whatever it likes, including the pane id of Main, before
# running this script). pane_is_conductor_eligible looks the resolved pane
# up in the registry directly, which a caller cannot spoof by exporting a
# variable.
#
# Allowed callers:
#   (a) the task's current live registered conductor — may give away only
#       its OWN tasks (a --from pane other than the caller's own is refused
#       unless the caller is Main);
#   (b) the designated Main (the roles table's "main" row, read via
#       lib/run-registry.sh's read_role — never an env var) — may hand over
#       any task.
# Refused: a worker pane (pane_is_conductor_eligible, lib/pane-guard.sh — the
# same judgment spawn-task.sh's conductor fallback and designate-main.sh
# (P3) use; fails closed on a registry read failure, F5) and anything whose
# identity process ancestry could not resolve at all.
#
# The target (--to) must be live and conductor-eligible by the same
# pane_is_conductor_eligible check — not a worker's own active pane, and not
# a pane herdr can't currently read (fails closed, never "eligible" for
# "couldn't tell").
#
# Each task's handover is ONE compare-and-swap (lib/run-registry.sh
# set_task_conductor): a stale or raced caller changes that task's row not
# at all, and two concurrent handovers of the same task leave exactly one
# winner. A blocked task's pending input_required prompt is re-delivered to
# the new conductor through the existing push-wake path
# (lib/push-wake.sh's HERDR_ALERT_FORCE re-entry, the same mechanism
# grace_realert and release_wake_hold already use to re-enter push_wake
# immediately) — no new sender. Both the old and new conductor then get a
# one-line best-effort [handover] notice via send-to-agent.sh; a failed
# notify is logged and never rolls back the swap already committed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/run-registry.sh
. "$HERE/lib/run-registry.sh"
# shellcheck source=lib/pane-guard.sh
. "$HERE/lib/pane-guard.sh"
# shellcheck source=lib/prompt-parse.sh
. "$HERE/lib/prompt-parse.sh"
# shellcheck source=lib/push-wake.sh
. "$HERE/lib/push-wake.sh"

# Is a given (pane, birth) pair LIVE right now? Same tri-state contract as
# designate-main.sh's _is_live (not shared code — each file's copy is one
# call to pane_birth_now, not worth extracting): rc 0 confirmed live, rc 1
# confirmed not live (herdr answered; pane gone or recycled), rc 2
# INDETERMINATE — the herdr read itself failed. Every call site below must
# refuse outright on rc 2, never fold "couldn't tell" into either live or
# dead.
_is_live() {       # pane birth -> 0 live / 1 confirmed gone / 2 indeterminate
  local pane="$1" birth="$2" live rc
  [ -n "$pane" ] || return 1
  live="$(pane_birth_now "$pane")"; rc=$?
  [ "$rc" = 0 ] || return 2
  [ -n "$live" ] || return 1
  if [ -z "$birth" ] || [ "$live" = "$birth" ]; then
    return 0
  fi
  return 1
}

task_id="" from_pane="" to_pane="" reason="" dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task) task_id="$2"; shift 2 ;;
    --task=*) task_id="${1#--task=}"; shift ;;
    --from) from_pane="$2"; shift 2 ;;
    --from=*) from_pane="${1#--from=}"; shift ;;
    --to) to_pane="$2"; shift 2 ;;
    --to=*) to_pane="${1#--to=}"; shift ;;
    --reason) reason="$2"; shift 2 ;;
    --reason=*) reason="${1#--reason=}"; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) sed -n '2,54p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "conductor-handover: unknown argument $1" >&2; exit 2 ;;
  esac
done

if { [ -n "$task_id" ] && [ -n "$from_pane" ]; } || { [ -z "$task_id" ] && [ -z "$from_pane" ]; }; then
  echo "conductor-handover: pass exactly one of --task <id> or --from <pane>" >&2
  exit 2
fi
[ -n "$to_pane" ] || { echo "conductor-handover: --to <pane> is required" >&2; exit 2; }
[ -n "${reason//[[:space:]]/}" ] || { echo "conductor-handover: --reason \"<text>\" is required" >&2; exit 2; }

# ---- caller identity: process ancestry, never self-asserted env -----------
_anc_rc=0
caller_pane="$(caller_pane_from_ancestry)" || _anc_rc=$?
if [ "$_anc_rc" != 0 ] || [ -z "$caller_pane" ]; then
  echo "conductor-handover: refusing — could not verify caller identity from process ancestry (herdr unreachable, or this process traces to no live pane)" >&2
  exit 3
fi
caller_birth="$(pane_birth_now "$caller_pane" 2>/dev/null)"
[ -n "$caller_birth" ] || { echo "conductor-handover: caller pane $caller_pane is not live" >&2; exit 3; }

# ---- refuse worker callers -------------------------------------------------
# A worker may only ever give its OWN task away through a human/conductor
# decision, never self-serve a handover of its own or anyone else's task.
# pane_is_conductor_eligible looks the ancestry-resolved pane up in the
# registry directly (fails closed on a read failure, F5) — not
# $HERDR_TASK_ID, which a worker can simply not export.
if ! pane_is_conductor_eligible "$caller_pane" 2>/dev/null; then
  echo "conductor-handover: refusing — caller pane $caller_pane is a registered worker's own active task pane, or its eligibility could not be verified" >&2
  exit 4
fi

# ---- is the caller Main? ---------------------------------------------------
# roles table's "main" row (lib/run-registry.sh read_role), never an env
# var — a worker could export HERDR_MAIN_PANE_ID=<Main's pane> to claim
# Main's authority over env, but cannot make caller_pane_from_ancestry
# resolve to anything but its own pane.
is_main=0
_main_row_j="$(read_role main 2>/dev/null)"
if [ -n "$_main_row_j" ] && [ "$_main_row_j" != null ]; then
  _main_pane="$(printf '%s' "$_main_row_j" | jq -r '.pane_id // empty')"
  _main_birth="$(printf '%s' "$_main_row_j" | jq -r '.pane_birth // empty')"
  _main_live_rc=0
  _is_live "$_main_pane" "$_main_birth" || _main_live_rc=$?
  if [ "$_main_live_rc" = 0 ] && [ "$_main_pane" = "$caller_pane" ]; then
    is_main=1
  fi
fi

# ---- target validation ------------------------------------------------------
# pane_is_conductor_eligible covers both pane_is_agent and the worker-pane
# refusal, and fails closed on a registry read failure the same as above.
if ! pane_is_conductor_eligible "$to_pane" 2>/dev/null; then
  echo "conductor-handover: refusing — target pane $to_pane is not an agent, is a registered worker's own active task pane, or its eligibility could not be verified" >&2
  exit 5
fi
_to_live_rc=0
_is_live "$to_pane" "" || _to_live_rc=$?
case "$_to_live_rc" in
  0) : ;;
  2) echo "conductor-handover: refusing — could not read target pane $to_pane's birth fingerprint (herdr read failed)" >&2; exit 5 ;;
  *) echo "conductor-handover: refusing — target pane $to_pane is gone" >&2; exit 5 ;;
esac
to_birth="$(pane_birth_now "$to_pane" 2>/dev/null)"
to_conductor_id="conductor_${to_pane}"
by="conductor_${caller_pane}"

# ---- resolve the task set --------------------------------------------------
# One row per task: task_id|run_id|current-conductor-pane|current-conductor-birth|label|worker-pane|state
if [ -n "$task_id" ]; then
  rows="$(_sql "SELECT task_id || '|' || run_id || '|' || conductor_pane_id || '|' || conductor_pane_birth || '|' || label || '|' || pane_id || '|' || state
                FROM tasks WHERE task_id=$(_sq "$task_id");" 2>/dev/null)"
  [ -n "$rows" ] || { echo "conductor-handover: no task $task_id" >&2; exit 6; }
else
  rows="$(_sql "SELECT task_id || '|' || run_id || '|' || conductor_pane_id || '|' || conductor_pane_birth || '|' || label || '|' || pane_id || '|' || state
                FROM tasks WHERE conductor_pane_id=$(_sq "$from_pane") AND state IN ('starting','running','blocked')
                ORDER BY updated_at;" 2>/dev/null)"
  [ -n "$rows" ] || { echo "conductor-handover: no active task has conductor_pane_id=$from_pane" >&2; exit 6; }
fi

ok=0 refused=0
while IFS='|' read -r t_id r_id cur_cpane cur_cbirth label worker_pane t_state; do
  [ -n "$t_id" ] || continue
  case "$t_state" in
    starting|running|blocked) ;;
    *) echo "  REFUSED $t_id ($label): task is terminal ($t_state)" >&2; refused=$((refused+1)); continue ;;
  esac
  # (a) the task's current live registered conductor, giving its own tasks
  # away — or (b) Main, giving any task away.
  if [ "$is_main" != 1 ]; then
    if [ "$cur_cpane" != "$caller_pane" ] || [ -z "$cur_cbirth" ] || [ "$cur_cbirth" != "$caller_birth" ]; then
      echo "  REFUSED $t_id ($label): caller is not this task's live registered conductor, and not Main" >&2
      refused=$((refused+1)); continue
    fi
  fi
  if [ "$dry_run" = 1 ]; then
    echo "  would hand over $t_id ($label): $cur_cpane -> $to_pane"
    ok=$((ok+1)); continue
  fi
  if ! set_task_conductor "$r_id" "$t_id" "$cur_cpane" "$cur_cbirth" "$to_pane" "$to_birth" "$to_conductor_id" \
       "$by" "$reason" 2>/dev/null; then
    echo "  REFUSED $t_id ($label): compare-and-swap lost (caller or task changed underneath)" >&2
    refused=$((refused+1)); continue
  fi
  echo "  handed over $t_id ($label): $cur_cpane -> $to_pane"
  ok=$((ok+1))

  # ---- re-wake: re-deliver any pending prompt to the new conductor --------
  if [ "$t_state" = blocked ]; then
    pending="$(_sql "SELECT json_extract(payload,'\$.prompt_id') || char(31) || json_extract(payload,'\$.message') || char(31) || json_extract(payload,'\$.command') || char(31) || json_extract(payload,'\$.tool')
                      FROM events WHERE run_id=$(_sq "$r_id") AND task_id=$(_sq "$t_id") AND type='input_required'
                      ORDER BY sequence DESC LIMIT 1;" 2>/dev/null)"
    if [ -n "$pending" ]; then
      IFS=$'\x1f' read -r p_pid p_msg p_cmd p_tool <<<"$pending"
      if [ -n "$p_pid" ]; then
        _pw_forced_wake_argv "$worker_pane" "$to_pane" "$r_id" "$t_id" "$label" \
          "${p_msg:-$label needs input}" "conductor-handover" "$p_cmd" "$p_tool"
        "${_PW_FORCED_WAKE_ARGV[@]}" >/dev/null 2>&1 || true
      fi
    fi
  fi

  # ---- notify both conductors, best-effort, never rolls back the swap -----
  bash "$HERE/send-to-agent.sh" "$cur_cpane" --not-an-answer \
    "[handover] $t_id ($label) handed to $to_pane — $reason" >/dev/null 2>&1 \
    || echo "  (notify to old conductor $cur_cpane did not land)" >&2
  bash "$HERE/send-to-agent.sh" "$to_pane" --not-an-answer \
    "[handover] $t_id ($label) handed to you from $cur_cpane — $reason" >/dev/null 2>&1 \
    || echo "  (notify to new conductor $to_pane did not land)" >&2
done <<<"$rows"

echo "-----"
if [ "$dry_run" = 1 ]; then
  echo "DRY RUN — nothing changed. would_hand_over=$ok refused=$refused"
  exit 0
fi
echo "handed_over=$ok refused=$refused"
[ "$refused" -eq 0 ] && exit 0 || exit 1
