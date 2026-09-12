#!/usr/bin/env bash
# alert-gate.sh — decide whether a prompt on a worker pane is one a HUMAN must
# answer, or one an automated peer is allowed to take.
#
# Provides: human_must_answer <pane_id>   0 = tell a person, 1 = a peer may take it
#           grace_realert <pane_id> <prompt_id> <run> <task> <cmd...>
#
# Why this exists: every approval prompt used to produce a Slack alert AND a
# conductor wake, including the ones peer-answer.sh auto-approves two seconds
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
# genuinely being waited for and the alert goes out. If peer authority would
# take it, the alert is held.
#
# HELD, NOT DROPPED. "Something else will answer it" is an assumption, and this
# codebase keeps finding bugs that live exactly there. grace_realert re-checks
# after HERDR_ALERT_GRACE_S (default 90): if the SAME prompt is still on screen
# and the task is still blocked, the alert fires after all, late but real. So
# the worst case of a broken or absent answer loop is a delayed page, never a
# silent one.
[ -n "${_HERDR_ALERT_GATE_SH:-}" ] && return 0
_HERDR_ALERT_GATE_SH=1
_ag_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_ag_dir/prompt-parse.sh"
. "$_ag_dir/command-policy.sh"

# 0 = a human must answer this. 1 = peer authority may take it.
# Unreadable, unclassifiable, or no prompt at all -> 0. Telling a person about
# something we could not read is the safe direction; staying quiet is not.
human_must_answer() {
  local pane="$1" cmd verdict
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
  [ -n "$(prompt_menu_options "$pane" 2>/dev/null)$(prompt_options "$pane" 2>/dev/null)" ] || return 0
  cmd="$(prompt_command_text "$pane" 2>/dev/null || printf '')"
  [ -n "${cmd//[[:space:]]/}" ] || return 0
  case "$cmd" in *elided*|*truncated*) return 0 ;; esac
  [ -n "$(conductor_reserved_reason "$cmd")" ] && return 0
  verdict="$(classify_command "$cmd" 2>/dev/null || printf 'escalate')"
  [ "$verdict" = allow ] || return 0
  return 1
}

# Re-check after the grace window and alert if the prompt outlived it.
# Runs detached: a notification hook must never hold the agent's turn.
# `<cmd...>` is the alert command to run if the prompt is still up.
grace_realert() {
  local pane="$1" pid="$2" run="$3" task="$4"; shift 4
  local grace="${HERDR_ALERT_GRACE_S:-90}"
  (
    sleep "$grace"
    # Same prompt? A different prompt is a different fact and gets its own
    # hook call; a cleared prompt means the loop did its job.
    local now_pid
    now_pid="$(prompt_id "$pane" 2>/dev/null || printf '')"
    [ -n "$pid" ] && [ "$now_pid" != "$pid" ] && exit 0
    prompt_menu_visible "$pane" 2>/dev/null || [ -n "$(prompt_options "$pane" 2>/dev/null)" ] || exit 0
    if [ -n "$run" ] && [ -n "$task" ]; then
      append_event "$run" "$task" "alert_grace_expired" \
        "$(jq -nc --arg p "$pane" --arg pid "$pid" --arg g "$grace" \
           '{pane:$p, prompt_id:$pid, grace_seconds:$g, reason:"allow-class prompt still unanswered after the grace window"}')" \
        >/dev/null 2>&1 || true
    fi
    "$@" >/dev/null 2>&1 || true
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
