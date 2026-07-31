#!/usr/bin/env bash
# lib/reconcile.sh — the reconciliation sweep + report, shared by
# agent-hooks/session-reconcile.sh (SessionStart, once per session) and
# agent-hooks/interval-reconcile.sh (throttled PostToolUse, mid-session). One
# copy so the two hooks can't drift on what "lost" or "already reported"
# means — exactly the reason lib/pane-guard.sh and lib/prompt-parse.sh are
# each a single sourced file instead of being copy-pasted per caller.
#
# Requires lib/run-registry.sh already sourced by the caller.
set -uo pipefail

# ---- conductor identity ------------------------------------------------------
# Best available identity, in priority order. None of these is bulletproof —
# see docs/control-plane-design.md's identity gaps — but a wrong guess here
# costs a duplicate or missed REPORT, not a misdirected keypress, so the bar
# is lower than pane-guard.sh's and a "conductor_default" fallback is an
# acceptable last resort rather than a refusal.
resolve_conductor_id() {
  local id="${HERDR_CONDUCTOR_ID:-}"
  if [ -z "$id" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    id="conductor_${HERDR_PANE_ID}"
  fi
  if [ -z "$id" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    local sess
    sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)
    [ -n "$sess" ] && id="conductor_tmux_${sess}"
  fi
  printf '%s\n' "${id:-conductor_default}"
}

# Run one reconciliation pass for a conductor: sweep every registered task for
# `lost` (non-terminal state, pane gone or pane_birth mismatch against a live
# `herdr pane list`), then report every task now in a terminal state that the
# conductor's checkpoint hasn't shown yet, and advance that checkpoint.
#
#   run_reconciliation <conductor_id> <hook_event_name> [--quiet-if-empty]
#
# Always writes the checkpoint (even when nothing changed — that write is
# also the "last ran at" clock agent-hooks/interval-reconcile.sh throttles
# against, via checkpoint_age_s). With --quiet-if-empty, prints NOTHING when
# there is nothing new — required for the interval hook, which fires every
# few minutes during a live session and must not narrate "nothing changed"
# every time. Without it (SessionStart's one-time cost), an explicit
# "no changes" line is useful confirmation that reconciliation actually ran.
run_reconciliation() {
  local conductor_id="$1" hook_event="$2" quiet=0
  [ "${3:-}" = "--quiet-if-empty" ] && quiet=1

  local live_json have_live=0
  live_json="$(herdr pane list 2>/dev/null || true)"
  if [ -n "$live_json" ] && printf '%s' "$live_json" | jq -e '(.result.panes // .panes)' >/dev/null 2>&1; then
    have_live=1
  fi
  _live_birth_for() {                   # pane_id -> terminal_id, empty if gone
    [ "$have_live" = 1 ] || { printf ''; return 0; }
    printf '%s' "$live_json" | jq -r --arg p "$1" \
      '(.result.panes // .panes)[]? | select(.pane_id==$p) | .terminal_id // empty' 2>/dev/null
  }

  local checkpoint new_checkpoint report_lines="" report_count=0
  checkpoint="$(read_checkpoint "$conductor_id")"
  new_checkpoint="$checkpoint"

  while IFS= read -r tf; do
    [ -n "$tf" ] && [ -f "$tf" ] || continue
    local task_json run_id task_id state pane_id pane_birth
    task_json="$(cat "$tf" 2>/dev/null)"
    printf '%s' "$task_json" | jq -e . >/dev/null 2>&1 || continue   # skip a torn write

    run_id=$(printf '%s' "$task_json" | jq -r '.run_id // empty')
    task_id=$(printf '%s' "$task_json" | jq -r '.task_id // empty')
    state=$(printf '%s' "$task_json" | jq -r '.state // empty')
    pane_id=$(printf '%s' "$task_json" | jq -r '.pane_id // empty')
    pane_birth=$(printf '%s' "$task_json" | jq -r '.pane_birth // empty')
    [ -n "$run_id" ] && [ -n "$task_id" ] || continue

    # ---- lost detection — only tasks that could still be alive ------------
    case "$state" in
      starting|running|blocked)
        if [ "$have_live" = 1 ] && [ -n "$pane_id" ]; then
          local live_birth reason=""
          live_birth="$(_live_birth_for "$pane_id")"
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

    # ---- report terminal states, once per (task_id, updated_at) ----------
    # Keyed by "<run_id>/<task_id>", not bare task_id: run-registry.sh's own
    # header admits task-id generation (date+pid+RANDOM) is "not
    # collision-proof across concurrent spawns". A bare-task_id key means a
    # same-named task_id from an unrelated run reported here would make this
    # conductor treat a genuinely new terminal-state task from a DIFFERENT
    # run as "already reported" the moment their task_ids happened to
    # collide — the checkpoint would silently conflate two unrelated tasks.
    # run_id is already part of every task record, so folding it into the
    # key costs nothing and removes the ambiguity entirely.
    case "$state" in
      completed|failed|blocked|lost|cancelled)
        local checkpoint_key updated_at prior_updated_at label repo
        checkpoint_key="${run_id}/${task_id}"
        updated_at=$(printf '%s' "$task_json" | jq -r '.updated_at // empty')
        prior_updated_at=$(printf '%s' "$checkpoint" | jq -r --arg t "$checkpoint_key" '.[$t].updated_at // empty')
        if [ "$prior_updated_at" != "$updated_at" ]; then
          label=$(printf '%s' "$task_json" | jq -r '.label // .task_id')
          repo=$(printf '%s' "$task_json" | jq -r '.repo // "" | split("/") | last')
          report_lines="${report_lines}- ${label} (${repo:-?}) -> ${state}  [${updated_at}]"$'\n'
          report_count=$((report_count + 1))
          new_checkpoint=$(printf '%s' "$new_checkpoint" | jq --arg t "$checkpoint_key" --arg s "$state" --arg u "$updated_at" \
            '.[$t] = {state:$s, updated_at:$u}')
        fi
        ;;
    esac
  done < <(all_task_files)

  write_checkpoint "$conductor_id" "$new_checkpoint"

  if [ "$report_count" -eq 0 ]; then
    [ "$quiet" = 1 ] && return 0
    local summary="wake-persistence: no task-state changes since this conductor (${conductor_id}) last checked in."
    printf '%s\n' "$summary"
    jq -nc --arg ev "$hook_event" --arg ctx "$summary" '{hookSpecificOutput:{hookEventName:$ev, additionalContext:$ctx}}'
    return 0
  fi

  local summary="wake-persistence: ${report_count} task(s) changed state since this conductor (${conductor_id}) last checked:"$'\n'"${report_lines%$'\n'}"
  printf '%s\n' "$summary"
  jq -nc --arg ev "$hook_event" --arg ctx "$summary" '{hookSpecificOutput:{hookEventName:$ev, additionalContext:$ctx}}'
  return 0
}
