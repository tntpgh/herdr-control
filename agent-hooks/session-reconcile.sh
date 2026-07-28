#!/usr/bin/env bash
# session-reconcile.sh — SessionStart hook: make wake-on-evidence PERSISTENT
# across conductor sessions.
#
# wake-on-evidence.sh only exists for as long as the Claude Code session that
# `run_in_background`'d it. When that session ends, the poller dies with it,
# and nothing re-arms it — a reopened session starts blind to every event a
# worker wrote in the meantime (observed: five agents finished unnoticed in
# one session). The registry (lib/run-registry.sh) is already durable; this
# hook is the missing READ on session start.
#
# Two things, run every SessionStart:
#
#  1. Reconciliation sweep — for every task not yet in a terminal state,
#     check whether its registered pane is still the SAME pane: does
#     `pane_id` still exist, and does its live `terminal_id` still match the
#     `pane_birth` fingerprint recorded at spawn? Pane ids get RECYCLED, so
#     "pane_id exists" alone is not enough. A task that fails either check
#     never reported completed/failed/cancelled on its own — it is `lost`,
#     a distinct terminal state, not silently folded into `completed`.
#     This is the reconciliation half of "push for responsiveness + periodic
#     reconciliation for correctness" (docs/control-plane-design.md, #1) —
#     the push edge (agent-hooks/claude-notify.sh) only fires while a worker
#     is alive to fire it.
#
#  2. Report — every task now in a terminal state (completed/failed/blocked/
#     lost/cancelled) whose (task_id, updated_at) this conductor has not
#     already been shown gets summarized. The cursor is a per-conductor
#     checkpoint stored IN THE REGISTRY DIR (read_checkpoint/write_checkpoint
#     in lib/run-registry.sh) — never in a worktree, which can be deleted out
#     from under it — so the same completion is reported once, ever, per
#     conductor, even across restarts. At-least-once delivery, idempotent by
#     (task_id, updated_at): if a task changes state again later (e.g.
#     blocked -> completed) that IS a new thing to report and fires again.
#
# Emits hookSpecificOutput.additionalContext so the summary lands in the new
# session's context directly, not just on stdout a human has to go read.
# Never fails the session: every path exits 0.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/lib/run-registry.sh"

# ---- who is "this conductor"? -----------------------------------------------
# Best available identity, in priority order. None of these is bulletproof —
# see docs/control-plane-design.md's identity gaps — but a wrong guess here
# costs a duplicate or missed REPORT, not a misdirected keypress, so the bar
# is lower than pane-guard.sh's and a "conductor_default" fallback is an
# acceptable last resort rather than a refusal.
conductor_id="${HERDR_CONDUCTOR_ID:-}"
if [ -z "$conductor_id" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  conductor_id="conductor_${HERDR_PANE_ID}"
fi
if [ -z "$conductor_id" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
  sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)
  [ -n "$sess" ] && conductor_id="conductor_tmux_${sess}"
fi
conductor_id="${conductor_id:-conductor_default}"

# ---- live pane map (best-effort; skipped entirely if herdr is unreachable) --
# Missing liveness data must not block reporting — it only disables THIS
# run's lost-detection pass; already-registered states still get reported.
live_json="$(herdr pane list 2>/dev/null || true)"
have_live=0
if [ -n "$live_json" ] && printf '%s' "$live_json" | jq -e '(.result.panes // .panes)' >/dev/null 2>&1; then
  have_live=1
fi
live_birth_for() {                      # pane_id -> terminal_id, empty if gone
  [ "$have_live" = 1 ] || { printf ''; return 0; }
  printf '%s' "$live_json" | jq -r --arg p "$1" \
    '(.result.panes // .panes)[]? | select(.pane_id==$p) | .terminal_id // empty' 2>/dev/null
}

checkpoint="$(read_checkpoint "$conductor_id")"
new_checkpoint="$checkpoint"
report_lines=""
report_count=0

while IFS= read -r tf; do
  [ -n "$tf" ] && [ -f "$tf" ] || continue
  task_json="$(cat "$tf" 2>/dev/null)"
  printf '%s' "$task_json" | jq -e . >/dev/null 2>&1 || continue   # skip a torn write

  run_id=$(printf '%s' "$task_json" | jq -r '.run_id // empty')
  task_id=$(printf '%s' "$task_json" | jq -r '.task_id // empty')
  state=$(printf '%s' "$task_json" | jq -r '.state // empty')
  pane_id=$(printf '%s' "$task_json" | jq -r '.pane_id // empty')
  pane_birth=$(printf '%s' "$task_json" | jq -r '.pane_birth // empty')
  [ -n "$run_id" ] && [ -n "$task_id" ] || continue

  # ---- 1. lost detection — only tasks that could still be alive ------------
  case "$state" in
    starting|running|blocked)
      if [ "$have_live" = 1 ] && [ -n "$pane_id" ]; then
        live_birth="$(live_birth_for "$pane_id")"
        reason=""
        if [ -z "$live_birth" ]; then
          reason="pane_gone"
        elif [ -n "$pane_birth" ] && [ "$live_birth" != "$pane_birth" ]; then
          reason="pane_recycled"
        fi
        if [ -n "$reason" ]; then
          set_task_state "$run_id" "$task_id" "lost"
          append_event "$run_id" "$task_id" "lost_detected" \
            "$(jq -nc --arg r "$reason" --arg pane "$pane_id" '{reason:$r, pane_id:$pane}')"
          task_json="$(read_task "$run_id" "$task_id")"
          state=$(printf '%s' "$task_json" | jq -r '.state // empty')
        fi
      fi
      ;;
  esac

  # ---- 2. report terminal states, once per (task_id, updated_at) ----------
  case "$state" in
    completed|failed|blocked|lost|cancelled)
      updated_at=$(printf '%s' "$task_json" | jq -r '.updated_at // empty')
      prior_updated_at=$(printf '%s' "$checkpoint" | jq -r --arg t "$task_id" '.[$t].updated_at // empty')
      if [ "$prior_updated_at" != "$updated_at" ]; then
        label=$(printf '%s' "$task_json" | jq -r '.label // .task_id')
        repo=$(printf '%s' "$task_json" | jq -r '.repo // "" | split("/") | last')
        report_lines="${report_lines}- ${label} (${repo:-?}) -> ${state}  [${updated_at}]"$'\n'
        report_count=$((report_count + 1))
        new_checkpoint=$(printf '%s' "$new_checkpoint" | jq --arg t "$task_id" --arg s "$state" --arg u "$updated_at" \
          '.[$t] = {state:$s, updated_at:$u}')
      fi
      ;;
  esac
done < <(all_task_files)

write_checkpoint "$conductor_id" "$new_checkpoint"

if [ "$report_count" -eq 0 ]; then
  summary="wake-persistence: no task-state changes since this conductor (${conductor_id}) last checked in."
else
  summary="wake-persistence: ${report_count} task(s) changed state while no conductor was watching:"$'\n'"${report_lines%$'\n'}"
fi

printf '%s\n' "$summary"
jq -nc --arg ctx "$summary" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}'
exit 0
