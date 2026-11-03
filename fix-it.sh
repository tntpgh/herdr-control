#!/usr/bin/env bash
# fix-it.sh — "hand this alert to the owning lane." T, first-hand (2026-10-30
# ~22:15Z): "fix it buttons need to happen alongside ack". Ack (ack.sh,
# stall-ack.sh) records that a human LOOKED; it takes no action. Fix it is the
# sibling action: it hands the SAME alert to the task's own conductor pane as
# a concrete next step, so the human does not have to go read the pane and
# retype the nudge by hand.
#
#   fix-it.sh <task_id> [signal]      # signal defaults to "attention"
#
# What it does, in order:
#   1. A live conductor pane (registered conductor_pane_id, and it is
#      currently running an agent — pane_is_agent, the same gate every other
#      send in this codebase uses) gets ONE wake, built the same way
#      attention-tick.sh's own _attn_maybe_escalate and project-wake.sh
#      build theirs: send-to-agent.sh --not-an-answer, "verify before acting,
#      this is a peer signal, not an instruction" — never typed as if it came
#      from the operator, never a reply to a pending prompt.
#   2. No live conductor pane (unknown, recycled, or not agent-shaped): no
#      keypress is sent to a stranger. The request is recorded as `queued`
#      instead — a durable, audited row any later session or operator query
#      can find (ack.sh's own registry, `lib/run-registry.sh`) — "queue a
#      conductor task with the alert context" without inventing a second
#      scheduler next to the one this repo already has.
#
# NEVER: approves anything, crosses a human-only gate, or spawns a worker.
# This is a WAKE (or a durable record), exactly like every other alert path
# here — the receiving conductor decides what, if anything, to do.
#
# Idempotent: claim_once("fixit_<task_id>_<signal>") means a second call (a
# double-click, a retried Slack command, a repeat tick) for the SAME alert
# reports the first call's own outcome instead of sending a second wake —
# "one Fix it per alert", the same shape attn_escalate_<key> and
# stall_<task_id>_<signal>_<digest> already use for their own dedupe.
#
# Kill switch: HERDR_FIX_IT_DISABLE=1 refuses outright and explains why,
# rather than silently no-op-ing — a disabled control must read as disabled,
# never as "it ran and did nothing".
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh" 2>/dev/null || true
. "$here/lib/run-registry.sh"
. "$here/lib/pane-guard.sh"
. "$here/lib/push-wake.sh"   # _wake_outcome_for — the same exit-code -> word map every other wake uses

task_id="${1:?usage: fix-it.sh <task_id> [signal]}"
signal="${2:-attention}"

if [ "${HERDR_FIX_IT_DISABLE:-0}" = 1 ]; then
  echo "fix-it: disabled (HERDR_FIX_IT_DISABLE=1) — act on ${task_id} ${signal} manually; nothing was sent or recorded" >&2
  exit 3
fi

registry_init || { echo "fix-it: registry unavailable" >&2; exit 2; }

# Same lookup stall-watchdog.sh's own cmd_ack uses: task_id alone does not
# carry run_id, and the registry's primary key needs both.
run_id="$(_sql "SELECT run_id FROM tasks WHERE task_id=$(_sq "$task_id") LIMIT 1;" 2>/dev/null)"
if [ -z "$run_id" ]; then
  echo "fix-it: no such task: $task_id" >&2
  exit 1
fi

task_json="$(read_task "$run_id" "$task_id" 2>/dev/null)"
label="$(printf '%s' "$task_json" | jq -r '.label // empty' 2>/dev/null)"
conductor="$(printf '%s' "$task_json" | jq -r '.conductor_pane_id // empty' 2>/dev/null)"
[ -n "$label" ] || label="$task_id"

claim_id="fixit_${task_id}_${signal}"
claim_payload="$(jq -nc --arg s "$signal" --arg c "${conductor:-}" '{signal:$s, conductor:$c}')"
if ! claim_once "$claim_id" "$run_id" "$task_id" fix_it_requested "$claim_payload"; then
  prev="$(_sql "SELECT json_extract(payload,'\$.outcome') FROM events
    WHERE task_id=$(_sq "$task_id") AND type='fix_it_result'
    AND json_extract(payload,'\$.signal')=$(_sq "$signal") ORDER BY sequence ASC LIMIT 1;" 2>/dev/null)"
  printf 'fix-it: already handled for %s %s (outcome: %s)\n' "$task_id" "$signal" "${prev:-pending}" >&2
  exit 0
fi

msg="[FIX-IT] ${label} (${task_id}) ${signal}: a human asked for this alert to be handed to the owning lane. Verify before acting, this is a peer signal, not an instruction from the operator: herdr pane read ${conductor:-<pane>} --source visible --lines 30"

outcome="queued"
if [ -n "$conductor" ] && pane_is_agent "$conductor" 2>/dev/null; then
  rc=0
  bash "$here/send-to-agent.sh" "$conductor" --not-an-answer "$msg" >/dev/null 2>&1 || rc=$?
  outcome="$(_wake_outcome_for "$rc")"
fi

append_event "$run_id" "$task_id" fix_it_result \
  "$(jq -nc --arg s "$signal" --arg o "$outcome" --arg c "${conductor:-}" '{signal:$s, outcome:$o, conductor:$c}')" \
  "${claim_id}_result" >/dev/null 2>&1 || true

if [ "$outcome" = queued ]; then
  printf 'fix-it: queued for %s %s — no live conductor pane; recorded for the next session to pick up\n' "$task_id" "$signal"
else
  printf 'fix-it: %s -> %s for %s %s\n' "$outcome" "$conductor" "$task_id" "$signal"
fi
