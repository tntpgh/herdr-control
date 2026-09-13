#!/usr/bin/env bash
# live-status.sh — derive a task's status from GROUND TRUTH at read time instead
# of trusting the copy stored in the registry.
#
# Provides: live_pane_status <pane_id>      -> working|idle|blocked|done|gone
#           derived_task_state <task_json>  -> the state to SHOW
#           live_status_json                -> one snapshot, all live panes
#
# Why this exists (three failures in one evening, 2026-09-12):
#   - a task sat `blocked` in the registry while its pane was idle: nothing
#     transitions a task whose worker simply goes quiet. #59 clears `blocked`
#     only when a prompt is ANSWERED.
#   - a task sat `running` while its PR had been merged for hours.
#   - a worker abandoned a five-item review brief and went idle; that is
#     indistinguishable from "working" in every surface we have, so it was
#     noticed an hour later, by a human asking.
#
# herdr already knows: `herdr pane list` carries `agent_status` per pane, live.
# We were copying that into `tasks.state` at event time and then trusting the
# copy — and every derived copy of a fact eventually disagrees with the fact
# (the same shape as the sentinel checker reading `healthy` off a stale audit
# row). So: the registry keeps what herdr CANNOT know — which task, which
# brief, what the worker owes — and herdr stays authoritative for liveness.
#
# The one state herdr cannot supply is the interesting one: STALLED. A pane
# that is idle can mean "finished cleanly" or "died mid-thought", and the
# discriminator is the worker's own completion event. Idle + no completion
# event + no prompt on screen = stalled, and stalled is a person's problem.
[ -n "${_HERDR_LIVE_STATUS_SH:-}" ] && return 0
_HERDR_LIVE_STATUS_SH=1
_ls_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_ls_dir/handoff.sh"

# One pane-list read per caller, cached for the life of the process: every
# consumer here wants the same snapshot, and three scripts each shelling out
# to herdr for it is how the copies started.
_LS_SNAPSHOT=""
live_status_json() {
  [ -n "$_LS_SNAPSHOT" ] && { printf '%s' "$_LS_SNAPSHOT"; return 0; }
  _LS_SNAPSHOT="$(herdr pane list 2>/dev/null || printf '')"
  printf '%s' "$_LS_SNAPSHOT"
}

# gone = herdr has no such pane (closed, or the whole server restarted).
# Distinguished from `idle` on purpose: gone is reconcilable, idle is not.
live_pane_status() {                    # <pane_id> -> status token
  local pane="$1" snap
  [ -n "$pane" ] || { printf 'gone\n'; return 0; }
  snap="$(live_status_json)"
  [ -n "$snap" ] || { printf 'unknown\n'; return 0; }   # herdr unreachable: say so, never guess
  printf '%s' "$snap" | jq -r --arg p "$pane" '
    ((.result.panes // .panes)[]? | select(.pane_id==$p) | .agent_status // "idle")
    // "gone"' 2>/dev/null | head -1
}

# The state a human should SEE for a task. Registry state is used only for the
# terminal facts herdr cannot know (completed/failed/cancelled/lost) and for
# task identity; everything else is derived.
# $2 (optional) = epoch seconds when this worker was last handed a brief.
# Completion evidence older than that describes a PREVIOUS round: a worker that
# finished round one, took a review brief and went quiet still carries round
# one's `_done` event, and judging evidence without that comparison reports it
# completed (PR #313, 2026-09-12 — five review findings dropped, invisible).
derived_task_state() {                  # <task_json> [asked_at_epoch] -> state
  local t="$1" asked="${2:-}" stored pane live wt
  stored=$(printf '%s' "$t" | jq -r '.state // empty')
  case "$stored" in
    completed|failed|cancelled|lost) printf '%s\n' "$stored"; return 0 ;;
  esac
  pane=$(printf '%s' "$t" | jq -r '.pane_id // empty')
  wt=$(printf '%s' "$t" | jq -r '.worktree // empty')
  live="$(live_pane_status "$pane")"
  case "$live" in
    unknown) printf '%s\n' "$stored" ;;               # herdr down: fall back, do not invent
    gone)    printf 'gone\n' ;;                        # reconcile owns the verdict
    blocked) printf 'blocked\n' ;;
    working) printf 'running\n' ;;
    idle|done)
      # Finished cleanly, or abandoned? The worker's own completion evidence is
      # the only thing that distinguishes them.
      local ev; ev="$(_evidence_mtime "$wt")"
      if [ -z "$ev" ]; then printf 'stalled\n'
      elif [ -n "$asked" ] && [ "$ev" -lt "$asked" ]; then printf 'stalled\n'
      else printf 'completed\n'; fi ;;
    *) printf '%s\n' "${stored:-unknown}" ;;
  esac
}

# A completion event for ANY task in this worktree's bus. Deliberately not
# per-task: one worktree is one task by construction (spawn-task.sh), and a
# stricter match would read as "no evidence" for every worker that labelled its
# event slightly differently, which is the failure mode this is meant to catch.
# Epoch seconds of the newest bus file carrying completion evidence, or empty.
# mtime rather than a parsed timestamp: the bus is append-only and not every
# event carries one, so the file's last write IS the last evidence.
_evidence_mtime() {                     # <worktree> -> epoch | empty
  local f newest="" m
  [ -n "${1:-}" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qE '"event"[[:space:]]*:[[:space:]]*"[^"]*_done"' "$f" 2>/dev/null || continue
    m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || continue
    [ -z "$newest" ] || [ "$m" -gt "$newest" ] && newest="$m"
  done < <(handoff_event_files "$1" 2>/dev/null)
  printf '%s' "$newest"
}
