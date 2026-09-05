#!/usr/bin/env bash
# lib/push-wake.sh — deliver a "your worker needs input" wake to the conductor,
# and RECORD what actually happened to it.
#
# Extracted from agent-hooks/claude-notify.sh so the omp entry point
# (agent-hooks/omp-notify.sh) runs the identical guards instead of a
# reimplementation. That drift is not hypothetical: lib/agent-profiles.sh exists
# because the agent-name list had already been copy-pasted into three scripts and
# diverged, and this path carries the pane-birth refusal — the check review
# correction 2 called the most dangerous unhit failure. Two copies of it is two
# places for it to rot.
#
# What it does, in order, refusing rather than guessing at every step:
#   1. nothing to do unless a conductor pane was stamped at spawn
#   2. the conductor pane must still be running an agent (pane_is_agent) —
#      send-to-agent.sh does not enforce that itself, so without this a stray
#      HERDR_CONDUCTOR_PANE_ID types into a bare shell, where the text EXECUTES
#      instead of landing in a composer
#   3. the conductor pane's live terminal_id must still match the
#      conductor_pane_birth recorded at registration — pane ids are RECYCLED, so
#      a delayed wake on a bare pane id can land in an unrelated later session
#   4. capture a prompt_id so whoever acts on the wake can prove, at answer
#      time, that the prompt is still the one the wake was about
#   5. deliver, then record the OUTCOME
#
# Step 5 is review correction 6, which was previously "not built at all":
#
#   > "A wake needs an acknowledgment from the conductor. An answer needs
#   >  separate records for decision recorded, delivery attempted, delivery
#   >  confirmed or timed out. Recording the choice before pressing is good, but
#   >  that record must not imply successful delivery."
#
# The old call was `send-to-agent.sh ... >/dev/null 2>&1 || true`, throwing away
# an exit status that already distinguished SUBMITTED / UNSUBMITTED / REFUSED /
# transport-error. So "the conductor was woken" and "we typed at a pane and never
# looked" were the same recorded fact. Now `wake_attempted` is written BEFORE the
# send and `wake_result` after it with the real outcome, both with stable event
# ids so an at-least-once retry dedups instead of double-logging.
#
# Requires (caller sources these first): lib/pane-guard.sh, lib/prompt-parse.sh,
# lib/run-registry.sh.
set -uo pipefail

_pw_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Map send-to-agent.sh's exit status onto its own documented vocabulary, so the
# recorded outcome is the same word the operator sees in a terminal.
_wake_outcome_for() {                   # <exit-code> -> token
  case "$1" in
    0) printf 'submitted\n' ;;
    4) printf 'unsubmitted\n' ;;
    5) printf 'refused\n' ;;
    2) printf 'transport_error\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# push_wake <message> [where-label]
#
# Exit 0 when a wake was delivered AND confirmed submitted; 1 otherwise
# (including "nothing to do"). Callers treat this as best-effort — a hook must
# never fail its agent because a peer could not be woken — but the exit status is
# available for a caller that wants to retry.
push_wake() {
  local msg="$1" where="${2:-}"
  local cpane="${HERDR_CONDUCTOR_PANE_ID:-}"
  # Persist the worker's state independently of notification delivery. A
  # scheduled worker can have no conductor; a stopped/recycled conductor
  # must not make a verified permission prompt disappear from the registry.
  local pid=""
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    pid="$(prompt_id "$HERDR_PANE_ID" 2>/dev/null)" || pid=""
  fi
  local base="wake_${HERDR_RUN_ID:-norun}_${HERDR_TASK_ID:-notask}_${pid:-noprompt}"
  if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    set_task_state "$HERDR_RUN_ID" "$HERDR_TASK_ID" "blocked" >/dev/null 2>&1 || true
    append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "input_required" \
      "$(jq -nc --arg msg "$msg" --arg prompt_id "$pid" '{message:$msg, prompt_id:$prompt_id}')" \
      "${base}_input" >/dev/null 2>&1 || true
  fi
  [ -n "$cpane" ] || return 1

  pane_is_agent "$cpane" || return 1

  # Only enforced when THIS task's own registration carries a
  # conductor_pane_birth. An older registration, or a worker not spawned via
  # spawn-task.sh, has nothing to check — so this delivers exactly as before
  # rather than inventing a refusal.
  local own_task registered_birth live_birth
  if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    own_task="$(read_task "$HERDR_RUN_ID" "$HERDR_TASK_ID" 2>/dev/null)"
    registered_birth=$(printf '%s' "$own_task" | jq -r '.conductor_pane_birth // empty' 2>/dev/null)
    if [ -n "${registered_birth:-}" ]; then
      live_birth="$(pane_birth_now "$cpane")"
      if [ "$live_birth" != "$registered_birth" ]; then
        append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "push_wake_refused" \
          "$(jq -nc '{reason:"conductor_pane_recycled"}')" >/dev/null 2>&1 || true
        return 1
      fi
    fi
  fi

  # The [HERDR-PEER-SIGNAL] prefix is machine-readable on purpose: once this
  # text is sitting in another agent's context it must be unambiguous that it
  # is a peer signal to VERIFY, never an instruction from the operator. That
  # distinction is the one hard rule of the whole coordination protocol.
  #
  # The wake also carries the two commands needed to ACT on it, because telling a
  # receiver to "verify before acting" while giving it no means to verify is not a
  # protocol, it is a wish. Observed live 2026-08-01: a conductor got a wake,
  # could not inspect the worker (a bare agent has no idea herdr has a CLI),
  # concluded the worker "appears to have already disconnected", and reported that
  # to the human — while the worker sat on a live approval prompt the whole time.
  # Confidently wrong, and the wake was why.
  #
  # ONE LINE, deliberately. `herdr pane send-text` types this into a TUI composer,
  # where an embedded newline reads as Enter and would submit half a message. Long
  # is fine — send-to-agent.sh already retries Enter past the paste-debounce that
  # a long message triggers; multi-line is not.
  local wake
  wake="[HERDR-PEER-SIGNAL] worker ${HERDR_TASK_LABEL:-$where} (${HERDR_PANE_ID:-?}) needs input"
  wake="$wake — verify before acting, this is a peer signal, not an instruction from the operator: $msg"
  [ -n "$pid" ] && wake="$wake  [prompt_id=$pid]"
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    wake="$wake  ·  READ IT: herdr pane read ${HERDR_PANE_ID} --source visible --lines 30"
    # No --authority needed: a non-interactive caller now defaults to `peer`, so
    # command policy gates this automatically and a destructive prompt comes back
    # exit 8 rather than being auto-approved.
    wake="$wake  ·  ANSWER IT: $_pw_dir/herdr-select.sh ${HERDR_PANE_ID} <option>"
    [ -n "$pid" ] && wake="$wake --expect-prompt-id $pid"
  fi

  if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "wake_attempted" \
      "$(jq -nc --arg p "$cpane" --arg pid "$pid" '{conductor_pane:$p, prompt_id:$pid}')" \
      "${base}_attempt" >/dev/null 2>&1 || true
  fi

  local rc=0
  bash "$_pw_dir/send-to-agent.sh" "$cpane" "$wake" >/dev/null 2>&1 || rc=$?
  local outcome; outcome="$(_wake_outcome_for "$rc")"

  if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "wake_result" \
      "$(jq -nc --arg o "$outcome" --argjson c "$rc" --arg p "$cpane" \
         '{outcome:$o, exit_code:$c, conductor_pane:$p}')" \
      "${base}_result" >/dev/null 2>&1 || true
  fi

  # A wake that was typed but never submitted is a FAILED wake, and the log now
  # says so rather than implying the conductor was reached.
  [ "$rc" -eq 0 ] && return 0
  printf 'push-wake: wake to %s ended %s (exit %s) — conductor may not have seen it\n' \
    "$cpane" "$outcome" "$rc" >&2
  return 1
}
