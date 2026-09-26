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
# send and `wake_result` after it with the real outcome. Attempt/result rows are
# APPEND-ONLY per attempt (unique attempt suffix in the event id) so a retry's
# outcome is a new fact, never swallowed by the first attempt's dedup; the
# `input_required` row alone keeps the stable per-prompt id, because "this
# prompt needs input" is one logical fact however many hooks re-observe it.
# Correlation survives via wake_key/attempt fields in each payload.
#
# Requires (caller sources these first): lib/pane-guard.sh, lib/prompt-parse.sh,
# lib/run-registry.sh.
set -uo pipefail

_pw_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Sourced here, not left to callers: the delivery gate below is a behavioural
# guarantee of push_wake itself, and a guarantee a caller can forget to load is
# not one.
. "$_pw_dir/lib/alert-gate.sh"

# Map send-to-agent.sh's exit status onto its own documented vocabulary, so the
# recorded outcome is the same word the operator sees in a terminal.
_wake_outcome_for() {                   # <exit-code> -> token
  case "$1" in
    0) printf 'submitted\n' ;;
    4) printf 'unsubmitted\n' ;;
    5|6) printf 'refused\n' ;;
    2) printf 'transport_error\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# _pw_forced_wake_argv <pane> <cpane> <run> <task> <label> <msg> <where> <full_cmd>
#
# Builds, into _PW_FORCED_WAKE_ARGV (a bash array), the exact re-entry into
# push_wake with HERDR_ALERT_FORCE=1 — the command grace_realert's own 90s
# re-check fires when a held prompt outlives its window (below). Extracted
# so an EARLY release (release_wake_hold, after push_wake below —
# herdr-select.sh calls it the moment a peer refuses a prompt push_wake
# already HELD) fires the IDENTICAL command instead of a second, driftable
# copy of it.
_pw_forced_wake_argv() {
  local pane="$1" cpane="$2" run="$3" task="$4" label="$5" msg="$6" where="$7" full_cmd="$8"
  _PW_FORCED_WAKE_ARGV=(
    env HERDR_ALERT_FORCE=1
        HERDR_PANE_ID="$pane" HERDR_CONDUCTOR_PANE_ID="$cpane"
        HERDR_RUN_ID="$run" HERDR_TASK_ID="$task"
        HERDR_TASK_LABEL="$label"
        bash -c '. "$0/lib/pane-guard.sh"; . "$0/lib/prompt-parse.sh"; . "$0/lib/run-registry.sh"; . "$0/lib/push-wake.sh"; push_wake "$1" "$2" "$3"' \
        "$_pw_dir" "$msg" "$where" "$full_cmd"
  )
}

# push_wake <message> [where-label] [full-command]
#
# full-command (project-contract-plan.md #3b, item 2) is the UNTRUNCATED
# command text behind the prompt, when the caller has it (omp-notify.sh, from
# agent-hooks/omp-herdr-control.ts's tool_approval_requested handler) — kept
# separate from `message`, which stays the display-truncated text the Slack
# alert and the conductor wake actually show. Recorded on the SAME
# input_required row so herdr-select.sh can look it up by prompt_id and
# classify complete arguments instead of whatever a wrapped TUI panel
# scraped back. Empty for every caller that does not pass it (claude-notify.sh,
# any older wiring) — same as today, no behavior change.
#
# Exit 0 when a wake was delivered AND confirmed submitted; 1 otherwise
# (including "nothing to do"). Callers treat this as best-effort — a hook must
# never fail its agent because a peer could not be woken — but the exit status is
# available for a caller that wants to retry.
push_wake() {
  local msg="$1" where="${2:-}" full_cmd="${3:-}"
  local cpane="${HERDR_CONDUCTOR_PANE_ID:-}"
  # Persist the worker's state independently of notification delivery. A
  # scheduled worker can have no conductor; a stopped/recycled conductor
  # must not make a verified permission prompt disappear from the registry.
  local pid=""
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    pid="$(prompt_id "$HERDR_PANE_ID" 2>/dev/null)" || pid=""
  fi
  local base="wake_${HERDR_RUN_ID:-norun}_${HERDR_TASK_ID:-notask}_${pid:-noprompt}"

  # ---- stale/terminal rejection — BEFORE any state change or actionable event
  # A hook can outlive the task it was stamped for: env vars survive into a
  # recycled pane's next occupant, and a hook already in flight can fire after
  # the sweep buried its task. set_task_state already refuses the illegal
  # terminal->blocked transition, but the input_required event used to be
  # appended anyway — a dead task kept generating actionable "needs input"
  # facts forever. Reject first, mutate second. The refusal is itself recorded
  # (dedup'd per logical prompt) so reconciliation surfaces it instead of the
  # hook just going quiet.
  local own_task="" own_state=""
  if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    own_task="$(read_task "$HERDR_RUN_ID" "$HERDR_TASK_ID" 2>/dev/null)"
    own_state=$(printf '%s' "$own_task" | jq -r '.state // empty' 2>/dev/null)
    case "$own_state" in
      completed|failed|cancelled|lost)
        append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "stale_worker_hook_refused" \
          "$(jq -nc --arg s "$own_state" --arg prompt_id "$pid" \
             '{reason:"task_terminal", state:$s, prompt_id:$prompt_id}')" \
          "${base}_stale" >/dev/null 2>&1 || true
        return 1
        ;;
    esac
    # Worker-side pane-birth check, mirroring the conductor-side one below:
    # refuse only on a POSITIVE mismatch (both fingerprints known and
    # different — the recycled-pane signature). An empty live reading is NOT
    # a refusal: it cannot distinguish "pane gone" from "herdr CLI hiccup",
    # and losing a real verified input request to a transient CLI failure is
    # the silent-notification disease this file exists to cure. The
    # reconcile sweep owns the pane-gone verdict.
    local reg_worker_pane reg_worker_birth live_worker_birth
    reg_worker_pane=$(printf '%s' "$own_task" | jq -r '.pane_id // empty' 2>/dev/null)
    reg_worker_birth=$(printf '%s' "$own_task" | jq -r '.pane_birth // empty' 2>/dev/null)
    if [ -n "$reg_worker_birth" ] && [ -n "${HERDR_PANE_ID:-}" ] && [ "$reg_worker_pane" = "${HERDR_PANE_ID}" ]; then
      live_worker_birth="$(pane_birth_now "$HERDR_PANE_ID" 2>/dev/null)"
      if [ -n "$live_worker_birth" ] && [ "$live_worker_birth" != "$reg_worker_birth" ]; then
        append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "stale_worker_hook_refused" \
          "$(jq -nc --arg reg "$reg_worker_birth" --arg live "$live_worker_birth" --arg prompt_id "$pid" \
             '{reason:"worker_pane_recycled", registered_birth:$reg, live_birth:$live, prompt_id:$prompt_id}')" \
          "${base}_stale" >/dev/null 2>&1 || true
        return 1
      fi
    fi
  fi

  # ---- change 5 (fix/peer-waits-for-record): corroborate before trusting.
  # Live canary, 2026-09-26 20:54:33Z: a worker issued two bash tool calls in
  # one turn; omp painted tool call A's panel first, and the hook firing for
  # tool call B fingerprinted A's still-painted panel while recording B's
  # (different) command under A's prompt_id — the row's stable per-prompt id
  # (INSERT OR IGNORE, below) means the FIRST hook's write wins, so the
  # prompt now carries a command it never showed. herdr-select.sh's own
  # short wait for this row (lib/scoped-policy.sh wait_for_input_required_row)
  # would then WAIT for and TRUST exactly that wrong text, so the
  # corroboration has to happen here, before the row is ever written — same
  # substring-of-the-panel rule herdr-select.sh and human_must_answer already
  # enforce (lib/scoped-policy.sh approval_command_text).
  local recorded_ok=1 cmd_hint=""
  if [ -n "${HERDR_PANE_ID:-}" ] && [ -n "$full_cmd" ]; then
    local panel_now
    panel_now="$(prompt_command_text "$HERDR_PANE_ID" 2>/dev/null || printf '')"
    approval_command_text "$panel_now" "$full_cmd" >/dev/null 2>&1 || recorded_ok=0
  fi
  if [ "$recorded_ok" = 0 ]; then
    cmd_hint="$(printf '%s' "$full_cmd" | cut -c1-200)"
    # An uncorroborated command must not reach human_must_answer below
    # either — the gate that decides who is woken has to judge the same
    # (absent) text this row now carries, never the mismatched one nobody's
    # screen shows.
    full_cmd=""
  fi
  if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    set_task_state "$HERDR_RUN_ID" "$HERDR_TASK_ID" "blocked" >/dev/null 2>&1 || true
    if [ "$recorded_ok" = 0 ]; then
      append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "input_required" \
        "$(jq -nc --arg msg "$msg" --arg prompt_id "$pid" --arg hint "$cmd_hint" \
           '{message:$msg, prompt_id:$prompt_id, command:"", command_uncorroborated:true, command_hint:$hint}')" \
        "${base}_input" >/dev/null 2>&1 || true
    else
      append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "input_required" \
        "$(jq -nc --arg msg "$msg" --arg prompt_id "$pid" --arg cmd "$full_cmd" \
           '{message:$msg, prompt_id:$prompt_id, command:$cmd}')" \
        "${base}_input" >/dev/null 2>&1 || true
    fi
  fi
  [ -n "$cpane" ] || return 1

  pane_is_agent "$cpane" || return 1

  # Only enforced when THIS task's own registration carries a
  # conductor_pane_birth. An older registration, or a worker not spawned via
  # spawn-task.sh, has nothing to check — so this delivers exactly as before
  # rather than inventing a refusal.
  local registered_birth live_birth
  if [ -n "$own_task" ]; then
    registered_birth=$(printf '%s' "$own_task" | jq -r '.conductor_pane_birth // empty' 2>/dev/null)
    if [ -n "${registered_birth:-}" ]; then
      live_birth="$(pane_birth_now "$cpane")"
      if [ "$live_birth" != "$registered_birth" ]; then
        append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "push_wake_refused" \
          "$(jq -nc --arg prompt_id "$pid" '{reason:"conductor_pane_recycled", prompt_id:$prompt_id}')" >/dev/null 2>&1 || true
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
    # No --authority needed: every caller without an explicit flag (or the
    # Slack button) is `peer`, terminal-attached or not, so command policy
    # gates this and a destructive prompt comes back exit 8 rather than
    # being auto-approved.
    wake="$wake  ·  ANSWER IT: $_pw_dir/herdr-select.sh ${HERDR_PANE_ID} <option>"
    [ -n "$pid" ] && wake="$wake --expect-prompt-id $pid"
  fi

  # ---- is a HUMAN actually being waited for? ---------------------------------
  # Everything above this line still happens for every prompt: the stale/terminal
  # rejection, the pane-birth checks, the `blocked` state, the `input_required`
  # row. Only the DELIVERY is gated, and deliberately at this line rather than at
  # the hook's decision point — a gate in the caller would skip the guards and
  # the audit trail with it, which is the bug the first draft of this shipped.
  #
  # An allow-class, unreserved prompt is one peer-answer.sh takes in seconds.
  # Waking a conductor (and paging Slack) for `git status` is the noise that
  # teaches its reader to ignore the channel — observed 2026-09-12, an afternoon
  # of workers doing ordinary work. Held, never dropped: grace_realert re-checks
  # and delivers late if the prompt outlives the window. See lib/alert-gate.sh.
  # HERDR_ALERT_FORCE is how the grace timer comes back: it re-enters this
  # function so the delayed wake gets pane_is_agent, the conductor pane-birth
  # revalidation and the wake_attempted/wake_result records, exactly like an
  # immediate one. The first draft handed $cpane and $wake to send-to-agent.sh
  # 90 seconds later with none of that (PR #60 review, HERDR-AG-02): a pane id
  # revalidated at T0 can belong to a bare shell by T+90, send-to-agent enforces
  # neither check, and $wake embeds agent-controlled $msg — so that was
  # agent-influenced text typed and Entered into an unvalidated pane. A delayed
  # delivery must be a delivery, not a shortcut around the delivery's guards.
  # ---- change 4 (fix/peer-waits-for-record): the reverse race. A peer can
  # refuse this EXACT prompt (herdr-select.sh's approval_escalated event,
  # authority=peer) before this hook ever fires for it — human_must_answer's
  # own live re-classification would still say "peer may take it" (it has no
  # way to know about the refusal), which used to HOLD the wake for a prompt
  # a human is already known to be waited for. Skip the hold once a refusal
  # for this exact (task, prompt_id) is already on record; deliver
  # immediately, exactly as for a human-must-answer prompt.
  local already_refused=0
  if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ] && [ -n "$pid" ]; then
    local refused_n
    refused_n="$(_sql "SELECT count(*) FROM events
          WHERE run_id=$(_sq "${HERDR_RUN_ID}") AND task_id=$(_sq "${HERDR_TASK_ID}")
            AND type='approval_escalated'
            AND json_extract(payload,'\$.prompt_id')=$(_sq "$pid");" 2>/dev/null)"
    [ "${refused_n:-0}" -gt 0 ] 2>/dev/null && already_refused=1
  fi
  if [ -z "${HERDR_ALERT_FORCE:-}" ] && [ "$already_refused" = 0 ] && [ -n "${HERDR_PANE_ID:-}" ] && ! human_must_answer "${HERDR_PANE_ID}" "$full_cmd"; then
    if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
      append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "wake_held" \
        "$(jq -nc --arg p "$cpane" --arg pid "$pid" --arg k "$base" \
           '{conductor_pane:$p, prompt_id:$pid, wake_key:$k, reason:"allow-class and unreserved; a peer may answer it"}')" \
        "${base}_held" >/dev/null 2>&1 || true
    fi
    _pw_forced_wake_argv "${HERDR_PANE_ID}" "$cpane" "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" \
      "${HERDR_TASK_LABEL:-}" "$msg" "$where" "$full_cmd"
    grace_realert "${HERDR_PANE_ID}" "$pid" "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" \
      "${_PW_FORCED_WAKE_ARGV[@]}"
    # A held wake has NOT been delivered, so it does not report success — the
    # documented contract is "0 only when delivered AND confirmed submitted"
    # (HERDR-AG-09). 2 distinguishes held from a transport failure.
    return 2
  fi

  # Every ATTEMPT gets its own pair of event rows. The previous ids
  # ("${base}_attempt"/"${base}_result") were constant per logical prompt, so
  # INSERT OR IGNORE preserved the FIRST transport outcome forever — a wake
  # that failed once and succeeded on retry (or vice versa) was unrecordable,
  # and the log lied about every attempt after the first. attempt_uniq makes
  # each attempt append-only and individually identifiable; wake_key ($base)
  # keeps the correlation back to the logical prompt, and attempt ties a
  # result row to exactly the attempt row it belongs to.
  local attempt_uniq
  attempt_uniq="$(date -u +%Y%m%dT%H%M%SZ)_$$_${RANDOM}"
  if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "wake_attempted" \
      "$(jq -nc --arg p "$cpane" --arg pid "$pid" --arg k "$base" --arg a "$attempt_uniq" \
         '{conductor_pane:$p, prompt_id:$pid, wake_key:$k, attempt:$a}')" \
      "${base}_attempt_${attempt_uniq}" >/dev/null 2>&1 || true
  fi

  local rc=0
  bash "$_pw_dir/send-to-agent.sh" "$cpane" "$wake" >/dev/null 2>&1 || rc=$?
  local outcome; outcome="$(_wake_outcome_for "$rc")"

  if [ -n "${HERDR_RUN_ID:-}" ] && [ -n "${HERDR_TASK_ID:-}" ]; then
    append_event "$HERDR_RUN_ID" "$HERDR_TASK_ID" "wake_result" \
      "$(jq -nc --arg o "$outcome" --argjson c "$rc" --arg p "$cpane" --arg pid "$pid" --arg k "$base" --arg a "$attempt_uniq" \
         '{outcome:$o, exit_code:$c, conductor_pane:$p, prompt_id:$pid, wake_key:$k, attempt:$a}')" \
      "${base}_result_${attempt_uniq}" >/dev/null 2>&1 || true
  fi

  # A conductor wake that did not land is exactly the case Slack's own hold
  # (lib/alert-gate.sh) cannot see: that mechanism watches the PANE, not
  # whether the peer notification path actually reached anyone. Give it
  # HERDR_WAKE_FAIL_ALERT_S to resolve itself before paging directly.
  [ "$rc" -eq 0 ] || _pw_wake_fail_realert "${HERDR_PANE_ID:-}" "$pid" \
    "${HERDR_RUN_ID:-}" "${HERDR_TASK_ID:-}" "$outcome"
  # A wake that was typed but never submitted is a FAILED wake, and the log now
  # says so rather than implying the conductor was reached.
  [ "$rc" -eq 0 ] && return 0
  printf 'push-wake: wake to %s ended %s (exit %s) — conductor may not have seen it\n' \
    "$cpane" "$outcome" "$rc" >&2
  return 1
}

# release_wake_hold <pane> <pid> <run> <task> <cpane> <label> <msg> <where> <full_cmd> <reason>
#
# Change 3 (fix/peer-waits-for-record): a wake_held row means push_wake
# decided "a peer may take it" for THIS exact prompt — but the peer path can
# disagree a moment later (herdr-select.sh --authority peer refuses it), and
# a held wake must not then sit held for the full grace window while a human
# is genuinely needed. Call this right after that refusal; it no-ops
# (returns 1) when no wake_held row exists for (run, task, pid) — most
# refusals were never held at all.
#
# Claims the SAME idempotency key grace_realert's own 90s re-check uses
# (grace_realert_${run}_${task}_${pid} via claim_once) BEFORE delivering, so
# whichever of the two fires first wins and the other silently no-ops —
# never a duplicate wake for one held prompt.
#
# The claim and the wake_hold_released record are synchronous (both a
# single fast registry write); only the actual delivery — which re-enters
# push_wake through a fresh bash process, exactly like a delayed
# grace_realert — runs detached, so a caller that must still exit promptly
# (herdr-select.sh, exit 8) is never held open by it.
release_wake_hold() {
  local pane="$1" pid="$2" run="$3" task="$4" cpane="$5" label="$6" msg="$7" where="$8" full_cmd="$9" reason="${10:-}"
  [ -n "$run" ] && [ -n "$task" ] && [ -n "$pid" ] || return 1
  registry_init || return 1
  local held
  held="$(_sql "SELECT count(*) FROM events
        WHERE run_id=$(_sq "$run") AND task_id=$(_sq "$task")
          AND type='wake_held'
          AND json_extract(payload,'\$.prompt_id')=$(_sq "$pid");" 2>/dev/null)"
  [ "${held:-0}" -gt 0 ] 2>/dev/null || return 1
  claim_once "grace_realert_${run}_${task}_${pid}" "$run" "$task" \
    grace_realert_claim \
    "$(jq -nc --arg p "$pane" --arg pid "$pid" '{pane:$p,prompt_id:$pid}')" \
    || return 1
  append_event "$run" "$task" "wake_hold_released" \
    "$(jq -nc --arg pid "$pid" --arg p "$pane" --arg r "$reason" '{prompt_id:$pid, pane:$p, reason:$r}')" \
    >/dev/null 2>&1 || true
  _pw_forced_wake_argv "$pane" "$cpane" "$run" "$task" "$label" "$msg" "$where" "$full_cmd"
  ( "${_PW_FORCED_WAKE_ARGV[@]}" >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# ---- symptom: the conductor wake failed and nobody has noticed ------------
# .handoffs/SPEC.md KEEP list: "a wake that failed delivery (refused/
# unsubmitted) and no one answered within 10 min". Measured on this machine's
# own registry (48h window): 176 of 353 wake_result events were NOT
# `submitted` (116 `unknown`, 56 `unsubmitted`, 4 `refused`) — roughly half
# the time the ONE channel meant to catch a blocked worker (a peer reading
# the steering queue) silently did not land, with nothing watching for it.
#
# lib/alert-gate.sh's grace hold cannot see this: it watches the PANE (is a
# prompt still up), never whether the wake meant to surface that pane to a
# peer actually arrived. This is the backstop for THAT gap specifically —
# it runs only when push_wake's own delivery already failed.
#
# Deliberately re-checks the TASK, not just the pane, before paging: the
# operator may have answered directly in the worker's own terminal, which
# unblocks the task even though the conductor never got the wake at all —
# that must read as resolved, not as "still nobody noticed".
#
# Runs detached, same discipline as grace_realert: a hook must never hold the
# agent's turn on a 10-minute sleep. The eventual herdr-notify.sh call goes
# through the SAME prompt_id dedupe as every other caller (lib/alert-gate.sh
# alert_claim), so if the primary alert path already posted for this exact
# prompt, this backstop silently no-ops instead of paging twice.
_pw_wake_fail_realert() {
  local pane="$1" pid="$2" run="$3" task="$4" outcome="$5"
  [ -n "$pane" ] || return 0
  local secs="${HERDR_WAKE_FAIL_ALERT_S:-600}"
  case "$secs" in ''|*[!0-9]*) secs=600 ;; esac
  (
    sleep "$secs"
    if [ -n "$run" ] && [ -n "$task" ]; then
      local st
      st="$(read_task "$run" "$task" 2>/dev/null | jq -r '.state // empty' 2>/dev/null)"
      [ "$st" = "blocked" ] || exit 0
    fi
    prompt_menu_visible "$pane" 2>/dev/null || [ -n "$(prompt_options "$pane" 2>/dev/null)" ] || exit 0
    local notify
    for notify in "${HERDR_NOTIFY:-}" "$_pw_dir/slack-bridge/herdr-notify.sh" \
                  "$HOME/.claude/skills/herdr-ops/scripts/slack-bridge/herdr-notify.sh"; do
      [ -n "$notify" ] && [ -f "$notify" ] && break
    done
    [ -n "${notify:-}" ] && [ -f "$notify" ] || exit 0
    bash "$notify" --choices --pane "$pane" \
      "conductor wake ${outcome} and still unanswered after ${secs}s — the peer-notify path is broken, this needs you directly" \
      >/dev/null 2>&1 || true
    if [ -n "$run" ] && [ -n "$task" ]; then
      # Keyed by prompt_id, not a fresh random id: two independent failed-wake
      # timers for the SAME still-unanswered prompt both reach this line (the
      # SECOND one's herdr-notify.sh call is silently deduped, exit 0 either
      # way — see lib/alert-gate.sh alert_claim), so without a deterministic
      # id the ledger would claim two alerts for a symptom Slack only saw once.
      local wf_eid=""
      [ -n "$pid" ] && wf_eid="wakefail_${pid}"
      append_event "$run" "$task" "wake_fail_alerted" \
        "$(jq -nc --arg p "$pane" --arg pid "$pid" --arg o "$outcome" --arg s "$secs" \
           '{pane:$p, prompt_id:$pid, outcome:$o, wait_seconds:($s|tonumber)}')" \
        "$wf_eid" >/dev/null 2>&1 || true
    fi
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
