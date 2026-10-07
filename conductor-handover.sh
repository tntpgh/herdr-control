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
# Allowed callers (HERDR_PANE_ID + its live pane birth):
#   (a) the task's current live registered conductor — may give away only
#       its OWN tasks (a --from pane other than the caller's own is refused
#       unless the caller is Main);
#   (b) the designated Main (designate-main.sh's roles/main file, read via
#       config.sh) — may hand over any task.
# Refused: a worker pane (HERDR_TASK_ID set, or the caller pane IS a
# registered worker's own active task pane) and anything else.
#
# The target (--to) must be a live, non-worker agent pane
# (validate_conductor_target_pane, lib/pane-guard.sh — the same check
# spawn-task.sh's HERDR_MCP_CONDUCTOR_PANE fallback uses, not a second copy).
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
# shellcheck source=config.sh
. "$HERE/config.sh" 2>/dev/null || true
# shellcheck source=lib/run-registry.sh
. "$HERE/lib/run-registry.sh"
# shellcheck source=lib/pane-guard.sh
. "$HERE/lib/pane-guard.sh"
# shellcheck source=lib/prompt-parse.sh
. "$HERE/lib/prompt-parse.sh"
# shellcheck source=lib/push-wake.sh
. "$HERE/lib/push-wake.sh"

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
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "conductor-handover: unknown argument $1" >&2; exit 2 ;;
  esac
done

if { [ -n "$task_id" ] && [ -n "$from_pane" ]; } || { [ -z "$task_id" ] && [ -z "$from_pane" ]; }; then
  echo "conductor-handover: pass exactly one of --task <id> or --from <pane>" >&2
  exit 2
fi
[ -n "$to_pane" ] || { echo "conductor-handover: --to <pane> is required" >&2; exit 2; }
[ -n "${reason//[[:space:]]/}" ] || { echo "conductor-handover: --reason \"<text>\" is required" >&2; exit 2; }

caller_pane="${HERDR_PANE_ID:-}"
[ -n "$caller_pane" ] || { echo "conductor-handover: no caller pane (HERDR_PANE_ID unset)" >&2; exit 2; }
caller_birth="$(pane_birth_now "$caller_pane" 2>/dev/null)"
[ -n "$caller_birth" ] || { echo "conductor-handover: caller pane $caller_pane is not live" >&2; exit 3; }

# ---- refuse worker callers -------------------------------------------------
# A worker may only ever give its OWN task away through a human/conductor
# decision, never self-serve a handover of its own or anyone else's task.
if [ -n "${HERDR_TASK_ID:-}" ]; then
  echo "conductor-handover: refusing — caller is a worker (HERDR_TASK_ID set)" >&2
  exit 4
fi
_caller_occ="$(validate_conductor_target_pane "$caller_pane" 2>/dev/null)"
if [ -n "$_caller_occ" ]; then
  echo "conductor-handover: refusing — caller pane $caller_pane: $_caller_occ" >&2
  exit 4
fi

# ---- is the caller Main? ---------------------------------------------------
is_main=0
if [ -n "${HERDR_MAIN_PANE_ID:-}" ] && [ "$HERDR_MAIN_PANE_ID" = "$caller_pane" ] \
   && [ -n "${HERDR_MAIN_PANE_BIRTH:-}" ] && [ "$HERDR_MAIN_PANE_BIRTH" = "$caller_birth" ]; then
  is_main=1
fi

# ---- target validation ------------------------------------------------------
if ! pane_is_agent "$to_pane" 2>/dev/null; then
  echo "conductor-handover: refusing — target pane $to_pane is not running an agent" >&2
  exit 5
fi
_target_reason="$(validate_conductor_target_pane "$to_pane" 2>/dev/null)"
if [ -n "$_target_reason" ]; then
  echo "conductor-handover: refusing — target pane $to_pane: $_target_reason" >&2
  exit 5
fi
to_birth="$(pane_birth_now "$to_pane" 2>/dev/null)"
[ -n "$to_birth" ] || { echo "conductor-handover: refusing — target pane $to_pane is gone" >&2; exit 5; }
to_conductor_id="conductor_${to_pane}"
by="${HERDR_CONDUCTOR_ID:-conductor_${caller_pane}}"

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
