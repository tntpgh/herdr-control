#!/usr/bin/env bash
# mark-launch-failed.sh <run_id> <task_id> [--reason TEXT] [--superseded-by <newer_task_id>]
#
# A SUPPORTED lifecycle command for exactly the shape fix/launch-receipt-r2
# exists to fix (conductor, 2026-10-29; tmp/conductor-supplied/
# registry-wB6p2.txt): a task the registry still calls `starting`/`running`
# whose pane is actually dead or a bare shell — spawn-task.sh's own
# HERDR_SPAWN_RECEIPT check (see its "Startup-failure reconciliation" block)
# only catches this at launch time; this is for a row that already slipped
# past that, or that was spawned by a stale/out-of-date copy of this repo.
#
# Transitions the row to the `launch_failed` terminal state (lib/run-
# registry.sh's `_legal_transition`) — the SAME distinct state spawn-task.sh
# itself now uses for this failure class, never the generic `failed` a
# worker that ran and then errored gets. Records WHICH of two dispositions
# applied in the audit event (`launch_failed_marked`), not as a second state:
#   launch_failed  (default) — nothing ever replaced this launch; `--reason`
#                   is free text explaining why (default: "operator-marked
#                   dead task").
#   superseded     (--superseded-by TASK_ID) — a newer task already took over
#                   this one's worktree/branch. TASK_ID must be a REAL
#                   registered task in the same run, for the same
#                   worktree+branch, created AFTER this one — re-checked
#                   here, never taken on the caller's word.
#
# DEADNESS IS RE-VERIFIED, NEVER TAKEN ON THE CALLER'S SAY-SO (same
# fail-closed shape as every other registry writer in this repo): the task's
# OWN registered pane must show a herdr-CONFIRMED answer of one of —
#   - gone entirely (pane_birth_now succeeds and returns empty),
#   - recycled (live terminal_id != the pane_birth recorded at registration),
#   - or alive but NOT running a recognized agent (pane_process_info_ok
#     succeeds, then pane_is_agent says no — lib/pane-guard.sh, a bare shell).
# A pane that IS live and running an agent refuses outright: this command
# marks a DEAD task dead, never a live one — use the normal completion path
# (set_task_state … completed) for that.
#
# A herdr CLI error or unparseable JSON is NEVER treated as evidence of
# death (security review, fix/launch-receipt-r2 round 2, 335f458: a herdr
# hiccup — server down, transient timeout — used to read identically to
# "pane confirmed gone" / "confirmed not an agent" and could bury a live
# worker). `pane_birth_now`'s own return code and the new
# `pane_process_info_ok` (lib/pane-guard.sh) tell "herdr didn't answer"
# apart from "herdr answered" before either answer is trusted; "didn't
# answer" refuses with the state left unchanged, same as a live pane does.
#
# Exit 0 marked. Exit 1 bad usage / no such task / already terminal /
# superseded-by evidence does not check out / the pane is actually alive /
# herdr could not be reached to confirm either way — every refusal names
# why on stderr, and none of them change the task's state.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"

run_id="${1:?usage: mark-launch-failed.sh <run_id> <task_id> [--reason TEXT] [--superseded-by <newer_task_id>]}"
task_id="${2:?usage: mark-launch-failed.sh <run_id> <task_id> [--reason TEXT] [--superseded-by <newer_task_id>]}"
shift 2
reason=""
superseded_by=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason)        reason="${2:?--reason requires text}"; shift 2 ;;
    --superseded-by) superseded_by="${2:?--superseded-by requires a task_id}"; shift 2 ;;
    *) echo "mark-launch-failed: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

task="$(read_task "$run_id" "$task_id")"
[ -n "$task" ] || { echo "mark-launch-failed: no task $task_id in run $run_id" >&2; exit 1; }

state="$(printf '%s' "$task" | jq -r '.state')"
case "$state" in
  completed|failed|launch_failed|cancelled|lost)
    echo "mark-launch-failed: $task_id is already terminal ($state) — nothing to mark" >&2
    exit 1 ;;
esac

pane="$(printf '%s' "$task" | jq -r '.pane_id // ""')"
reg_birth="$(printf '%s' "$task" | jq -r '.pane_birth // ""')"
if [ -z "$pane" ]; then
  dead_evidence="task has no registered pane_id"
else
  # Fail CLOSED on uncertainty, not open (security review, fix/launch-
  # receipt-r2 round 2, 335f458): a herdr CLI error or unparseable JSON
  # must never read the same as a confirmed-dead answer, or a herdr hiccup
  # (server down, transient timeout) buries a live worker. `pane_birth_now`
  # already distinguishes this via its own return code (rc 1 = herdr itself
  # failed, vs rc 0 with empty output = herdr answered and the pane is
  # genuinely absent) — this was simply never checked before.
  if ! live_birth="$(pane_birth_now "$pane" 2>/dev/null)"; then
    echo "mark-launch-failed: refusing — herdr unavailable (could not confirm whether pane $pane still exists); state left unchanged. Retry once herdr is reachable." >&2
    exit 1
  fi
  if [ -z "$live_birth" ]; then
    dead_evidence="pane $pane no longer exists"
  elif [ -n "$reg_birth" ] && [ "$live_birth" != "$reg_birth" ]; then
    dead_evidence="pane $pane was recycled (registered birth=$reg_birth live birth=$live_birth)"
  else
    # Same fail-closed-on-uncertainty rule for the foreground-process check:
    # `pane_is_agent` (lib/pane-guard.sh) alone can't tell "herdr failed"
    # apart from "herdr answered: no agent" — it is a deliberate two-state
    # boolean for send-to-agent.sh's refuse-to-send direction, where both
    # cases mean the same thing. Marking something DEAD needs the opposite
    # direction, so ask `pane_process_info_ok` first, independently.
    if ! pane_process_info_ok "$pane"; then
      echo "mark-launch-failed: refusing — herdr unavailable (could not confirm what is running in pane $pane); state left unchanged. Retry once herdr is reachable." >&2
      exit 1
    fi
    if pane_is_agent "$pane" 2>/dev/null; then
      echo "mark-launch-failed: refusing — pane $pane is alive and running an agent right now; this task is not dead. Use the normal completion path instead." >&2
      exit 1
    fi
    dead_evidence="pane $pane is alive but its foreground process is not a recognized agent (bare shell)"
  fi
fi

disposition="launch_failed"
if [ -n "$superseded_by" ]; then
  newer="$(read_task "$run_id" "$superseded_by")"
  [ -n "$newer" ] || { echo "mark-launch-failed: --superseded-by $superseded_by does not match any registered task in run $run_id" >&2; exit 1; }
  this_wt="$(printf '%s' "$task" | jq -r '.worktree // ""')"
  this_branch="$(printf '%s' "$task" | jq -r '.branch // ""')"
  this_created="$(printf '%s' "$task" | jq -r '.created_at // ""')"
  new_wt="$(printf '%s' "$newer" | jq -r '.worktree // ""')"
  new_branch="$(printf '%s' "$newer" | jq -r '.branch // ""')"
  new_created="$(printf '%s' "$newer" | jq -r '.created_at // ""')"
  if [ -z "$this_wt" ] || [ "$this_wt" != "$new_wt" ] || [ "$this_branch" != "$new_branch" ]; then
    echo "mark-launch-failed: refusing — $superseded_by (worktree=$new_wt branch=$new_branch) does not match $task_id's own worktree=$this_wt branch=$this_branch" >&2
    exit 1
  fi
  if [ -z "$new_created" ] || [ -z "$this_created" ] || ! [[ "$new_created" > "$this_created" ]]; then
    echo "mark-launch-failed: refusing — $superseded_by was not registered after $task_id (new=$new_created old=$this_created)" >&2
    exit 1
  fi
  disposition="superseded"
  [ -n "$reason" ] || reason="superseded by $superseded_by"
else
  [ -n "$reason" ] || reason="operator-marked dead task"
fi

set_task_state "$run_id" "$task_id" launch_failed || { echo "mark-launch-failed: set_task_state refused — see its own stderr" >&2; exit 1; }
append_event "$run_id" "$task_id" "launch_failed_marked" \
  "$(jq -nc --arg disposition "$disposition" --arg reason "$reason" \
      --arg dead_evidence "$dead_evidence" --arg superseded_by "$superseded_by" \
      '{disposition:$disposition, reason:$reason, dead_evidence:$dead_evidence, superseded_by:$superseded_by}')" \
  >/dev/null 2>&1 || true

printf 'mark-launch-failed: %s/%s -> launch_failed (disposition=%s): %s\n' "$run_id" "$task_id" "$disposition" "$dead_evidence"
read_task "$run_id" "$task_id"
