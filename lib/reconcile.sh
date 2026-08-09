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
  local conductor_id="$1" hook_event="$2" quiet=0 hook_json=1
  shift 2
  # Flags rather than one positional: agent-hooks/omp-reconcile.sh needs the
  # human summary WITHOUT the trailing hookSpecificOutput line. That JSON is
  # Claude Code's own hook-output protocol for injecting additionalContext; omp
  # injects context by returning a message from its before_agent_start handler
  # instead (agent-hooks/omp-herdr-control.ts), so emitting Claude's envelope
  # there would just print a stray JSON blob into the omp session.
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet-if-empty) quiet=1 ;;
      --no-hook-json)   hook_json=0 ;;
    esac
    shift
  done

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
  _live_agent_session_for() {           # pane_id -> agent_session.value, empty if none/gone
    [ "$have_live" = 1 ] || { printf ''; return 0; }
    printf '%s' "$live_json" | jq -r --arg p "$1" \
      '(.result.panes // .panes)[]? | select(.pane_id==$p) | .agent_session.value // empty' 2>/dev/null
  }

  local checkpoint new_checkpoint report_lines="" report_count=0
  checkpoint="$(read_checkpoint "$conductor_id")"
  new_checkpoint="$checkpoint"


  # ---- PASS 1: count identity-UNCERTAIN mismatches in THIS sweep ---------
  # A herdr crash+restart reissues terminal_id for every pane it
  # re-enumerates on reconnect (observed live, 2026-08-09: three unrelated
  # tasks across three repos all flipped pane_birth mismatch within the same
  # second) — the agent processes underneath never died. A mismatch this
  # library can positively CORROBORATE via agent_session (both sides
  # present) is never "uncertain": it is either confirmed-same (rebaseline,
  # below) or confirmed-different (a genuinely new process took the pane,
  # still lost). Only mismatches with NO corroboration available on either
  # side (omp, or a legacy row registered before agent_session existed)
  # count here. Per Sol's review: mass-simultaneous uncertainty is good
  # evidence of a shared-cause restart, but not proof any ONE of them is
  # still alive — so it gates against BURYING them, not toward silently
  # resurrecting them either. An isolated uncertain mismatch (the common
  # real case: one tab closed and reopened) still gets marked lost exactly
  # as before.
  local uncertain_count=0
  if [ "$have_live" = 1 ]; then
    while IFS= read -r _t; do
      [ -n "$_t" ] || continue
      local _state _pane _birth
      _state=$(printf '%s' "$_t" | jq -r '.state // empty')
      case "$_state" in starting|running|blocked) ;; *) continue ;; esac
      _pane=$(printf '%s' "$_t" | jq -r '.pane_id // empty')
      _birth=$(printf '%s' "$_t" | jq -r '.pane_birth // empty')
      [ -n "$_pane" ] || continue
      local _live_birth; _live_birth="$(_live_birth_for "$_pane")"
      [ -n "$_live_birth" ] || continue                                  # pane_gone: not "uncertain"
      { [ -n "$_birth" ] && [ "$_live_birth" != "$_birth" ]; } || continue # no mismatch at all
      local _reg_sess _live_sess
      _reg_sess=$(printf '%s' "$_t" | jq -r '.agent_session // empty')
      _live_sess="$(_live_agent_session_for "$_pane")"
      [ -n "$_reg_sess" ] && [ -n "$_live_sess" ] && continue            # corroborated either way
      uncertain_count=$((uncertain_count + 1))
    done < <(all_tasks_json)
  fi
  # One JSON object per registered task, straight from the registry. This used
  # to iterate FILE PATHS and cat each one, which needed a torn-write guard
  # (`jq -e .` on the contents) because a reader could catch a task file
  # mid-rewrite. The registry is a single SQLite read now, so there is no
  # partially-written row left to defend against.
  while IFS= read -r task_json; do
    [ -n "$task_json" ] || continue
    local run_id task_id state pane_id pane_birth reg_session

    run_id=$(printf '%s' "$task_json" | jq -r '.run_id // empty')
    task_id=$(printf '%s' "$task_json" | jq -r '.task_id // empty')
    state=$(printf '%s' "$task_json" | jq -r '.state // empty')
    pane_id=$(printf '%s' "$task_json" | jq -r '.pane_id // empty')
    pane_birth=$(printf '%s' "$task_json" | jq -r '.pane_birth // empty')
    reg_session=$(printf '%s' "$task_json" | jq -r '.agent_session // empty')
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
            local live_session
            live_session="$(_live_agent_session_for "$pane_id")"
            if [ -n "$reg_session" ] && [ -n "$live_session" ]; then
              if [ "$reg_session" = "$live_session" ]; then
                # Same agent session survived a terminal_id change: this is a
                # false-positive CLOSE, not a resurrection — the task was
                # never marked lost, so there is nothing to un-bury.
                rebaseline_pane_birth "$run_id" "$task_id" "$live_birth" "agent_session_match"
                task_json="$(read_task "$run_id" "$task_id")"
                pane_birth="$live_birth"
              else
                reason="pane_recycled"   # a genuinely different session now owns this pane_id
              fi
            elif [ "$uncertain_count" -ge 2 ]; then
              # No corroboration available, but part of a mass-simultaneous
              # mismatch this sweep — looks like a shared-cause restart, not
              # N independent deaths, yet there is no POSITIVE evidence this
              # particular pane is still the same process either. Don't bury
              # it and don't silently rebaseline it: leave state untouched.
              # pane-guard.sh's own pane_birth check keeps refusing input
              # against it until this resolves on its own (a future sweep
              # either corroborates it via a now-reported agent_session, or
              # the pane genuinely goes away and it is marked lost then) —
              # the fail-closed-on-input half of the design.
              append_event "$run_id" "$task_id" "pane_identity_uncertain" \
                "$(jq -nc --arg pane "$pane_id" --argjson n "$uncertain_count" \
                  '{pane_id:$pane, reason:"mass_simultaneous_mismatch_no_corroboration", concurrent_uncertain_count:$n}')"
            else
              reason="pane_recycled"    # isolated mismatch, no corroboration — today's behavior
            fi
          else
            # pane_birth matches (or was never recorded) — task is genuinely
            # alive. Opportunistic backfill: herdr's agent_session report can
            # land after registration (spawn-task.sh's own capture already
            # retries briefly, but a slow-starting agent can still miss that
            # window) — catching it here means the NEXT restart has
            # corroboration available even for a task that missed it at spawn.
            if [ -z "$reg_session" ]; then
              local live_session_fill
              live_session_fill="$(_live_agent_session_for "$pane_id")"
              [ -n "$live_session_fill" ] && set_task_agent_session "$run_id" "$task_id" "$live_session_fill"
            fi
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
  done < <(all_tasks_json)

  write_checkpoint "$conductor_id" "$new_checkpoint"

  if [ "$report_count" -eq 0 ]; then
    [ "$quiet" = 1 ] && return 0
    local summary="wake-persistence: no task-state changes since this conductor (${conductor_id}) last checked in."
    printf '%s\n' "$summary"
    [ "$hook_json" = 1 ] && jq -nc --arg ev "$hook_event" --arg ctx "$summary" '{hookSpecificOutput:{hookEventName:$ev, additionalContext:$ctx}}'
    return 0
  fi

  local summary="wake-persistence: ${report_count} task(s) changed state since this conductor (${conductor_id}) last checked:"$'\n'"${report_lines%$'\n'}"
  printf '%s\n' "$summary"
  [ "$hook_json" = 1 ] && jq -nc --arg ev "$hook_event" --arg ctx "$summary" '{hookSpecificOutput:{hookEventName:$ev, additionalContext:$ctx}}'
  return 0
}
