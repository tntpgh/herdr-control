#!/usr/bin/env bash
# alert-gate.sh — decide whether a prompt on a worker pane is one a HUMAN must
# answer, or one an automated peer is allowed to take.
#
# Provides: human_must_answer <pane_id> [recorded-cmd]   0 = tell a person, 1 = a peer may take it
#           grace_realert <pane_id> <prompt_id> <run> <task> <cmd...>
#
# Why this exists: every approval prompt used to produce a Slack alert AND a
# conductor wake (the Slack lane is retired; the wake remains), including the
# ones peer-answer.sh auto-approves two seconds
# later. A worker doing ordinary work (`git status`, `pwd`, a grep, its own test
# suite) generated dozens of pages in an afternoon — 2026-09-12, observed by the
# operator as "we are spamming the slack". An alert channel that fires on
# everything trains its reader to ignore it, which costs exactly the alert that
# mattered. The registry is unchanged: `input_required` is still recorded for
# every prompt, so nothing is hidden from reconciliation, `hub`, or the sweep.
#
# The gate is the SAME classification the answer path enforces
# (lib/command-policy.sh), so the two can never disagree about who owns a
# prompt: if `herdr-select.sh --authority peer` would refuse it, a human is
# genuinely being waited for and the conductor wake goes out. If peer
# authority would take it, the wake is held.
#
# HELD, NOT DROPPED. "Something else will answer it" is an assumption, and this
# codebase keeps finding bugs that live exactly there. grace_realert re-checks
# after HERDR_ALERT_GRACE_S (default 90): if the SAME prompt is still on screen
# and the task is still blocked, the wake fires after all, late but real. So
# the worst case of a broken or absent answer loop is a delayed wake, never a
# silent one.
[ -n "${_HERDR_ALERT_GATE_SH:-}" ] && return 0
_HERDR_ALERT_GATE_SH=1
_ag_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_ag_dir/prompt-parse.sh"
. "$_ag_dir/command-policy.sh"
. "$_ag_dir/run-registry.sh"
. "$_ag_dir/scoped-policy.sh"

# 0 = a human must answer this. 1 = peer authority may take it.
# Unreadable, unclassifiable, or no prompt at all -> 0. Telling a person about
# something we could not read is the safe direction; staying quiet is not.
# [recorded-cmd] is the untruncated command the hook recorded for this prompt
# (agent-hooks/omp-herdr-control.ts); judged instead of the panel only when it
# EQUALS the panel's command region — lib/scoped-policy.sh
# approval_command_text, the same rule herdr-select.sh enforces, as is the peer
# decision itself (peer_decide), so this gate and the answer path cannot
# disagree about who owns a prompt. A recorded command that does NOT match is
# dropped and the panel is judged alone, which is exactly what push_wake does
# with the same text (it blanks it before recording the row) and what
# herdr-select.sh will judge when a peer answers. Until 2026-09-27 this
# returned "a human must answer" on a mismatch instead, so the hook (raw text:
# human) and push_wake (blanked text: peer may take it) classified one prompt
# two ways, armed a human-stale page AND held the wake for it (PR #158 round 2).
human_must_answer() {
  local pane="$1" recorded="${2:-}" cmd task
  [ -n "$pane" ] || return 0
  # A COMPLETE recognized prompt must be on screen before anything is classified.
  # Two distinct reasons, both found by tests rather than by reasoning:
  #   - Without any shape check the gate trusts its caller: `prompt_command_text`
  #     falls back to the whole visible region when there is no panel, so ordinary
  #     transcript output classifies as `allow` and an alert gets held on the
  #     strength of a log line.
  #   - `visible` is not enough either. An UNRECOGNIZED menu — omp's
  #     "Approve / Always allow / Deny", which carries no `Command:` row — is
  #     visible but incomplete, and holding it would mean suppressing an alert
  #     for a prompt whose command we cannot even read. If the shape is not one
  #     we fully parse, a person decides.
  # A numbered list only counts when the pane is NOT an omp panel pane. omp
  # paints its steering queue as `1. Conductor: …`, which the numbered
  # extractor matches — the collision prompt_id()'s own header documents. With
  # a queue on screen and an UNRECOGNIZED approval panel below it, accepting
  # the numbered shape would hold an alert for a panel no peer can answer
  # (peer-answer.sh acts only on complete panels), i.e. silence for a prompt
  # that is nobody's (PR #60 review, HERDR-AG-06). A complete menu is
  # authoritative; anything else on a pane showing `Allow tool:` furniture is
  # a person's.
  if [ -z "$(prompt_menu_options "$pane" 2>/dev/null)" ]; then
    _pane_visible "$pane" | grep -q 'Allow tool:' && return 0
    [ -n "$(prompt_options "$pane" 2>/dev/null)" ] || return 0
  fi
  cmd="$(prompt_command_text "$pane" 2>/dev/null || printf '')"
  local judged
  # F1/F6 (fix/approve-wrapped-commands security review): same wrap-join
  # corroboration herdr-select.sh and push_wake now apply, from the SAME
  # screen snapshot as `cmd` (corroboration_candidates) rather than a
  # second independent read; falls back to `cmd` unchanged for a numbered
  # or unparseable pane.
  corroboration_candidates "$pane" "$cmd"
  judged="$(approval_command_text "$CC_PANEL" "$recorded" "$CC_WRAPJOIN")" && cmd="$judged"
  [ -n "${cmd//[[:space:]]/}" ] || return 0
  case "$cmd" in *elided*|*truncated*) return 0 ;; esac
  task="$(task_for_pane "$pane" 2>/dev/null)"
  peer_decide "$cmd" "$task" && return 1
  return 0
}

# Re-check after the grace window and alert if a prompt outlived it.
# Runs detached: a notification hook must never hold the agent's turn.
# `<cmd...>` is the alert command; it is expected to carry its own guards and
# its own outcome recording (for the conductor wake that means re-entering
# push_wake with HERDR_ALERT_FORCE=1, not a raw send-to-agent).
#
# The re-check asks ONE question: is a prompt still on screen? It deliberately
# does NOT require the fingerprint to match. The first draft did, and review
# (PR #60, HERDR-AG-01) showed that is a silent-failure machine: prompt_id()
# always returns a 64-hex digest — it never signals "could not read" — so a
# torn frame, a tmux resize rewrapping a long `Command:` row, a scroll, or one
# unrelated line entering the scraped region all produce a different hash for
# the SAME pending question. The timer would then exit quietly, and no further
# hook fires for that prompt (omp's tool_call is once per tool call, Claude's
# Notification once per prompt). That is permanent silence for a prompt nobody
# answered — the precise outcome this whole mechanism promises cannot happen,
# and the same anti-pattern push-wake.sh's worker-birth check already forbids:
# refuse on a POSITIVE mismatch, never on an unreadable sample.
#
# So: prompt gone -> silence is correct, it was answered. Prompt present ->
# alert, whatever its fingerprint. A changed fingerprint means the operator
# hears about a prompt whose text moved on, which is a worse description and a
# better outcome than hearing nothing. The id is carried into the event for
# forensics only.

# Sanitize the grace window. Split out so it can be asserted directly instead of
# by waiting out a timer — a test that has to sleep 90s to check a clamp does
# not get written, and then the clamp is untested.
_ag_grace_seconds() {                   # [raw] -> integer seconds
  local g="${1:-${HERDR_ALERT_GRACE_S:-90}}"
  case "$g" in
    ''|*[!0-9]*) printf '90\n'; return ;;   # non-numeric: the default, not an error
  esac
  [ "$g" -gt 900 ] && { printf '900\n'; return ; }   # unbounded silence is not a setting
  [ "$g" -lt 1 ] && { printf '1\n'; return ; }
  printf '%s\n' "$g"
}

# TEST SEAM, unset in every real deployment: when HERDR_ALERT_TRACE names a
# file, each detached grace_realert timer appends "armed <kind> <prompt_id>"
# when it starts and "done <kind> <prompt_id> <outcome>" when it exits,
# whatever the exit path. A suite then waits for its timers to finish by
# reading the file, instead of sleeping and hoping a slow run's timer has not
# yet fired into the NEXT case's window.
_ag_trace() {
  [ -n "${HERDR_ALERT_TRACE:-}" ] && printf '%s\n' "$*" >> "$HERDR_ALERT_TRACE"
  return 0
}

grace_realert() {
  local pane="$1" pid="$2" run="$3" task="$4"; shift 4
  local grace hold_at
  grace="$(_ag_grace_seconds)"
  hold_at="$(_now_iso 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  _ag_trace "armed grace_realert ${pid:-noprompt}"
  (
    _ag_out=stood_down
    trap '_ag_trace "done grace_realert ${pid:-noprompt} $_ag_out"' EXIT
    sleep "$grace"
    prompt_menu_visible "$pane" 2>/dev/null || [ -n "$(prompt_options "$pane" 2>/dev/null)" ] || exit 0
    # A later prompt on this task supersedes this timer. Without this check,
    # every repeated hook created another timer that eventually woke the
    # conductor for whichever prompt happened to be current at T+grace.
    if [ -n "$run" ] && [ -n "$task" ]; then
      later="$(_sql "SELECT count(*) FROM events WHERE run_id=$(_sq "$run")
        AND task_id=$(_sq "$task") AND type='input_required'
        AND occurred_at > $(_sq "$hold_at");" 2>/dev/null)"
      [ "${later:-0}" = 0 ] || exit 0
      # The claim is shared ON PURPOSE between the conductor re-wake push_wake
      # arms and release_wake_hold (one of them acts on a held prompt, never
      # two).
      claim_once "grace_realert_${run}_${task}_${pid}" "$run" "$task" \
        grace_realert_claim \
        "$(jq -nc --arg p "$pane" --arg pid "$pid" '{pane:$p,prompt_id:$pid}')" \
        || exit 0
    fi
    local now_pid rc=0
    now_pid="$(prompt_id "$pane" 2>/dev/null || printf '')"
    "$@" >/dev/null 2>&1 || rc=$?
    _ag_out=fired
    if [ -n "$run" ] && [ -n "$task" ]; then
      append_event "$run" "$task" "alert_grace_expired" \
        "$(jq -nc --arg p "$pane" --arg pid "$pid" --arg now "$now_pid" --arg g "$grace" --argjson rc "$rc" \
           '{pane:$p, prompt_id_at_hold:$pid, prompt_id_now:$now, grace_seconds:$g, delivery_exit:$rc,
             fingerprint_changed:($pid != "" and $now != $pid),
             reason:"held prompt still unanswered after the grace window"}')" \
        >/dev/null 2>&1 || true
    fi
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
